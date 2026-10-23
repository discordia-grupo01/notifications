defmodule Notifications.Events.EventTest do
  use ExUnit.Case, async: true

  alias Notifications.Events.Event

  @at "2026-10-23T12:00:00.000000Z"

  defp base(extra), do: Map.merge(%{"event_id" => "e1", "occurred_at" => @at}, extra)

  test "routing_keys/0 lists everything the service binds" do
    assert Enum.sort(Event.routing_keys()) ==
             Enum.sort(~w(
               servers.channel_created servers.channel_deleted servers.server_deleted
               servers.member_joined servers.member_left servers.role_updated
               servers.role_deleted servers.member_roles_updated
               servers.channel_overrides_updated servers.owner_updated
               messaging.message_created
             ))
  end

  test "parses messaging.message_created" do
    payload =
      base(%{
        "server_id" => "s1",
        "channel_id" => "c1",
        "message_id" => "m1",
        "author_id" => "u1",
        "mentioned_user_ids" => ["u2", "u2", "u3"]
      })

    assert {:ok,
            %Event.MessageCreated{
              server_id: "s1",
              channel_id: "c1",
              message_id: "m1",
              author_id: "u1",
              mentioned_user_ids: ["u2", "u3"],
              occurred_at: %DateTime{}
            }} = Event.parse("messaging.message_created", payload)
  end

  test "parses every servers.* event" do
    cases = [
      {"servers.channel_created",
       %{"server_id" => "s", "channel_id" => "c", "name" => "n", "kind" => "text"},
       Event.ChannelCreated},
      {"servers.channel_deleted", %{"server_id" => "s", "channel_id" => "c"},
       Event.ChannelDeleted},
      {"servers.server_deleted", %{"server_id" => "s", "channel_ids" => ["c"]},
       Event.ServerDeleted},
      {"servers.member_joined", %{"server_id" => "s", "user_id" => "u"}, Event.MemberJoined},
      {"servers.member_left", %{"server_id" => "s", "user_id" => "u"}, Event.MemberLeft},
      {"servers.role_updated",
       %{
         "server_id" => "s",
         "role_id" => "r",
         "permissions" => ["VIEW_CHANNELS"],
         "is_everyone" => true
       }, Event.RoleUpdated},
      {"servers.role_deleted", %{"server_id" => "s", "role_id" => "r"}, Event.RoleDeleted},
      {"servers.member_roles_updated",
       %{"server_id" => "s", "user_id" => "u", "role_ids" => ["r", "r"]},
       Event.MemberRolesUpdated},
      {"servers.channel_overrides_updated",
       %{
         "server_id" => "s",
         "channel_id" => "c",
         "overrides" => [%{"role_id" => "r", "allow" => ["VIEW_CHANNELS"], "deny" => []}]
       }, Event.ChannelOverridesUpdated},
      {"servers.owner_updated", %{"server_id" => "s", "owner_id" => "u"}, Event.OwnerUpdated}
    ]

    for {key, extra, module} <- cases do
      assert {:ok, %^module{event_id: "e1"}} = Event.parse(key, base(extra)), key
    end
  end

  test "deduplicates role ids" do
    payload = base(%{"server_id" => "s", "user_id" => "u", "role_ids" => ["r", "r"]})

    assert {:ok, %Event.MemberRolesUpdated{role_ids: ["r"]}} =
             Event.parse("servers.member_roles_updated", payload)
  end

  test "an unknown routing key is rejected" do
    assert Event.parse("servers.something_else", base(%{})) == {:error, :unknown_routing_key}
  end

  test "a payload that is not a map is rejected" do
    assert Event.parse("servers.member_left", "nope") == {:error, :invalid_payload}
  end

  test "a missing or empty required field is rejected" do
    assert Event.parse("servers.member_left", base(%{"server_id" => "s"})) ==
             {:error, :invalid_payload}

    assert Event.parse("servers.member_left", base(%{"server_id" => "s", "user_id" => ""})) ==
             {:error, :invalid_payload}
  end

  test "a missing or malformed occurred_at is rejected" do
    payload = %{"event_id" => "e1", "server_id" => "s", "user_id" => "u"}

    assert Event.parse("servers.member_left", payload) == {:error, :invalid_payload}

    assert Event.parse("servers.member_left", Map.put(payload, "occurred_at", "yesterday")) ==
             {:error, :invalid_payload}

    assert Event.parse("servers.member_left", Map.put(payload, "occurred_at", 5)) ==
             {:error, :invalid_payload}
  end

  test "mentioned_user_ids must be a list of strings" do
    payload =
      base(%{
        "server_id" => "s",
        "channel_id" => "c",
        "message_id" => "m",
        "author_id" => "u",
        "mentioned_user_ids" => "u2"
      })

    assert Event.parse("messaging.message_created", payload) == {:error, :invalid_payload}

    assert Event.parse("messaging.message_created", %{payload | "mentioned_user_ids" => [1]}) ==
             {:error, :invalid_payload}
  end

  test "role_updated needs a boolean is_everyone and a list of permissions" do
    ok =
      base(%{"server_id" => "s", "role_id" => "r", "permissions" => [], "is_everyone" => false})

    assert {:ok, %Event.RoleUpdated{}} = Event.parse("servers.role_updated", ok)

    assert Event.parse("servers.role_updated", %{ok | "is_everyone" => "yes"}) ==
             {:error, :invalid_payload}

    assert Event.parse("servers.role_updated", %{ok | "permissions" => "all"}) ==
             {:error, :invalid_payload}
  end

  test "channel overrides reject malformed entries" do
    bad = [
      "x",
      [%{"role_id" => "r", "allow" => "a", "deny" => []}],
      [%{"role_id" => "", "allow" => [], "deny" => []}],
      [%{"role_id" => "r", "allow" => [1], "deny" => []}]
    ]

    for overrides <- bad do
      payload = base(%{"server_id" => "s", "channel_id" => "c", "overrides" => overrides})

      assert Event.parse("servers.channel_overrides_updated", payload) ==
               {:error, :invalid_payload}
    end
  end
end
