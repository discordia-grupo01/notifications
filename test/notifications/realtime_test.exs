defmodule Notifications.RealtimeTest do
  use ExUnit.Case, async: false
  import Mox

  alias Notifications.Events.Event
  alias Notifications.PushMock
  alias Notifications.Realtime
  alias Notifications.Unread.RepoMock

  setup :verify_on_exit!

  setup do
    Application.put_env(:notifications, :push, PushMock)
    on_exit(fn -> Application.delete_env(:notifications, :push) end)
    test = self()

    stub(PushMock, :publish, fn topic, "changed", payload ->
      send(test, {:ping, topic, payload})
      :ok
    end)

    :ok
  end

  @at ~U[2026-11-11 12:00:00.000000Z]

  defp pings_of(event) do
    Realtime.after_event(event)
    collect([])
  end

  defp collect(acc) do
    receive do
      {:ping, topic, payload} -> collect([{topic, payload} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp ping_event(key, fields),
    do: %Event.Ping{event_id: "e1", occurred_at: @at, routing_key: key, fields: fields}

  test "a new member updates the member list of the server and the server list of that user" do
    event =
      struct!(Event.MemberJoined, event_id: "e", occurred_at: @at, server_id: "s1", user_id: "u1")

    assert pings_of(event) == [
             {"server:s1", %{"resource" => "members", "server_id" => "s1"}},
             {"user:u1", %{"resource" => "servers", "server_id" => "s1"}},
             {"server:s1", %{"resource" => "metrics", "server_id" => "s1"}}
           ]
  end

  test "a member who leaves does the same" do
    event =
      struct!(Event.MemberLeft, event_id: "e", occurred_at: @at, server_id: "s1", user_id: "u1")

    assert [
             {"server:s1", %{"resource" => "members"}},
             {"user:u1", %{"resource" => "servers"}},
             {"server:s1", %{"resource" => "metrics"}}
           ] = pings_of(event)
  end

  test "channels, roles and owner changes tell the server what to ask for again" do
    for {module, fields, expected} <- [
          {Event.ChannelCreated, %{channel_id: "c", name: "n", kind: "text"}, ["channels"]},
          {Event.ChannelDeleted, %{channel_id: "c"}, ["channels"]},
          {Event.ChannelOverridesUpdated, %{channel_id: "c", overrides: []}, ["channels"]},
          {Event.RoleUpdated, %{role_id: "r", permissions: [], is_everyone: false},
           ["roles", "channels"]},
          {Event.RoleDeleted, %{role_id: "r"}, ["roles", "channels"]},
          {Event.OwnerUpdated, %{owner_id: "o"}, ["server", "members", "roles"]},
          {Event.ServerUpdated, %{name: "n"}, ["server"]}
        ] do
      event =
        struct!(module, Map.merge(%{event_id: "e", occurred_at: @at, server_id: "s1"}, fields))

      assert pings_of(event) |> Enum.map(fn {"server:s1", %{"resource" => r}} -> r end) ==
               expected
    end
  end

  test "the roles of a member change the member list and what that user can see" do
    event =
      struct!(Event.MemberRolesUpdated,
        event_id: "e",
        occurred_at: @at,
        server_id: "s1",
        user_id: "u1",
        role_ids: ["r"]
      )

    assert pings_of(event) == [
             {"server:s1", %{"resource" => "members", "server_id" => "s1"}},
             {"user:u1", %{"resource" => "roles", "server_id" => "s1"}},
             {"user:u1", %{"resource" => "channels", "server_id" => "s1"}}
           ]
  end

  test "a profile change reaches the user and every server they belong to" do
    expect(RepoMock, :list_memberships, fn "u1" ->
      {:ok, [%{"server_id" => "s1"}, %{"server_id" => "s1"}, %{"server_id" => "s2"}]}
    end)

    event =
      struct!(Event.UserProfileUpdated,
        event_id: "e",
        occurred_at: @at,
        user_id: "u1",
        version: 2,
        name: "Ana"
      )

    assert pings_of(event) == [
             {"user:u1", %{"resource" => "profile", "user_id" => "u1"}},
             {"server:s1", %{"resource" => "profile", "server_id" => "s1", "user_id" => "u1"}},
             {"server:s2", %{"resource" => "profile", "server_id" => "s2", "user_id" => "u1"}}
           ]
  end

  test "a profile change still reaches the user when the memberships can't be read" do
    expect(RepoMock, :list_memberships, fn "u1" -> {:error, :timeout} end)

    event =
      struct!(Event.UserProfileUpdated,
        event_id: "e",
        occurred_at: @at,
        user_id: "u1",
        version: 2,
        name: "Ana"
      )

    assert [{"user:u1", %{"resource" => "profile"}}] = pings_of(event)
  end

  test "a message tells the server its metrics changed and each mentioned user their notifications" do
    event =
      struct!(Event.MessageCreated,
        event_id: "e",
        occurred_at: @at,
        server_id: "s1",
        channel_id: "c1",
        message_id: "m1",
        author_id: "a",
        mentioned_user_ids: ["u1", "u2"]
      )

    assert pings_of(event) == [
             {"server:s1", %{"resource" => "metrics", "server_id" => "s1"}},
             {"user:u1", %{"resource" => "notifications"}},
             {"user:u2", %{"resource" => "notifications"}}
           ]
  end

  test "a direct message and an ownership transfer refresh the notification center" do
    direct =
      struct!(Event.DirectMessageCreated,
        event_id: "e",
        occurred_at: @at,
        conversation_id: "c",
        message_id: "m",
        author_id: "a",
        recipient_id: "r"
      )

    assert pings_of(direct) == [{"user:r", %{"resource" => "notifications"}}]

    transfer =
      struct!(Event.OwnershipTransferUpdated,
        event_id: "e",
        occurred_at: @at,
        transfer_id: "t",
        server_id: "s1",
        from_user_id: "owner",
        to_user_id: "member",
        status: "pending",
        created_at: @at
      )

    assert pings_of(transfer) == [
             {"user:owner", %{"resource" => "notifications"}},
             {"user:member", %{"resource" => "notifications"}}
           ]
  end

  test "a deleted server is told before the server data goes away and not again after" do
    event =
      struct!(Event.ServerDeleted,
        event_id: "e",
        occurred_at: @at,
        server_id: "s1",
        channel_ids: []
      )

    Realtime.before_event(event)
    assert collect([]) == [{"server:s1", %{"resource" => "servers", "server_id" => "s1"}}]

    assert pings_of(event) == []
  end

  describe "events that only carry a ping" do
    test "moderation, filters and reports reach the server" do
      for {key, resources} <- [
            {"servers.member_banned", ["moderation", "members"]},
            {"servers.member_unbanned", ["moderation", "members"]},
            {"servers.member_kicked", ["moderation", "members"]},
            {"servers.member_muted", ["moderation", "members"]},
            {"servers.member_unmuted", ["moderation", "members"]},
            {"servers.word_filter_updated", ["moderation"]},
            {"servers.moderation_action_recorded", ["moderation"]},
            {"servers.report_updated", ["reports"]},
            {"servers.emoji_created", ["emojis"]},
            {"servers.emoji_deleted", ["emojis"]},
            {"servers.server_boost_updated", ["server"]}
          ] do
        pings = pings_of(ping_event(key, %{server_id: "s1", user_id: "u1"}))
        assert Enum.map(pings, fn {"server:s1", %{"resource" => r}} -> r end) == resources
      end
    end

    test "what servers says changed is passed on as it is" do
      for resource <- ["server", "channels", "roles"] do
        assert pings_of(
                 ping_event("servers.resource_changed", %{server_id: "s1", resource: resource})
               ) ==
                 [{"server:s1", %{"resource" => resource, "server_id" => "s1"}}]
      end

      assert pings_of(
               ping_event("servers.resource_changed", %{server_id: "s1", resource: "otra"})
             ) == []
    end

    test "points, boosts, purchases and premium reach only that user" do
      for resource <- ["points", "boosts", "purchases"] do
        assert pings_of(
                 ping_event("billing.account_changed", %{user_id: "u1", resource: resource})
               ) ==
                 [{"user:u1", %{"resource" => resource}}]
      end

      assert pings_of(ping_event("billing.premium_updated", %{user_id: "u1"})) == [
               {"user:u1", %{"resource" => "premium"}},
               {"user:u1", %{"resource" => "profile", "user_id" => "u1"}}
             ]
    end

    test "the back-office change reaches each staff member and says what changed" do
      event =
        ping_event("admin.backoffice_changed", %{
          resource: "servers",
          audience_user_ids: ["a", "b"]
        })

      assert pings_of(event) == [
               {"user:a", %{"resource" => "backoffice", "kind" => "servers"}},
               {"user:b", %{"resource" => "backoffice", "kind" => "servers"}}
             ]
    end
  end

  test "a failing push never breaks the event that caused it" do
    stub(PushMock, :publish, fn _topic, _event, _payload -> {:error, :down} end)

    event =
      struct!(Event.MemberJoined, event_id: "e", occurred_at: @at, server_id: "s1", user_id: "u1")

    assert Realtime.after_event(event) == :ok
  end

  test "an event with nothing to tell produces no ping" do
    event =
      struct!(Event.PlatformStatusChanged, event_id: "e", occurred_at: @at, status: "operational")

    assert pings_of(event) == []
  end
end
