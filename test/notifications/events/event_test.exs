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
               messaging.message_created messaging.direct_message_created
               messaging.message_updated messaging.message_deleted
               users.profile_updated servers.server_updated messaging.user_presence_changed
               voice.private_call platform.status_changed platform.health_changed
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

  test "messaging.message_created carries the channel name and the preview when present" do
    payload =
      base(%{
        "server_id" => "s1",
        "channel_id" => "c1",
        "message_id" => "m1",
        "author_id" => "u1",
        "mentioned_user_ids" => [],
        "channel_name" => "general",
        "content_preview" => "hola"
      })

    assert {:ok, %Event.MessageCreated{channel_name: "general", content_preview: "hola"}} =
             Event.parse("messaging.message_created", payload)
  end

  test "messaging.message_created without channel name or preview still parses" do
    payload =
      base(%{
        "server_id" => "s1",
        "channel_id" => "c1",
        "message_id" => "m1",
        "author_id" => "u1",
        "mentioned_user_ids" => [],
        "content_preview" => ""
      })

    assert {:ok, %Event.MessageCreated{channel_name: nil, content_preview: nil}} =
             Event.parse("messaging.message_created", payload)
  end

  test "messaging.direct_message_created carries the preview when present" do
    payload =
      base(%{
        "conversation_id" => "conv-1",
        "message_id" => "m1",
        "author_id" => "u1",
        "recipient_id" => "u2",
        "content_preview" => "hola"
      })

    assert {:ok, %Event.DirectMessageCreated{content_preview: "hola"}} =
             Event.parse("messaging.direct_message_created", payload)
  end

  test "parses a private voice call event" do
    payload =
      base(%{
        "call_id" => "call-1",
        "conversation_id" => "conversation-1",
        "caller_id" => "caller-1",
        "recipient_id" => "recipient-1",
        "status" => "ringing"
      })

    assert {:ok,
            %Event.PrivateCall{
              call_id: "call-1",
              conversation_id: "conversation-1",
              caller_id: "caller-1",
              recipient_id: "recipient-1",
              status: "ringing"
            }} = Event.parse("voice.private_call", payload)
  end

  test "parses platform.status_changed" do
    payload = base(%{"status" => "degraded"})

    assert {:ok, %Event.PlatformStatusChanged{status: "degraded"}} =
             Event.parse("platform.status_changed", payload)
  end

  test "parses platform.health_changed with its staff audience" do
    payload =
      base(%{
        "service" => "servers",
        "previous_status" => "operational",
        "status" => "degraded",
        "consecutive_failures" => 2,
        "audience_user_ids" => ["u1", "u1", "u2"]
      })

    assert {:ok,
            %Event.PlatformHealthChanged{
              service: "servers",
              previous_status: "operational",
              status: "degraded",
              consecutive_failures: 2,
              audience_user_ids: ["u1", "u2"]
            }} = Event.parse("platform.health_changed", payload)
  end

  test "parses messaging.message_updated with the mentions it has after the edit" do
    payload =
      base(%{
        "server_id" => "s1",
        "channel_id" => "c1",
        "message_id" => "m1",
        "author_id" => "u1",
        "mentioned_user_ids" => ["u2", "u2"],
        "channel_name" => "general",
        "content_preview" => "hola @usuario"
      })

    assert {:ok,
            %Event.MessageUpdated{
              server_id: "s1",
              channel_id: "c1",
              message_id: "m1",
              author_id: "u1",
              mentioned_user_ids: ["u2"],
              channel_name: "general",
              content_preview: "hola @usuario"
            }} = Event.parse("messaging.message_updated", payload)
  end

  test "messaging.message_updated needs every id and a mention list" do
    payload =
      base(%{
        "server_id" => "s1",
        "channel_id" => "c1",
        "message_id" => "m1",
        "author_id" => "u1",
        "mentioned_user_ids" => []
      })

    assert {:ok, %Event.MessageUpdated{channel_name: nil, content_preview: nil}} =
             Event.parse("messaging.message_updated", payload)

    for key <- ~w(server_id channel_id message_id author_id mentioned_user_ids) do
      assert Event.parse("messaging.message_updated", Map.delete(payload, key)) ==
               {:error, :invalid_payload}
    end
  end

  test "parses messaging.message_deleted of a channel and of a direct message" do
    payload = base(%{"channel_id" => "c1", "message_id" => "m1", "author_id" => "u1"})

    assert {:ok, %Event.MessageDeleted{server_id: nil, channel_id: "c1", message_id: "m1"}} =
             Event.parse("messaging.message_deleted", payload)

    assert {:ok, %Event.MessageDeleted{server_id: "s1"}} =
             Event.parse("messaging.message_deleted", Map.put(payload, "server_id", "s1"))

    for key <- ~w(channel_id message_id author_id) do
      assert Event.parse("messaging.message_deleted", Map.delete(payload, key)) ==
               {:error, :invalid_payload}
    end
  end

  test "parses users.profile_updated keeping only id, name and version" do
    payload =
      base(%{
        "user_id" => "u1",
        "version" => 4,
        "name" => "Beto",
        "avatar_url" => "x",
        "description" => "y"
      })

    assert {:ok, %Event.UserProfileUpdated{user_id: "u1", name: "Beto", version: 4}} =
             Event.parse("users.profile_updated", payload)
  end

  test "users.profile_updated rejects a missing name or a bad version" do
    payload = base(%{"user_id" => "u1", "version" => 4, "name" => "Beto"})

    assert Event.parse("users.profile_updated", Map.delete(payload, "name")) ==
             {:error, :invalid_payload}

    for version <- [-1, "4", nil] do
      assert Event.parse("users.profile_updated", Map.put(payload, "version", version)) ==
               {:error, :invalid_payload}
    end
  end

  test "parses servers.server_updated keeping only id and name" do
    payload = base(%{"server_id" => "s1", "name" => "Mi server", "owner_id" => "u1"})

    assert {:ok, %Event.ServerUpdated{server_id: "s1", name: "Mi server"}} =
             Event.parse("servers.server_updated", payload)

    assert Event.parse("servers.server_updated", Map.delete(payload, "name")) ==
             {:error, :invalid_payload}
  end

  test "parses messaging.user_presence_changed" do
    payload =
      base(%{
        "user_id" => "u1",
        "connections" => "idle",
        "do_not_disturb" => true,
        "version" => 9
      })

    assert {:ok,
            %Event.UserPresenceChanged{
              user_id: "u1",
              connections: "idle",
              do_not_disturb: true,
              version: 9
            }} = Event.parse("messaging.user_presence_changed", payload)
  end

  test "messaging.user_presence_changed rejects unknown states and missing fields" do
    payload =
      base(%{
        "user_id" => "u1",
        "connections" => "active",
        "do_not_disturb" => false,
        "version" => 1
      })

    assert {:ok, _event} = Event.parse("messaging.user_presence_changed", payload)

    for bad <- [
          Map.put(payload, "connections", "online"),
          Map.delete(payload, "do_not_disturb"),
          Map.put(payload, "do_not_disturb", "false"),
          Map.delete(payload, "version"),
          Map.delete(payload, "user_id")
        ] do
      assert Event.parse("messaging.user_presence_changed", bad) == {:error, :invalid_payload}
    end
  end

  test "parses messaging.direct_message_created" do
    payload =
      base(%{
        "conversation_id" => "conv-1",
        "message_id" => "m1",
        "author_id" => "u1",
        "recipient_id" => "u2"
      })

    assert {:ok,
            %Event.DirectMessageCreated{
              conversation_id: "conv-1",
              message_id: "m1",
              author_id: "u1",
              recipient_id: "u2",
              occurred_at: %DateTime{}
            }} = Event.parse("messaging.direct_message_created", payload)
  end

  test "messaging.direct_message_created needs every id" do
    payload =
      base(%{
        "conversation_id" => "conv-1",
        "message_id" => "m1",
        "author_id" => "u1",
        "recipient_id" => "u2"
      })

    for key <- ~w(conversation_id message_id author_id recipient_id) do
      assert Event.parse("messaging.direct_message_created", Map.delete(payload, key)) ==
               {:error, :invalid_payload}

      assert Event.parse("messaging.direct_message_created", Map.put(payload, key, "")) ==
               {:error, :invalid_payload}
    end
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
