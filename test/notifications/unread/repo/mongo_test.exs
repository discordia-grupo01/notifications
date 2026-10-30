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
      replica_servers replica_roles replica_members replica_overrides
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
