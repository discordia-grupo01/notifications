defmodule Notifications.Events.LifecycleTest do
  use ExUnit.Case, async: false
  import Mox

  alias Notifications.Events.{Event, Lifecycle}
  alias Notifications.Delivery.RepoMock, as: DeliveryRepoMock
  alias Notifications.PushMock
  alias Notifications.Unread.RepoMock

  setup :verify_on_exit!

  setup do
    stub(RepoMock, :list_settings_by_scope, fn _scopes -> {:ok, []} end)
    stub(DeliveryRepoMock, :list_push_disabled, fn _ids -> {:ok, []} end)
    stub(DeliveryRepoMock, :get_presence, fn _ids -> {:ok, %{}} end)
    stub(DeliveryRepoMock, :list_devices, fn _ids -> {:ok, []} end)
    :ok
  end

  setup do
    stub(PushMock, :publish, fn _topic, _event, _payload -> :ok end)
    Application.put_env(:notifications, :push, PushMock)
    on_exit(fn -> Application.delete_env(:notifications, :push) end)
  end

  @at ~U[2026-10-23 12:00:00.000000Z]

  defp base(extra), do: Map.merge(%{event_id: "e1", occurred_at: @at}, extra)

  defp alive, do: expect(RepoMock, :get_clock, fn "server:s1" -> nil end)
  defp channel_alive, do: expect(RepoMock, :get_clock, fn "channel:c1" -> nil end)

  describe "servers.channel_created" do
    test "stores the channel and asks the server's sockets to resync" do
      event =
        struct!(
          Event.ChannelCreated,
          base(%{server_id: "s1", channel_id: "c1", name: "general", kind: "text"})
        )

      alive()
      expect(RepoMock, :apply_clock, fn "channel:c1", "created", @at, nil -> {:ok, :applied} end)

      expect(RepoMock, :upsert_channel, fn doc ->
        assert doc == %{"_id" => "c1", "server_id" => "s1", "name" => "general", "kind" => "text"}
        :ok
      end)

      expect(PushMock, :publish, fn "server:s1", "resync", %{} -> :ok end)

      assert Lifecycle.handle(event) == :ok
    end

    test "is ignored when the server was already deleted" do
      event =
        struct!(
          Event.ChannelCreated,
          base(%{server_id: "s1", channel_id: "c1", name: "g", kind: "text"})
        )

      expect(RepoMock, :get_clock, fn "server:s1" -> %{"state" => "deleted"} end)

      assert Lifecycle.handle(event) == {:ignored, :server_deleted}
    end

    test "is ignored when a newer event about the channel was already applied" do
      event =
        struct!(
          Event.ChannelCreated,
          base(%{server_id: "s1", channel_id: "c1", name: "g", kind: "text"})
        )

      alive()
      expect(RepoMock, :apply_clock, fn "channel:c1", "created", @at, nil -> {:ok, :stale} end)

      assert Lifecycle.handle(event) == {:ignored, :stale}
    end
  end

  test "servers.channel_deleted removes the channel with a tombstone and resyncs" do
    event = struct!(Event.ChannelDeleted, base(%{server_id: "s1", channel_id: "c1"}))

    expect(RepoMock, :apply_clock, fn "channel:c1", "deleted", @at, %DateTime{} ->
      {:ok, :applied}
    end)

    expect(RepoMock, :delete_channel, fn "c1" -> :ok end)
    expect(PushMock, :publish, fn "server:s1", "resync", %{} -> :ok end)

    assert Lifecycle.handle(event) == :ok
  end

  test "servers.server_deleted removes everything the service knows about the server" do
    event = struct!(Event.ServerDeleted, base(%{server_id: "s1", channel_ids: ["c1", "c2"]}))

    expect(RepoMock, :apply_clock, fn "server:s1", "deleted", @at, %DateTime{} ->
      {:ok, :applied}
    end)

    expect(RepoMock, :delete_server_data, fn "s1", ["c1", "c2"] -> :ok end)
    expect(PushMock, :publish, fn "server:s1", "changed", %{"resource" => "servers"} -> :ok end)
    expect(PushMock, :publish, fn "server:s1", "resync", %{} -> :ok end)

    assert Lifecycle.handle(event) == :ok
  end

  describe "membership" do
    test "servers.member_joined records the join and resyncs the user" do
      event = struct!(Event.MemberJoined, base(%{server_id: "s1", user_id: "u1"}))

      expect(RepoMock, :apply_clock, fn "member:s1:u1", "joined", @at, nil -> {:ok, :applied} end)
      expect(RepoMock, :record_member_joined, fn "s1", "u1", @at -> :ok end)
      expect(PushMock, :publish, fn "user:u1", "resync", %{} -> :ok end)

      assert Lifecycle.handle(event) == :ok
    end

    test "servers.member_left removes the member and resyncs the user" do
      event = struct!(Event.MemberLeft, base(%{server_id: "s1", user_id: "u1"}))

      expect(RepoMock, :apply_clock, fn "member:s1:u1", "left", @at, nil -> {:ok, :applied} end)
      expect(RepoMock, :delete_member, fn "s1", "u1", @at -> {:ok, :applied} end)
      expect(PushMock, :publish, fn "user:u1", "resync", %{} -> :ok end)

      assert Lifecycle.handle(event) == :ok
    end

    test "a stale join is ignored without touching the replica" do
      event = struct!(Event.MemberJoined, base(%{server_id: "s1", user_id: "u1"}))

      expect(RepoMock, :apply_clock, fn _key, _state, _at, _expires -> {:ok, :stale} end)

      assert Lifecycle.handle(event) == {:ignored, :stale}
    end

    test "servers.member_roles_updated writes the roles and resyncs the user" do
      event =
        struct!(
          Event.MemberRolesUpdated,
          base(%{server_id: "s1", user_id: "u1", role_ids: ["r1"]})
        )

      alive()
      expect(RepoMock, :apply_member_roles, fn "s1", "u1", ["r1"], @at -> {:ok, :applied} end)
      expect(PushMock, :publish, fn "user:u1", "resync", %{} -> :ok end)

      assert Lifecycle.handle(event) == :ok
    end
  end

  describe "replica of the server's permissions" do
    test "servers.role_updated" do
      event =
        struct!(
          Event.RoleUpdated,
          base(%{
            server_id: "s1",
            role_id: "r1",
            permissions: ["VIEW_CHANNELS"],
            is_everyone: true
          })
        )

      alive()

      expect(RepoMock, :apply_role, fn "s1", "r1", ["VIEW_CHANNELS"], true, @at ->
        {:ok, :applied}
      end)

      expect(PushMock, :publish, fn "server:s1", "resync", %{} -> :ok end)

      assert Lifecycle.handle(event) == :ok
    end

    test "servers.role_deleted" do
      event = struct!(Event.RoleDeleted, base(%{server_id: "s1", role_id: "r1"}))

      alive()
      expect(RepoMock, :delete_role, fn "s1", "r1", @at -> {:ok, :applied} end)
      expect(PushMock, :publish, fn "server:s1", "resync", %{} -> :ok end)

      assert Lifecycle.handle(event) == :ok
    end

    test "servers.channel_overrides_updated" do
      overrides = [%{role_id: "r1", allow: [], deny: ["VIEW_CHANNELS"]}]

      event =
        struct!(
          Event.ChannelOverridesUpdated,
          base(%{server_id: "s1", channel_id: "c1", overrides: overrides})
        )

      alive()

      expect(RepoMock, :apply_channel_overrides, fn "s1", "c1", ^overrides, @at ->
        {:ok, :applied}
      end)

      expect(PushMock, :publish, fn "server:s1", "resync", %{} -> :ok end)

      assert Lifecycle.handle(event) == :ok
    end

    test "servers.owner_updated" do
      event = struct!(Event.OwnerUpdated, base(%{server_id: "s1", owner_id: "u9"}))

      alive()
      expect(RepoMock, :apply_server_owner, fn "s1", "u9", @at -> {:ok, :applied} end)
      expect(PushMock, :publish, fn "server:s1", "resync", %{} -> :ok end)

      assert Lifecycle.handle(event) == :ok
    end

    test "a stale write does not resync" do
      event = struct!(Event.OwnerUpdated, base(%{server_id: "s1", owner_id: "u9"}))

      alive()
      expect(RepoMock, :apply_server_owner, fn _s, _o, _at -> {:ok, :stale} end)

      assert Lifecycle.handle(event) == {:ignored, :stale}
    end

    test "writes about a deleted server are ignored" do
      event = struct!(Event.OwnerUpdated, base(%{server_id: "s1", owner_id: "u9"}))

      expect(RepoMock, :get_clock, fn "server:s1" -> %{"state" => "deleted"} end)

      assert Lifecycle.handle(event) == {:ignored, :server_deleted}
    end
  end

  describe "messaging.message_created" do
    defp message_event(extra \\ %{}) do
      struct!(
        Event.MessageCreated,
        base(
          Map.merge(
            %{
              server_id: "s1",
              channel_id: "c1",
              message_id: "m1",
              author_id: "u1",
              mentioned_user_ids: ["u2"]
            },
            extra
          )
        )
      )
    end

    test "records the activity, the history of whoever it mentions and pushes it to the sockets" do
      alive()
      channel_alive()
      position = Notifications.Unread.Position.of(message_event().occurred_at, "m1")

      expect(RepoMock, :record_message, fn attrs ->
        assert attrs == %{
                 channel_id: "c1",
                 server_id: "s1",
                 message_id: "m1",
                 author_id: "u1",
                 mentioned_user_ids: ["u2"],
                 position: position
               }

        :ok
      end)

      expect(RepoMock, :list_settings_for, fn ["u2"], ["c1", "s1"] -> {:ok, []} end)

      expect(RepoMock, :put_history, fn [item] ->
        assert %{"_id" => "u2:m1", "user_id" => "u2", "kind" => "mention"} = item
        :ok
      end)

      expect(PushMock, :publish, fn "server:s1", "message_created", payload ->
        assert payload == %{
                 "server_id" => "s1",
                 "channel_id" => "c1",
                 "message_id" => "m1",
                 "author_id" => "u1",
                 "mentioned_user_ids" => ["u2"],
                 "position" => position
               }

        :ok
      end)

      assert Lifecycle.handle(message_event()) == :ok
    end

    test "a message that mentions nobody touches no history" do
      alive()
      channel_alive()
      expect(RepoMock, :record_message, fn _attrs -> :ok end)
      expect(PushMock, :publish, fn "server:s1", "message_created", _payload -> :ok end)

      assert Lifecycle.handle(message_event(%{mentioned_user_ids: []})) == :ok
    end

    test "a failure recording the history is returned so the event is retried" do
      alive()
      channel_alive()
      expect(RepoMock, :record_message, fn _attrs -> :ok end)
      expect(RepoMock, :list_settings_for, fn _users, _scopes -> {:error, :timeout} end)

      assert Lifecycle.handle(message_event()) == {:error, :timeout}
    end

    test "is ignored when the server was deleted" do
      expect(RepoMock, :get_clock, fn "server:s1" -> %{"state" => "deleted"} end)

      assert Lifecycle.handle(message_event()) == {:ignored, :server_deleted}
    end

    test "is ignored when the channel was already deleted" do
      alive()
      expect(RepoMock, :get_clock, fn "channel:c1" -> %{"state" => "deleted"} end)

      assert Lifecycle.handle(message_event()) == {:ignored, :channel_deleted}
    end

    test "a failure reading the channel clock is returned" do
      alive()
      expect(RepoMock, :get_clock, fn "channel:c1" -> {:error, :timeout} end)

      assert Lifecycle.handle(message_event()) == {:error, :timeout}
    end

    test "a storage failure is returned so the event is retried" do
      alive()
      channel_alive()
      expect(RepoMock, :record_message, fn _attrs -> {:error, :timeout} end)

      assert Lifecycle.handle(message_event()) == {:error, :timeout}
    end

    test "a push failure is returned so the event is retried" do
      alive()
      channel_alive()
      expect(RepoMock, :record_message, fn _attrs -> :ok end)
      expect(RepoMock, :list_settings_for, fn _users, _scopes -> {:ok, []} end)
      expect(RepoMock, :put_history, fn _items -> :ok end)
      expect(PushMock, :publish, fn _topic, _event, _payload -> {:error, :not_connected} end)

      assert Lifecycle.handle(message_event()) == {:error, :not_connected}
    end

    test "a failure reading the server clock is returned" do
      expect(RepoMock, :get_clock, fn "server:s1" -> {:error, :timeout} end)

      assert Lifecycle.handle(message_event()) == {:error, :timeout}
    end
  end

  describe "platform.status_changed" do
    test "publishes a refetch notification to the platform topic" do
      event = struct!(Event.PlatformStatusChanged, base(%{status: "degraded"}))

      expect(PushMock, :publish, fn "platform",
                                    "status_changed",
                                    %{
                                      "refetch" => true,
                                      "status" => "degraded"
                                    } ->
        :ok
      end)

      assert Lifecycle.handle(event) == :ok
    end

    test "platform.health_changed notifies each staff user's socket" do
      event =
        struct!(Event.PlatformHealthChanged, %{
          event_id: "e1",
          occurred_at: @at,
          service: "servers",
          previous_status: "operational",
          status: "degraded",
          consecutive_failures: 2,
          audience_user_ids: ["u1", "u2"]
        })

      expect(PushMock, :publish, 2, fn topic, "health_check_changed", payload ->
        assert topic in ["user:u1", "user:u2"]

        assert payload == %{
                 "service" => "servers",
                 "previous_status" => "operational",
                 "status" => "degraded",
                 "consecutive_failures" => 2
               }

        :ok
      end)

      assert Lifecycle.handle(event) == :ok
    end

    test "returns the push failure so the event can be retried" do
      event = struct!(Event.PlatformStatusChanged, base(%{status: "operational"}))

      expect(PushMock, :publish, fn "platform",
                                    "status_changed",
                                    %{
                                      "refetch" => true,
                                      "status" => "operational"
                                    } ->
        {:error, :pubsub_unavailable}
      end)

      assert Lifecycle.handle(event) == {:error, :pubsub_unavailable}
    end
  end

  describe "messaging.direct_message_created" do
    defp direct_event(extra \\ %{}) do
      struct!(
        Event.DirectMessageCreated,
        base(
          Map.merge(
            %{conversation_id: "conv-1", message_id: "m1", author_id: "u1", recipient_id: "u2"},
            extra
          )
        )
      )
    end

    test "records an entry in the recipient's history" do
      expect(RepoMock, :put_history, fn [item] ->
        assert %{
                 "_id" => "u2:m1",
                 "user_id" => "u2",
                 "kind" => "direct_message",
                 "conversation_id" => "conv-1",
                 "author_id" => "u1"
               } = item

        :ok
      end)

      assert Lifecycle.handle(direct_event()) == :ok
    end

    test "a message to oneself leaves nothing behind" do
      assert Lifecycle.handle(direct_event(%{recipient_id: "u1"})) == :ok
    end

    test "a storage failure is returned so the event is retried" do
      expect(RepoMock, :put_history, fn _items -> {:error, :timeout} end)

      assert Lifecycle.handle(direct_event()) == {:error, :timeout}
    end
  end

  describe "push" do
    test "a channel message notifies the devices of whoever it mentions" do
      alive()
      channel_alive()
      stub(RepoMock, :record_message, fn _attrs -> :ok end)
      stub(RepoMock, :list_settings_for, fn _users, _scopes -> {:ok, []} end)
      stub(RepoMock, :put_history, fn _items -> :ok end)
      stub(PushMock, :publish, fn _topic, _event, _payload -> :ok end)

      test_pid = self()

      expect(DeliveryRepoMock, :list_devices, fn ["u2"] ->
        send(test_pid, :devices_asked)
        {:ok, []}
      end)

      assert Lifecycle.handle(message_event()) == :ok
      assert_received :devices_asked
    end

    test "a direct message notifies the devices of the recipient" do
      test_pid = self()
      stub(RepoMock, :put_history, fn _items -> :ok end)

      expect(DeliveryRepoMock, :list_devices, fn ["u2"] ->
        send(test_pid, :devices_asked)
        {:ok, []}
      end)

      assert Lifecycle.handle(direct_event()) == :ok
      assert_received :devices_asked
    end

    test "a push problem never fails the event" do
      stub(RepoMock, :put_history, fn _items -> :ok end)
      stub(DeliveryRepoMock, :list_push_disabled, fn _ids -> {:error, :timeout} end)

      assert Lifecycle.handle(direct_event()) == :ok
    end
  end

  describe "messaging.message_updated" do
    defp updated_event(extra \\ %{}) do
      struct!(
        Event.MessageUpdated,
        base(
          Map.merge(
            %{
              server_id: "s1",
              channel_id: "c1",
              message_id: "m1",
              author_id: "u1",
              mentioned_user_ids: ["u2"],
              channel_name: "general",
              content_preview: "hola @usuario"
            },
            extra
          )
        )
      )
    end

    test "adds the entry of the newly mentioned user and pushes it as edited" do
      alive()
      channel_alive()
      expect(RepoMock, :list_history_mention_users, fn "m1" -> {:ok, []} end)
      expect(RepoMock, :list_settings_for, fn ["u2"], ["c1", "s1"] -> {:ok, []} end)

      expect(RepoMock, :put_history, fn [item] ->
        assert %{"_id" => "u2:m1", "kind" => "mention"} = item
        :ok
      end)

      test_pid = self()

      expect(DeliveryRepoMock, :list_devices, fn ["u2"] ->
        send(test_pid, :devices_asked)
        {:ok, []}
      end)

      assert Lifecycle.handle(updated_event()) == :ok
      assert_received :devices_asked
    end

    test "removes the entry of whoever stopped being mentioned and pushes nobody" do
      alive()
      channel_alive()
      expect(RepoMock, :list_history_mention_users, fn "m1" -> {:ok, ["u2"]} end)
      expect(RepoMock, :delete_history_entries, fn "m1", ["u2"] -> :ok end)

      assert Lifecycle.handle(updated_event(%{mentioned_user_ids: []})) == :ok
    end

    test "is ignored when the server or the channel was deleted" do
      expect(RepoMock, :get_clock, fn "server:s1" -> %{"state" => "deleted"} end)
      assert Lifecycle.handle(updated_event()) == {:ignored, :server_deleted}

      alive()
      expect(RepoMock, :get_clock, fn "channel:c1" -> %{"state" => "deleted"} end)
      assert Lifecycle.handle(updated_event()) == {:ignored, :channel_deleted}
    end

    test "a storage failure is returned so the event is retried" do
      alive()
      channel_alive()
      expect(RepoMock, :list_history_mention_users, fn _id -> {:error, :timeout} end)

      assert Lifecycle.handle(updated_event()) == {:error, :timeout}
    end

    test "a push problem never fails the edit" do
      alive()
      channel_alive()
      expect(RepoMock, :list_history_mention_users, fn _id -> {:ok, []} end)
      stub(RepoMock, :list_settings_for, fn _users, _scopes -> {:ok, []} end)
      stub(RepoMock, :put_history, fn _items -> :ok end)
      stub(DeliveryRepoMock, :list_push_disabled, fn _ids -> {:error, :timeout} end)

      assert Lifecycle.handle(updated_event()) == :ok
    end
  end

  describe "messaging.message_deleted" do
    defp deleted_event(extra \\ %{}),
      do:
        struct!(
          Event.MessageDeleted,
          base(Map.merge(%{channel_id: "c1", message_id: "m1", author_id: "u1"}, extra))
        )

    test "removes the entries that point at the message" do
      expect(RepoMock, :delete_history_entries, 2, fn "m1", :all -> :ok end)

      assert Lifecycle.handle(deleted_event()) == :ok
      assert Lifecycle.handle(deleted_event(%{server_id: "s1"})) == :ok
    end

    test "a storage failure is returned so the event is retried" do
      expect(RepoMock, :delete_history_entries, fn _id, _users -> {:error, :timeout} end)

      assert Lifecycle.handle(deleted_event()) == {:error, :timeout}
    end
  end

  describe "users.profile_updated" do
    defp profile_event(extra \\ %{}),
      do:
        struct!(
          Event.UserProfileUpdated,
          base(Map.merge(%{user_id: "u1", version: 3, name: "Ana"}, extra))
        )

    test "keeps the name of the user and tells everybody who shares a server with them" do
      expect(DeliveryRepoMock, :apply_user_name, fn "u1", "Ana", 3 -> {:ok, :applied} end)

      expect(RepoMock, :list_memberships, fn "u1" ->
        {:ok, [%{"server_id" => "s1"}, %{"server_id" => "s2"}]}
      end)

      test = self()

      stub(PushMock, :publish, fn topic, "changed", payload ->
        send(test, {:ping, topic, payload})
        :ok
      end)

      assert Lifecycle.handle(profile_event()) == :ok

      assert_received {:ping, "user:u1", %{"resource" => "profile", "user_id" => "u1"}}
      assert_received {:ping, "server:s1", %{"resource" => "profile", "user_id" => "u1"}}
      assert_received {:ping, "server:s2", %{"resource" => "profile", "user_id" => "u1"}}
    end

    test "an older version is ignored and nobody is told" do
      expect(DeliveryRepoMock, :apply_user_name, fn _id, _name, _version -> {:ok, :stale} end)
      test = self()

      stub(PushMock, :publish, fn topic, _event, _payload ->
        send(test, {:ping, topic})
        :ok
      end)

      assert Lifecycle.handle(profile_event()) == {:ignored, :stale}
      refute_received {:ping, _topic}
    end

    test "a storage failure is returned so the event is retried" do
      expect(DeliveryRepoMock, :apply_user_name, fn _id, _name, _version -> {:error, :timeout} end)

      assert Lifecycle.handle(profile_event()) == {:error, :timeout}
    end
  end

  describe "servers.server_updated" do
    defp server_event,
      do: struct!(Event.ServerUpdated, base(%{server_id: "s1", name: "Mi server"}))

    test "keeps the name of the server" do
      expect(DeliveryRepoMock, :apply_server_name, fn "s1", "Mi server", @at ->
        {:ok, :applied}
      end)

      assert Lifecycle.handle(server_event()) == :ok
    end

    test "an older snapshot is ignored and a failure is returned" do
      expect(DeliveryRepoMock, :apply_server_name, fn _id, _name, _at -> {:ok, :stale} end)
      expect(DeliveryRepoMock, :apply_server_name, fn _id, _name, _at -> {:error, :timeout} end)

      assert Lifecycle.handle(server_event()) == {:ignored, :stale}
      assert Lifecycle.handle(server_event()) == {:error, :timeout}
    end
  end

  describe "messaging.user_presence_changed" do
    defp presence_event(extra \\ %{}) do
      struct!(
        Event.UserPresenceChanged,
        base(
          Map.merge(
            %{user_id: "u1", connections: "active", do_not_disturb: false, version: 5},
            extra
          )
        )
      )
    end

    test "keeps the state with an expiry as a safety net" do
      expect(DeliveryRepoMock, :apply_presence, fn "u1", "active", false, 5, expires_at ->
        assert DateTime.diff(expires_at, DateTime.utc_now()) in 21_590..21_600
        {:ok, :applied}
      end)

      assert Lifecycle.handle(presence_event()) == :ok
    end

    test "an older version is ignored and a failure is returned" do
      expect(DeliveryRepoMock, :apply_presence, fn _u, _c, _d, _v, _at -> {:ok, :stale} end)
      expect(DeliveryRepoMock, :apply_presence, fn _u, _c, _d, _v, _at -> {:error, :timeout} end)

      assert Lifecycle.handle(presence_event()) == {:ignored, :stale}
      assert Lifecycle.handle(presence_event()) == {:error, :timeout}
    end
  end

  describe "servers.ownership_transfer_updated" do
    @created ~U[2026-10-23 11:00:00.000000Z]

    defp transfer_event(extra \\ %{}) do
      struct!(
        Event.OwnershipTransferUpdated,
        base(
          Map.merge(
            %{
              transfer_id: "t1",
              server_id: "s1",
              from_user_id: "owner",
              to_user_id: "member",
              status: "pending",
              created_at: @created,
              resolved_at: nil
            },
            extra
          )
        )
      )
    end

    test "records the entry for the recipient and tries to push it" do
      alive()

      expect(RepoMock, :apply_clock, fn "transfer:t1", "pending", @at, expires_at ->
        assert %DateTime{} = expires_at
        {:ok, :applied}
      end)

      expect(RepoMock, :upsert_history, fn [item] ->
        assert %{"_id" => "member:t1", "kind" => "ownership_transfer"} = item
        :ok
      end)

      expect(DeliveryRepoMock, :list_devices, fn ["member"] -> {:ok, []} end)

      assert Lifecycle.handle(transfer_event()) == :ok
    end

    test "the answer reaches the previous owner" do
      alive()

      expect(RepoMock, :apply_clock, fn "transfer:t1", "accepted", @at, _expires ->
        {:ok, :applied}
      end)

      expect(RepoMock, :upsert_history, fn items ->
        assert Enum.map(items, & &1["user_id"]) == ["member", "owner"]
        :ok
      end)

      expect(DeliveryRepoMock, :list_devices, fn ["owner"] -> {:ok, []} end)

      assert Lifecycle.handle(transfer_event(%{status: "accepted", resolved_at: @at})) == :ok
    end

    test "a stale snapshot is ignored and writes nothing" do
      alive()

      expect(RepoMock, :apply_clock, fn "transfer:t1", "pending", @at, _expires ->
        {:ok, :stale}
      end)

      assert Lifecycle.handle(transfer_event()) == {:ignored, :stale}
    end

    test "is ignored when the server was deleted" do
      expect(RepoMock, :get_clock, fn "server:s1" -> %{"state" => "deleted"} end)

      assert Lifecycle.handle(transfer_event()) == {:ignored, :server_deleted}
    end

    test "returns the error so the message is retried when the history can't be written" do
      alive()

      expect(RepoMock, :apply_clock, fn "transfer:t1", "pending", @at, _expires ->
        {:ok, :applied}
      end)

      expect(RepoMock, :upsert_history, fn _items -> {:error, :timeout} end)

      assert Lifecycle.handle(transfer_event()) == {:error, :timeout}
    end
  end
end
