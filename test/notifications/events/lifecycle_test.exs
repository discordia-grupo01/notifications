defmodule Notifications.Events.LifecycleTest do
  use ExUnit.Case, async: false
  import Mox

  alias Notifications.Events.{Event, Lifecycle}
  alias Notifications.PushMock
  alias Notifications.Unread.RepoMock

  setup :verify_on_exit!

  setup do
    Application.put_env(:notifications, :push, PushMock)
    on_exit(fn -> Application.delete_env(:notifications, :push) end)
  end

  @at ~U[2026-10-23 12:00:00.000000Z]

  defp base(extra), do: Map.merge(%{event_id: "e1", occurred_at: @at}, extra)

  defp alive, do: expect(RepoMock, :get_clock, fn "server:s1" -> nil end)

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

    test "records the activity and pushes it to the server's sockets" do
      alive()

      expect(RepoMock, :record_message, fn attrs ->
        assert attrs == %{
                 channel_id: "c1",
                 server_id: "s1",
                 message_id: "m1",
                 author_id: "u1",
                 mentioned_user_ids: ["u2"]
               }

        :ok
      end)

      expect(PushMock, :publish, fn "server:s1", "message_created", payload ->
        assert payload == %{
                 "server_id" => "s1",
                 "channel_id" => "c1",
                 "message_id" => "m1",
                 "author_id" => "u1",
                 "mentioned_user_ids" => ["u2"]
               }

        :ok
      end)

      assert Lifecycle.handle(message_event()) == :ok
    end

    test "is ignored when the server was deleted" do
      expect(RepoMock, :get_clock, fn "server:s1" -> %{"state" => "deleted"} end)

      assert Lifecycle.handle(message_event()) == {:ignored, :server_deleted}
    end

    test "a storage failure is returned so the event is retried" do
      alive()
      expect(RepoMock, :record_message, fn _attrs -> {:error, :timeout} end)

      assert Lifecycle.handle(message_event()) == {:error, :timeout}
    end

    test "a push failure is returned so the event is retried" do
      alive()
      expect(RepoMock, :record_message, fn _attrs -> :ok end)
      expect(PushMock, :publish, fn _topic, _event, _payload -> {:error, :not_connected} end)

      assert Lifecycle.handle(message_event()) == {:error, :not_connected}
    end

    test "a failure reading the server clock is returned" do
      expect(RepoMock, :get_clock, fn "server:s1" -> {:error, :timeout} end)

      assert Lifecycle.handle(message_event()) == {:error, :timeout}
    end
  end
end
