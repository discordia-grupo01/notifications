mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Notifications.Unread.Repo.MongoTest do
    use ExUnit.Case, async: false

    alias Notifications.Unread.Repo.Mongo, as: Repo

    @t1 ~U[2026-10-23 12:00:00.000Z]
    @t2 ~U[2026-10-23 12:00:01.000Z]
    @t3 ~U[2026-10-23 12:00:02.000Z]

    @collections ~w(
      channels event_clocks channel_activity read_markers mention_markers
      replica_servers replica_roles replica_members replica_overrides notification_settings
      notification_history
    )

    setup do
      for collection <- @collections do
        {:ok, _result} = Mongo.delete_many(Notifications.Mongo, collection, %{})
      end

      assert :ok = Repo.ensure_indexes()
      id = Notifications.UUID.generate()
      {:ok, server: "srv-" <> id, channel: "chan-" <> id, user: "usr-" <> id}
    end

    defp message_id(n), do: "00000000-0000-7000-8000-" <> String.pad_leading("#{n}", 12, "0")

    defp record(channel, server, n, author, mentions \\ []) do
      Repo.record_message(%{
        channel_id: channel,
        server_id: server,
        message_id: message_id(n),
        author_id: author,
        mentioned_user_ids: mentions
      })
    end

    test "ping/0 answers when Mongo is reachable" do
      assert Repo.ping() == :ok
    end

    test "ensure_indexes/0 can run more than once" do
      assert Repo.ensure_indexes() == :ok
    end

    describe "event clocks" do
      test "the newest event wins and an older one is stale" do
        assert {:ok, :applied} = Repo.apply_clock("k", "created", @t2, nil)
        assert {:ok, :stale} = Repo.apply_clock("k", "deleted", @t1, nil)
        assert %{"state" => "created"} = Repo.get_clock("k")
        assert {:ok, :applied} = Repo.apply_clock("k", "deleted", @t3, @t3)
        assert %{"state" => "deleted", "expires_at" => %DateTime{}} = Repo.get_clock("k")
      end

      test "an unknown key has no clock" do
        assert Repo.get_clock("nope") == nil
      end
    end

    describe "channels" do
      test "upsert, read and list by server", %{server: server, channel: channel} do
        doc = %{"_id" => channel, "server_id" => server, "name" => "general", "kind" => "text"}

        assert Repo.upsert_channel(doc) == :ok
        assert Repo.upsert_channel(doc) == :ok
        assert %{"name" => "general"} = Repo.get_channel(channel)
        assert Repo.get_channel("nope") == nil
        assert {:ok, [^channel]} = Repo.list_channel_ids(server)
        assert {:ok, [%{"_id" => ^channel}]} = Repo.list_channels([server])
      end

      test "listing channels of no servers is empty" do
        assert Repo.list_channels([]) == {:ok, []}
      end

      test "deleting a channel removes its activity, markers and overrides", ctx do
        %{server: server, channel: channel, user: user} = ctx
        Repo.upsert_channel(%{"_id" => channel, "server_id" => server, "kind" => "text"})
        record(channel, server, 1, "someone", [user])
        Repo.mark_read(user, channel, server, message_id(1))
        Repo.apply_channel_overrides(server, channel, [], @t1)

        assert Repo.delete_channel(channel) == :ok

        assert Repo.get_channel(channel) == nil
        assert {:ok, %{}} = Repo.get_activity([channel])
        assert {:ok, %{}} = Repo.get_read_markers(user, [channel])
        assert {:ok, %{}} = Repo.get_mention_markers(user, [channel])
        assert {:ok, []} = Repo.list_overrides([server])
      end

      test "deleting a server removes everything it owns", ctx do
        %{server: server, channel: channel, user: user} = ctx
        Repo.upsert_channel(%{"_id" => channel, "server_id" => server, "kind" => "text"})
        record(channel, server, 1, "someone", [user])
        Repo.apply_server_owner(server, user, @t1)
        Repo.apply_role(server, "r1", ["VIEW_CHANNELS"], true, @t1)
        Repo.apply_member_roles(server, user, ["r1"], @t1)
        Repo.apply_channel_overrides(server, channel, [], @t1)

        assert Repo.delete_server_data(server, [channel]) == :ok

        assert {:ok, []} = Repo.list_channels([server])
        assert {:ok, []} = Repo.list_memberships(user)
        assert {:ok, []} = Repo.list_roles([server])
        assert {:ok, []} = Repo.list_overrides([server])
        assert {:ok, %{}} = Repo.get_server_owners([server])
        assert {:ok, %{}} = Repo.get_activity([channel])
        assert {:ok, %{}} = Repo.get_mention_markers(user, [channel])
      end
    end

    describe "activity and markers" do
      test "the last message of a channel only moves forward", %{server: s, channel: c} do
        record(c, s, 2, "a")
        record(c, s, 1, "a")

        assert {:ok, activity} = Repo.get_activity([c])
        assert activity[c] == message_id(2)
      end

      test "recording the same message twice changes nothing", %{server: s, channel: c} do
        record(c, s, 1, "a", ["b"])
        record(c, s, 1, "a", ["b"])

        assert {:ok, %{^c => id}} = Repo.get_activity([c])
        assert id == message_id(1)
        assert {:ok, %{^c => ^id}} = Repo.get_mention_markers("b", [c])
      end

      test "a message in an unknown channel registers it as a text channel", %{
        server: s,
        channel: c
      } do
        assert Repo.get_channel(c) == nil

        record(c, s, 1, "a")

        assert %{"_id" => ^c, "server_id" => ^s, "kind" => "text"} = Repo.get_channel(c)
      end

      test "a message never overwrites what is already known about the channel", %{
        server: s,
        channel: c
      } do
        Repo.upsert_channel(%{"_id" => c, "server_id" => s, "name" => "general", "kind" => "text"})

        record(c, s, 1, "a")

        assert %{"name" => "general"} = Repo.get_channel(c)
      end

      test "the author's own message counts as read for them", %{server: s, channel: c} do
        record(c, s, 3, "author")

        assert {:ok, %{^c => id}} = Repo.get_read_markers("author", [c])
        assert id == message_id(3)
        assert {:ok, markers} = Repo.get_read_markers("someone-else", [c])
        assert markers == %{}
      end

      test "every mentioned user gets a mention marker", %{server: s, channel: c} do
        record(c, s, 1, "author", ["m1", "m2"])
        record(c, s, 2, "author", ["m1"])

        assert {:ok, %{^c => latest}} = Repo.get_mention_markers("m1", [c])
        assert latest == message_id(2)
        assert {:ok, %{^c => first}} = Repo.get_mention_markers("m2", [c])
        assert first == message_id(1)
        assert {:ok, markers} = Repo.get_mention_markers("author", [c])
        assert markers == %{}
      end

      test "a read marker never goes backwards", %{server: s, channel: c} do
        Repo.mark_read("u", c, s, message_id(5))
        Repo.mark_read("u", c, s, message_id(2))

        assert {:ok, %{^c => id}} = Repo.get_read_markers("u", [c])
        assert id == message_id(5)
      end

      test "mark_all_read writes a marker per channel in one go", %{server: s, user: u} do
        entries =
          for n <- 1..5, do: %{channel_id: "c#{n}-#{u}", server_id: s, message_id: message_id(n)}

        assert Repo.mark_all_read(u, entries) == :ok

        ids = Enum.map(entries, & &1.channel_id)
        assert {:ok, markers} = Repo.get_read_markers(u, ids)
        assert map_size(markers) == 5
        assert markers["c3-#{u}"] == message_id(3)
      end

      test "mark_all_read never moves a marker backwards and is repeatable", %{
        server: s,
        channel: c,
        user: u
      } do
        Repo.mark_read(u, c, s, message_id(9))

        assert Repo.mark_all_read(u, [%{channel_id: c, server_id: s, message_id: message_id(4)}]) ==
                 :ok

        assert Repo.mark_all_read(u, [%{channel_id: c, server_id: s, message_id: message_id(4)}]) ==
                 :ok

        assert {:ok, %{^c => id}} = Repo.get_read_markers(u, [c])
        assert id == message_id(9)
      end

      test "mark_all_read leaves other users alone", %{server: s, channel: c, user: u} do
        Repo.mark_all_read(u, [%{channel_id: c, server_id: s, message_id: message_id(4)}])

        assert {:ok, markers} = Repo.get_read_markers("someone-else", [c])
        assert markers == %{}
      end

      test "mark_all_read with nothing to write is a no-op", %{user: u} do
        assert Repo.mark_all_read(u, []) == :ok
      end

      test "queries with no channels are empty" do
        assert Repo.get_activity([]) == {:ok, %{}}
        assert Repo.get_read_markers("u", []) == {:ok, %{}}
        assert Repo.get_mention_markers("u", []) == {:ok, %{}}
      end
    end

    describe "membership replica" do
      test "a join creates the membership with the join time", %{server: s, user: u} do
        assert Repo.record_member_joined(s, u, @t2) == :ok

        assert {:ok, [%{"server_id" => ^s, "joined_at" => joined, "role_ids" => []}]} =
                 Repo.list_memberships(u)

        assert joined == @t2
      end

      test "roles arrive before or after the join without losing it", %{server: s, user: u} do
        assert {:ok, :applied} = Repo.apply_member_roles(s, u, ["r1"], @t1)
        assert Repo.record_member_joined(s, u, @t2) == :ok

        assert {:ok, [%{"role_ids" => ["r1"], "joined_at" => joined}]} = Repo.list_memberships(u)
        assert joined == @t2
      end

      test "an older role update is stale", %{server: s, user: u} do
        assert {:ok, :applied} = Repo.apply_member_roles(s, u, ["new"], @t2)
        assert {:ok, :stale} = Repo.apply_member_roles(s, u, ["old"], @t1)

        assert {:ok, [%{"role_ids" => ["new"]}]} = Repo.list_memberships(u)
      end

      test "leaving removes the membership and the user's markers", ctx do
        %{server: s, channel: c, user: u} = ctx
        Repo.record_member_joined(s, u, @t1)
        Repo.mark_read(u, c, s, message_id(1))
        record(c, s, 2, "other", [u])

        assert {:ok, :applied} = Repo.delete_member(s, u, @t2)

        assert {:ok, []} = Repo.list_memberships(u)
        assert {:ok, markers} = Repo.get_read_markers(u, [c])
        assert markers == %{}
        assert {:ok, markers} = Repo.get_mention_markers(u, [c])
        assert markers == %{}
      end

      test "rejoining after leaving brings the membership back, as new", %{server: s, user: u} do
        Repo.record_member_joined(s, u, @t1)
        Repo.apply_member_roles(s, u, ["r1"], @t1)
        Repo.delete_member(s, u, @t2)
        assert {:ok, []} = Repo.list_memberships(u)

        assert Repo.record_member_joined(s, u, @t3) == :ok

        assert {:ok, [%{"joined_at" => joined, "role_ids" => []}]} = Repo.list_memberships(u)
        assert joined == @t3
      end

      test "a leave older than the stored state is stale", %{server: s, user: u} do
        Repo.apply_member_roles(s, u, ["r1"], @t3)

        assert {:ok, :stale} = Repo.delete_member(s, u, @t1)
        assert {:ok, [_member]} = Repo.list_memberships(u)
      end

      test "a user without memberships gets an empty list" do
        assert {:ok, []} = Repo.list_memberships("nobody")
      end
    end

    describe "settings" do
      test "lists what the user configured and nothing from other users", %{
        server: s,
        channel: c,
        user: u
      } do
        assert :ok = Repo.put_setting(u, :server, s, s, %{muted: true})
        assert :ok = Repo.put_setting(u, :channel, c, s, %{level: "all"})
        assert :ok = Repo.put_setting("someone-else", :channel, c, s, %{muted: true})

        assert {:ok, docs} = Repo.list_settings(u)

        assert docs |> Enum.map(&{&1["scope"], &1["scope_id"], &1["server_id"]}) |> Enum.sort() ==
                 Enum.sort([{"server", s, s}, {"channel", c, s}])
      end

      test "a first write stores the identity and defaults the other field", %{
        server: s,
        channel: c,
        user: u
      } do
        assert :ok = Repo.put_setting(u, :channel, c, s, %{level: "none"})

        assert %{
                 "user_id" => ^u,
                 "scope" => "channel",
                 "scope_id" => ^c,
                 "server_id" => ^s,
                 "muted" => false,
                 "level" => "none"
               } = Repo.get_setting(u, c)
      end

      test "writing one field keeps the other", %{server: s, channel: c, user: u} do
        :ok = Repo.put_setting(u, :channel, c, s, %{muted: true})
        :ok = Repo.put_setting(u, :channel, c, s, %{level: "all"})

        assert %{"muted" => true, "level" => "all"} = Repo.get_setting(u, c)

        :ok = Repo.put_setting(u, :channel, c, s, %{muted: false})

        assert %{"muted" => false, "level" => "all"} = Repo.get_setting(u, c)
      end

      test "repeating a write keeps a single document", %{server: s, channel: c, user: u} do
        assert :ok = Repo.put_setting(u, :channel, c, s, %{muted: true})
        assert :ok = Repo.put_setting(u, :channel, c, s, %{muted: true})

        assert {:ok, [_one]} = Repo.list_settings(u)
      end

      test "CA3: unmuting a setting that has nothing else removes the document", %{
        server: s,
        channel: c,
        user: u
      } do
        :ok = Repo.put_setting(u, :channel, c, s, %{muted: true})

        assert :ok = Repo.put_setting(u, :channel, c, s, %{muted: false})

        assert Repo.get_setting(u, c) == nil
        assert {:ok, []} = Repo.list_settings(u)
      end

      test "clearing the level of an unmuted setting removes the document", %{
        server: s,
        channel: c,
        user: u
      } do
        :ok = Repo.put_setting(u, :channel, c, s, %{level: "all"})

        assert :ok = Repo.put_setting(u, :channel, c, s, %{level: nil})

        assert Repo.get_setting(u, c) == nil
      end

      test "clearing the level keeps a muted setting", %{server: s, channel: c, user: u} do
        :ok = Repo.put_setting(u, :channel, c, s, %{muted: true, level: "all"})

        assert :ok = Repo.put_setting(u, :channel, c, s, %{level: nil})

        assert %{"muted" => true, "level" => nil} = Repo.get_setting(u, c)
      end

      test "unmuting keeps a setting that still has a level", %{server: s, channel: c, user: u} do
        :ok = Repo.put_setting(u, :channel, c, s, %{muted: true, level: "none"})

        assert :ok = Repo.put_setting(u, :channel, c, s, %{muted: false})

        assert %{"muted" => false, "level" => "none"} = Repo.get_setting(u, c)
      end

      test "clearing something that never existed leaves nothing behind", %{
        channel: c,
        user: u
      } do
        assert :ok = Repo.put_setting(u, :channel, c, nil, %{muted: false, level: nil})

        assert Repo.get_setting(u, c) == nil
        assert {:ok, []} = Repo.list_settings(u)
      end

      test "clearing never overwrites the server the setting belongs to", %{
        server: s,
        channel: c,
        user: u
      } do
        :ok = Repo.put_setting(u, :channel, c, s, %{muted: true, level: "all"})

        assert :ok = Repo.put_setting(u, :channel, c, nil, %{level: nil})

        assert %{"server_id" => ^s} = Repo.get_setting(u, c)
      end

      test "settings of other users are never touched", %{server: s, channel: c, user: u} do
        :ok = Repo.put_setting(u, :channel, c, s, %{muted: true})
        :ok = Repo.put_setting("someone-else", :channel, c, s, %{muted: true})

        assert :ok = Repo.put_setting(u, :channel, c, s, %{muted: false})

        assert %{"muted" => true} = Repo.get_setting("someone-else", c)
      end

      test "deleting a channel removes everybody's settings of it", %{
        server: s,
        channel: c,
        user: u
      } do
        :ok = Repo.put_setting(u, :channel, c, s, %{level: "all"})
        :ok = Repo.put_setting("someone-else", :channel, c, s, %{muted: true})
        :ok = Repo.put_setting(u, :server, s, s, %{muted: true})

        assert :ok = Repo.delete_channel(c)

        assert {:ok, [%{"scope" => "server"}]} = Repo.list_settings(u)
        assert {:ok, []} = Repo.list_settings("someone-else")
      end

      test "deleting a server removes its settings and the ones of its channels", %{
        server: s,
        channel: c,
        user: u
      } do
        :ok = Repo.put_setting(u, :server, s, s, %{level: "none"})
        :ok = Repo.put_setting(u, :channel, c, s, %{muted: true})
        :ok = Repo.put_setting(u, :channel, "other-channel", "other-server", %{level: "all"})

        assert :ok = Repo.delete_server_data(s, [c])

        assert {:ok, [%{"scope_id" => "other-channel"}]} = Repo.list_settings(u)
      end

      test "leaving a server removes only that user's settings of it", %{
        server: s,
        channel: c,
        user: u
      } do
        :ok = Repo.put_setting(u, :server, s, s, %{level: "all"})
        :ok = Repo.put_setting(u, :channel, c, s, %{muted: true})
        :ok = Repo.put_setting(u, :channel, "other-channel", "other-server", %{level: "all"})
        :ok = Repo.put_setting("someone-else", :channel, c, s, %{muted: true})

        assert {:ok, :applied} = Repo.delete_member(s, u, @t2)

        assert {:ok, [%{"scope_id" => "other-channel"}]} = Repo.list_settings(u)
        assert {:ok, [_one]} = Repo.list_settings("someone-else")
      end
    end

    describe "history" do
      defp history_item(user, n, attrs) do
        Map.merge(
          %{
            "_id" => user <> ":" <> message_id(n),
            "user_id" => user,
            "kind" => "mention",
            "message_id" => message_id(n),
            "author_id" => "author",
            "occurred_at" => @t1,
            "expires_at" => DateTime.add(@t1, 7 * 24 * 60 * 60, :second)
          },
          attrs
        )
      end

      defp mention_item(user, n, server, channel),
        do: history_item(user, n, %{"server_id" => server, "channel_id" => channel})

      defp dm_item(user, n),
        do: history_item(user, n, %{"kind" => "direct_message", "conversation_id" => "conv"})

      defp ids(items), do: Enum.map(items, & &1["message_id"])

      test "lists a user's entries newest first and nobody else's", %{
        server: s,
        channel: c,
        user: u
      } do
        :ok =
          Repo.put_history([
            mention_item(u, 1, s, c),
            dm_item(u, 3),
            mention_item("other", 2, s, c)
          ])

        assert {:ok, items} = Repo.list_history(u, nil, 50)
        assert ids(items) == [message_id(3), message_id(1)]
      end

      test "an entry without expiry is stored and listed", %{server: s, channel: c, user: u} do
        item = u |> mention_item(1, s, c) |> Map.delete("expires_at")

        :ok = Repo.put_history([item])

        assert {:ok, [stored]} = Repo.list_history(u, nil, 50)
        assert stored["message_id"] == message_id(1)
        refute Map.has_key?(stored, "expires_at")
      end

      test "stores the entry with everything the page needs", %{server: s, channel: c, user: u} do
        :ok = Repo.put_history([mention_item(u, 1, s, c)])

        assert {:ok, [item]} = Repo.list_history(u, nil, 50)

        assert %{
                 "user_id" => ^u,
                 "kind" => "mention",
                 "server_id" => ^s,
                 "channel_id" => ^c,
                 "author_id" => "author",
                 "occurred_at" => %DateTime{},
                 "expires_at" => %DateTime{}
               } = item
      end

      test "writing the same entry again keeps a single one, untouched", %{
        server: s,
        channel: c,
        user: u
      } do
        :ok = Repo.put_history([mention_item(u, 1, s, c)])

        :ok =
          Repo.put_history([history_item(u, 1, %{"server_id" => s, "channel_id" => "changed"})])

        assert {:ok, [%{"channel_id" => ^c}]} = Repo.list_history(u, nil, 50)
      end

      test "paginates with the cursor", %{server: s, channel: c, user: u} do
        :ok = Repo.put_history(for n <- 1..5, do: mention_item(u, n, s, c))

        assert {:ok, first} = Repo.list_history(u, nil, 2)
        assert ids(first) == [message_id(5), message_id(4)]

        assert {:ok, second} = Repo.list_history(u, {@t1, message_id(4)}, 2)
        assert ids(second) == [message_id(3), message_id(2)]

        assert {:ok, last} = Repo.list_history(u, {@t1, message_id(2)}, 2)
        assert ids(last) == [message_id(1)]

        assert {:ok, []} = Repo.list_history(u, {@t1, message_id(1)}, 2)
      end

      test "orders by when it happened, not by the message id", %{server: s, channel: c, user: u} do
        oldest = "ffffffff-ffff-5fff-8fff-ffffffffffff"
        middle = "00000000-0000-5000-8000-000000000000"
        newest = "80000000-0000-5000-8000-000000000000"

        :ok =
          Repo.put_history([
            mention_item(u, 1, s, c) |> hashed(oldest, @t1),
            mention_item(u, 2, s, c) |> hashed(middle, @t2),
            mention_item(u, 3, s, c) |> hashed(newest, DateTime.add(@t2, 1, :second))
          ])

        assert {:ok, items} = Repo.list_history(u, nil, 50)
        assert ids(items) == [newest, middle, oldest]
      end

      test "pages through entries with hashed ids without skipping or repeating", %{
        server: s,
        channel: c,
        user: u
      } do
        hashed = for n <- 1..6, do: "#{n}0000000-0000-5000-8000-00000000000#{7 - n}"

        :ok =
          Repo.put_history(
            hashed
            |> Enum.with_index()
            |> Enum.map(fn {id, index} ->
              mention_item(u, index + 1, s, c) |> hashed(id, DateTime.add(@t1, index, :second))
            end)
          )

        newest_first = Enum.reverse(hashed)
        assert {:ok, first} = Repo.list_history(u, nil, 2)
        assert ids(first) == Enum.take(newest_first, 2)

        position = fn items ->
          {List.last(items)["occurred_at"], List.last(items)["message_id"]}
        end

        assert {:ok, second} = Repo.list_history(u, position.(first), 2)
        assert ids(second) == newest_first |> Enum.drop(2) |> Enum.take(2)

        assert {:ok, third} = Repo.list_history(u, position.(second), 2)
        assert ids(third) == Enum.drop(newest_first, 4)

        assert {:ok, []} = Repo.list_history(u, position.(third), 2)
      end

      test "entries with the same instant are split by message id, in both directions", %{
        server: s,
        channel: c,
        user: u
      } do
        :ok = Repo.put_history(for n <- 1..3, do: mention_item(u, n, s, c))

        assert {:ok, [only]} = Repo.list_history(u, {@t1, message_id(3)}, 1)
        assert only["message_id"] == message_id(2)

        assert {:ok, older} =
                 Repo.list_history(u, {DateTime.add(@t1, 1, :second), message_id(1)}, 50)

        assert ids(older) == [message_id(3), message_id(2), message_id(1)]
      end

      defp hashed(item, id, at) do
        item
        |> Map.put("_id", item["user_id"] <> ":" <> id)
        |> Map.put("message_id", id)
        |> Map.put("occurred_at", at)
      end

      test "an empty history is an empty list", %{user: u} do
        assert {:ok, []} = Repo.list_history(u, nil, 50)
      end

      test "writing nothing is fine" do
        assert :ok = Repo.put_history([])
      end

      test "lists the settings of the given users for the given scopes only", %{
        server: s,
        channel: c,
        user: u
      } do
        :ok = Repo.put_setting(u, :channel, c, s, %{muted: true})
        :ok = Repo.put_setting(u, :server, s, s, %{level: "none"})
        :ok = Repo.put_setting(u, :channel, "unrelated", s, %{muted: true})
        :ok = Repo.put_setting("not-asked", :channel, c, s, %{muted: true})

        assert {:ok, docs} = Repo.list_settings_for([u, "missing"], [c, s])

        assert docs |> Enum.map(&{&1["user_id"], &1["scope_id"]}) |> Enum.sort() ==
                 Enum.sort([{u, c}, {u, s}])
      end

      test "deleting a channel removes its mention entries and keeps the rest", %{
        server: s,
        channel: c,
        user: u
      } do
        :ok =
          Repo.put_history([
            mention_item(u, 1, s, c),
            mention_item("other", 2, s, c),
            mention_item(u, 3, s, "another-channel"),
            dm_item(u, 4)
          ])

        assert :ok = Repo.delete_channel(c)

        assert {:ok, items} = Repo.list_history(u, nil, 50)
        assert ids(items) == [message_id(4), message_id(3)]
        assert {:ok, []} = Repo.list_history("other", nil, 50)
      end

      test "deleting a server removes its mention entries and keeps the direct messages", %{
        server: s,
        channel: c,
        user: u
      } do
        :ok =
          Repo.put_history([
            mention_item(u, 1, s, c),
            mention_item(u, 2, "another-server", "another-channel"),
            dm_item(u, 3)
          ])

        assert :ok = Repo.delete_server_data(s, [c])

        assert {:ok, items} = Repo.list_history(u, nil, 50)
        assert ids(items) == [message_id(3), message_id(2)]
      end

      test "leaving a server removes only that user's entries of it", %{
        server: s,
        channel: c,
        user: u
      } do
        :ok =
          Repo.put_history([
            mention_item(u, 1, s, c),
            mention_item("other", 2, s, c),
            mention_item(u, 3, "another-server", "another-channel"),
            dm_item(u, 4)
          ])

        assert {:ok, :applied} = Repo.delete_member(s, u, @t2)

        assert {:ok, items} = Repo.list_history(u, nil, 50)
        assert ids(items) == [message_id(4), message_id(3)]
        assert {:ok, [_one]} = Repo.list_history("other", nil, 50)
      end

      test "the indexes include the expiry of the entries" do
        assert :ok = Repo.ensure_indexes()

        names =
          Notifications.Mongo
          |> Mongo.list_indexes("notification_history")
          |> Enum.map(& &1["name"])

        assert "history_expires_at_ttl" in names
        assert "by_user_timeline" in names
      end
    end

    describe "permissions replica" do
      test "owner", %{server: s} do
        assert {:ok, :applied} = Repo.apply_server_owner(s, "u1", @t1)
        assert {:ok, :applied} = Repo.apply_server_owner(s, "u2", @t2)
        assert {:ok, :stale} = Repo.apply_server_owner(s, "u0", @t1)

        assert {:ok, %{^s => "u2"}} = Repo.get_server_owners([s])
        assert Repo.get_server_owners([]) == {:ok, %{}}
      end

      test "roles are stored, updated and tombstoned", %{server: s} do
        assert {:ok, :applied} = Repo.apply_role(s, "r1", ["VIEW_CHANNELS"], true, @t1)

        assert {:ok, :applied} =
                 Repo.apply_role(s, "r1", ["VIEW_CHANNELS", "SEND_MESSAGES"], true, @t2)

        assert {:ok, :stale} = Repo.apply_role(s, "r1", [], false, @t1)

        assert {:ok, [%{"_id" => "r1", "permissions" => ["VIEW_CHANNELS", "SEND_MESSAGES"]}]} =
                 Repo.list_roles([s])

        assert {:ok, :applied} = Repo.delete_role(s, "r1", @t3)
        assert {:ok, []} = Repo.list_roles([s])
        assert {:ok, :stale} = Repo.apply_role(s, "r1", ["VIEW_CHANNELS"], true, @t2)
      end

      test "deleting a role removes it from members and overrides", ctx do
        %{server: s, channel: c, user: u} = ctx
        Repo.apply_role(s, "r1", ["VIEW_CHANNELS"], false, @t1)
        Repo.apply_member_roles(s, u, ["r1", "r2"], @t1)

        Repo.apply_channel_overrides(
          s,
          c,
          [
            %{role_id: "r1", allow: [], deny: ["VIEW_CHANNELS"]},
            %{role_id: "r2", allow: [], deny: []}
          ],
          @t1
        )

        assert {:ok, :applied} = Repo.delete_role(s, "r1", @t2)

        assert {:ok, [%{"role_ids" => ["r2"]}]} = Repo.list_memberships(u)
        assert {:ok, [%{"overrides" => [%{"role_id" => "r2"}]}]} = Repo.list_overrides([s])
      end

      test "overrides are replaced as a whole by the newest event", %{server: s, channel: c} do
        first = [%{role_id: "r1", allow: ["VIEW_CHANNELS"], deny: []}]

        assert {:ok, :applied} = Repo.apply_channel_overrides(s, c, first, @t1)
        assert {:ok, :applied} = Repo.apply_channel_overrides(s, c, [], @t2)
        assert {:ok, :stale} = Repo.apply_channel_overrides(s, c, first, @t1)

        assert {:ok, [%{"_id" => ^c, "overrides" => []}]} = Repo.list_overrides([s])
      end
    end
  end
end
