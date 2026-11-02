rabbitmq_url = System.get_env("RABBITMQ_URL")
mongo_url = System.get_env("MONGO_URL")

if rabbitmq_url && mongo_url do
  defmodule Notifications.Events.ConsumerTest do
    use ExUnit.Case, async: false

    alias Notifications.Unread
    alias Notifications.Unread.State

    @exchange "discordia.events"

    setup do
      previous = Application.get_env(:notifications, :unread_repo)
      Application.put_env(:notifications, :unread_repo, Notifications.Unread.Repo.Mongo)

      on_exit(fn -> Application.put_env(:notifications, :unread_repo, previous) end)

      rabbitmq_url = System.fetch_env!("RABBITMQ_URL")
      queue = "notifications.unread_state.test-#{System.unique_integer([:positive])}"

      start_supervised!({Notifications.Events.Consumer, url: rabbitmq_url, queue: queue})

      assert wait_until(fn ->
               match?(%{chan: %AMQP.Channel{}}, :sys.get_state(Notifications.Events.Consumer))
             end)

      {:ok, conn} = AMQP.Connection.open(rabbitmq_url)
      {:ok, chan} = AMQP.Channel.open(conn)
      :ok = AMQP.Exchange.declare(chan, @exchange, :topic, durable: true)

      on_exit(fn ->
        try do
          {:ok, cleanup} = AMQP.Channel.open(conn)
          AMQP.Queue.delete(cleanup, queue)
          AMQP.Connection.close(conn)
        catch
          :exit, _ -> :ok
        end
      end)

      suffix = Notifications.UUID.generate()

      {:ok,
       chan: chan,
       queue: queue,
       server: "srv-" <> suffix,
       channel: "chan-" <> suffix,
       me: "me-" <> suffix,
       other: "other-" <> suffix}
    end

    defp publish(chan, routing_key, extra) do
      body =
        %{"event_id" => Notifications.UUID.generate(), "occurred_at" => iso(DateTime.utc_now())}
        |> Map.merge(extra)
        |> Jason.encode!()

      :ok = AMQP.Basic.publish(chan, @exchange, routing_key, body, persistent: true)
    end

    defp iso(datetime), do: DateTime.to_iso8601(datetime)

    defp later(seconds),
      do: DateTime.utc_now() |> DateTime.add(seconds, :second) |> Notifications.UUID.floor_v7()

    defp wait_until(fun, tries \\ 100) do
      cond do
        fun.() ->
          true

        tries == 0 ->
          false

        true ->
          Process.sleep(50)
          wait_until(fun, tries - 1)
      end
    end

    defp flags(user, channel) do
      case Unread.snapshot(user) do
        {:ok, state} -> state |> State.channel_flags(channel) |> Map.take([:unread, :mention])
        {:error, _reason} -> nil
      end
    end

    defp seed_membership(ctx) do
      %{chan: chan, server: server, channel: channel, me: me} = ctx

      publish(chan, "servers.role_updated", %{
        "server_id" => server,
        "role_id" => "everyone-" <> server,
        "permissions" => ["VIEW_CHANNELS"],
        "is_everyone" => true
      })

      publish(chan, "servers.channel_created", %{
        "server_id" => server,
        "channel_id" => channel,
        "name" => "general",
        "kind" => "text"
      })

      publish(chan, "servers.member_joined", %{"server_id" => server, "user_id" => me})

      publish(chan, "servers.member_roles_updated", %{
        "server_id" => server,
        "user_id" => me,
        "role_ids" => ["everyone-" <> server]
      })

      assert wait_until(fn -> match?({:ok, %{^channel => _}}, Unread.snapshot(me)) end)
    end

    test "CA1/CA2: a message in a channel the member can view becomes unread", ctx do
      %{chan: chan, server: server, channel: channel, me: me, other: other} = ctx
      seed_membership(ctx)
      assert flags(me, channel) == %{unread: false, mention: false}

      publish(chan, "messaging.message_created", %{
        "server_id" => server,
        "channel_id" => channel,
        "message_id" => later(10),
        "author_id" => other,
        "mentioned_user_ids" => []
      })

      assert wait_until(fn -> flags(me, channel) == %{unread: true, mention: false} end)
      assert {:ok, state} = Unread.snapshot(me)

      assert Map.take(State.server_flags(state, server), [:unread, :mention]) ==
               %{unread: true, mention: false}
    end

    test "CA3: a message that mentions the member is flagged as a mention", ctx do
      %{chan: chan, server: server, channel: channel, me: me, other: other} = ctx
      seed_membership(ctx)

      publish(chan, "messaging.message_created", %{
        "server_id" => server,
        "channel_id" => channel,
        "message_id" => later(10),
        "author_id" => other,
        "mentioned_user_ids" => [me]
      })

      assert wait_until(fn -> flags(me, channel) == %{unread: true, mention: true} end)
    end

    test "a channel nobody announced yet is learned from its first message (backfill case)",
         ctx do
      %{chan: chan, server: server, channel: channel, me: me, other: other} = ctx

      publish(chan, "servers.role_updated", %{
        "server_id" => server,
        "role_id" => "everyone-" <> server,
        "permissions" => ["VIEW_CHANNELS"],
        "is_everyone" => true
      })

      publish(chan, "servers.member_roles_updated", %{
        "server_id" => server,
        "user_id" => me,
        "role_ids" => ["everyone-" <> server]
      })

      publish(chan, "messaging.message_created", %{
        "server_id" => server,
        "channel_id" => channel,
        "message_id" => later(10),
        "author_id" => other,
        "mentioned_user_ids" => []
      })

      assert wait_until(fn -> flags(me, channel) == %{unread: true, mention: false} end)
    end

    test "a message for a channel that was deleted does not bring it back", ctx do
      %{chan: chan, server: server, channel: channel, other: other} = ctx

      publish(chan, "servers.channel_deleted", %{"server_id" => server, "channel_id" => channel})

      assert wait_until(fn ->
               Notifications.Unread.Repo.Mongo.get_clock("channel:" <> channel) != nil
             end)

      publish(chan, "messaging.message_created", %{
        "server_id" => server,
        "channel_id" => channel,
        "message_id" => later(10),
        "author_id" => other,
        "mentioned_user_ids" => []
      })

      Process.sleep(500)
      assert Notifications.Unread.Repo.Mongo.get_channel(channel) == nil
      assert {:ok, activity} = Notifications.Unread.Repo.Mongo.get_activity([channel])
      assert activity == %{}
    end

    test "CA2: marking everything as read clears every channel of every server", ctx do
      %{chan: chan, server: server, channel: channel, me: me, other: other} = ctx
      seed_membership(ctx)
      second = "chan2-" <> server

      publish(chan, "servers.channel_created", %{
        "server_id" => server,
        "channel_id" => second,
        "name" => "random",
        "kind" => "text"
      })

      for {id, mentions} <- [{channel, [me]}, {second, []}] do
        publish(chan, "messaging.message_created", %{
          "server_id" => server,
          "channel_id" => id,
          "message_id" => later(10),
          "author_id" => other,
          "mentioned_user_ids" => mentions
        })
      end

      assert wait_until(fn ->
               flags(me, channel) == %{unread: true, mention: true} and
                 flags(me, second) == %{unread: true, mention: false}
             end)

      assert {:ok, 2} = Unread.mark_all_read(me)

      assert flags(me, channel) == %{unread: false, mention: false}
      assert flags(me, second) == %{unread: false, mention: false}
      assert {:ok, 0} = Unread.mark_all_read(me)
    end

    test "reading the channel clears the indicators", ctx do
      %{chan: chan, server: server, channel: channel, me: me, other: other} = ctx
      seed_membership(ctx)

      publish(chan, "messaging.message_created", %{
        "server_id" => server,
        "channel_id" => channel,
        "message_id" => later(10),
        "author_id" => other,
        "mentioned_user_ids" => [me]
      })

      assert wait_until(fn -> flags(me, channel).unread end)
      assert {:ok, _up_to} = Unread.mark_read(me, channel)
      assert flags(me, channel) == %{unread: false, mention: false}
    end

    test "the member's own messages never make the channel unread for them", ctx do
      %{chan: chan, server: server, channel: channel, me: me} = ctx
      seed_membership(ctx)

      publish(chan, "messaging.message_created", %{
        "server_id" => server,
        "channel_id" => channel,
        "message_id" => later(10),
        "author_id" => me,
        "mentioned_user_ids" => []
      })

      assert wait_until(fn ->
               {:ok, activity} = Notifications.Unread.Repo.Mongo.get_activity([channel])
               map_size(activity) == 1
             end)

      assert flags(me, channel) == %{unread: false, mention: false}
    end

    test "a message from before the member joined is not unread for them", ctx do
      %{chan: chan, server: server, channel: channel, me: me, other: other} = ctx
      seed_membership(ctx)

      old = DateTime.utc_now() |> DateTime.add(-3_600, :second) |> Notifications.UUID.floor_v7()

      publish(chan, "messaging.message_created", %{
        "server_id" => server,
        "channel_id" => channel,
        "message_id" => old,
        "author_id" => other,
        "mentioned_user_ids" => []
      })

      assert wait_until(fn ->
               {:ok, activity} = Notifications.Unread.Repo.Mongo.get_activity([channel])
               map_size(activity) == 1
             end)

      assert flags(me, channel) == %{unread: false, mention: false}
    end

    test "a channel the member cannot view is not tracked for them", ctx do
      %{chan: chan, server: server, channel: channel, me: me, other: other} = ctx
      seed_membership(ctx)

      publish(chan, "servers.channel_overrides_updated", %{
        "server_id" => server,
        "channel_id" => channel,
        "overrides" => [
          %{"role_id" => "everyone-" <> server, "allow" => [], "deny" => ["VIEW_CHANNELS"]}
        ]
      })

      assert wait_until(fn -> match?({:ok, state} when state == %{}, Unread.snapshot(me)) end)

      publish(chan, "messaging.message_created", %{
        "server_id" => server,
        "channel_id" => channel,
        "message_id" => later(10),
        "author_id" => other,
        "mentioned_user_ids" => [me]
      })

      assert {:error, :forbidden} = wait_for_error(fn -> Unread.mark_read(me, channel) end)
    end

    test "leaving the server removes its channels from the member's state", ctx do
      %{chan: chan, server: server, channel: channel, me: me} = ctx
      seed_membership(ctx)

      publish(chan, "servers.member_left", %{"server_id" => server, "user_id" => me})

      assert wait_until(fn -> match?({:ok, state} when state == %{}, Unread.snapshot(me)) end)
      refute Map.has_key?(elem(Unread.snapshot(me), 1), channel)
    end

    test "deleting the server drops its data and ignores later events", ctx do
      %{chan: chan, server: server, channel: channel, me: me, other: other} = ctx
      seed_membership(ctx)

      publish(chan, "servers.server_deleted", %{"server_id" => server, "channel_ids" => [channel]})

      assert wait_until(fn -> match?({:ok, state} when state == %{}, Unread.snapshot(me)) end)

      publish(chan, "messaging.message_created", %{
        "server_id" => server,
        "channel_id" => channel,
        "message_id" => later(10),
        "author_id" => other,
        "mentioned_user_ids" => []
      })

      publish(chan, "servers.channel_created", %{
        "server_id" => server,
        "channel_id" => channel,
        "name" => "zombie",
        "kind" => "text"
      })

      Process.sleep(500)
      assert {:ok, activity} = Notifications.Unread.Repo.Mongo.get_activity([channel])
      assert activity == %{}
      assert Notifications.Unread.Repo.Mongo.get_channel(channel) == nil
    end

    test "processed events are audited, message activity is not", ctx do
      %{chan: chan, server: server, channel: channel, me: me, other: other} = ctx
      event_id = Notifications.UUID.generate()

      body =
        Jason.encode!(%{
          "event_id" => event_id,
          "occurred_at" => iso(DateTime.utc_now()),
          "server_id" => server,
          "channel_id" => channel,
          "name" => "general",
          "kind" => "text"
        })

      :ok = AMQP.Basic.publish(chan, @exchange, "servers.channel_created", body)

      assert wait_until(fn ->
               match?(%{"status" => "processed"}, audit(event_id))
             end)

      message_event_id = Notifications.UUID.generate()

      :ok =
        AMQP.Basic.publish(
          chan,
          @exchange,
          "messaging.message_created",
          Jason.encode!(%{
            "event_id" => message_event_id,
            "occurred_at" => iso(DateTime.utc_now()),
            "server_id" => server,
            "channel_id" => channel,
            "message_id" => later(10),
            "author_id" => other,
            "mentioned_user_ids" => [me]
          })
        )

      assert wait_until(fn ->
               {:ok, activity} = Notifications.Unread.Repo.Mongo.get_activity([channel])
               map_size(activity) == 1
             end)

      assert audit(message_event_id) == nil
    end

    test "a malformed or invalid message is acked and audited, not retried forever", ctx do
      %{chan: chan, queue: queue} = ctx
      event_id = Notifications.UUID.generate()

      :ok = AMQP.Basic.publish(chan, @exchange, "servers.member_left", "{not json")

      :ok =
        AMQP.Basic.publish(
          chan,
          @exchange,
          "servers.member_left",
          Jason.encode!(%{"event_id" => event_id, "occurred_at" => "nope"})
        )

      assert wait_until(fn ->
               match?(%{"status" => "discarded_invalid_payload"}, audit(event_id))
             end)

      assert wait_until(fn -> message_count(chan, queue) == 0 end)
    end

    defp wait_for_error(fun, tries \\ 100) do
      case fun.() do
        {:error, _reason} = error ->
          error

        _other when tries > 0 ->
          Process.sleep(50)
          wait_for_error(fun, tries - 1)

        other ->
          other
      end
    end

    test "CA1: a mention ends up in the history of whoever was mentioned", ctx do
      %{chan: chan, server: server, channel: channel, me: me, other: other} = ctx
      seed_membership(ctx)
      message_id = later(10)

      publish(chan, "messaging.message_created", %{
        "server_id" => server,
        "channel_id" => channel,
        "message_id" => message_id,
        "author_id" => other,
        "mentioned_user_ids" => [me]
      })

      assert wait_until(fn -> history_ids(me) == [message_id] end)

      assert {:ok, %{items: [item]}} = Notifications.History.list(me)
      assert item["kind"] == "mention"
      assert item["channel_id"] == channel
      assert item["server_id"] == server
      assert item["author_id"] == other
    end

    test "CA1: a direct message ends up in the history of its recipient, with no server involved",
         ctx do
      %{chan: chan, me: me, other: other} = ctx
      message_id = later(10)

      publish(chan, "messaging.direct_message_created", %{
        "conversation_id" => "conv-" <> me,
        "message_id" => message_id,
        "author_id" => other,
        "recipient_id" => me
      })

      assert wait_until(fn -> history_ids(me) == [message_id] end)

      assert {:ok, %{items: [item]}} = Notifications.History.list(me)
      assert item["kind"] == "direct_message"
      assert item["conversation_id"] == "conv-" <> me
      assert history_ids(other) == []
    end

    test "the history lists the newest first", ctx do
      %{chan: chan, me: me, other: other} = ctx
      older = later(10)
      newer = later(20)

      for message_id <- [older, newer] do
        publish(chan, "messaging.direct_message_created", %{
          "conversation_id" => "conv-" <> me,
          "message_id" => message_id,
          "author_id" => other,
          "recipient_id" => me
        })
      end

      assert wait_until(fn -> history_ids(me) == [newer, older] end)
    end

    test "a muted channel leaves no entry for the mention, a plain one does", ctx do
      %{chan: chan, server: server, channel: channel, me: me, other: other} = ctx
      seed_membership(ctx)

      assert {:ok, %{muted: true}} =
               Notifications.Settings.update_channel(me, channel, %{muted: true})

      publish(chan, "messaging.message_created", %{
        "server_id" => server,
        "channel_id" => channel,
        "message_id" => later(10),
        "author_id" => other,
        "mentioned_user_ids" => [me]
      })

      direct = later(20)

      publish(chan, "messaging.direct_message_created", %{
        "conversation_id" => "conv-" <> me,
        "message_id" => direct,
        "author_id" => other,
        "recipient_id" => me
      })

      assert wait_until(fn -> history_ids(me) == [direct] end)
    end

    test "the same event delivered twice leaves a single entry", ctx do
      %{chan: chan, me: me, other: other} = ctx
      message_id = later(10)

      payload = %{
        "conversation_id" => "conv-" <> me,
        "message_id" => message_id,
        "author_id" => other,
        "recipient_id" => me
      }

      publish(chan, "messaging.direct_message_created", payload)
      publish(chan, "messaging.direct_message_created", payload)

      assert wait_until(fn -> history_ids(me) == [message_id] end)
      Process.sleep(300)
      assert history_ids(me) == [message_id]
    end

    defp history_ids(user) do
      case Notifications.History.list(user) do
        {:ok, %{items: items}} -> Enum.map(items, & &1["message_id"])
        {:error, _reason} -> nil
      end
    end

    defp audit(event_id),
      do: Mongo.find_one(Notifications.Mongo, "consumed_events", %{"_id" => event_id})

    defp message_count(chan, queue) do
      {:ok, %{message_count: count}} = AMQP.Queue.declare(chan, queue, durable: true)
      count
    end
  end
end
