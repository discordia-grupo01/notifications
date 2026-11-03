defmodule Notifications.Events.Event do
  defmodule ChannelCreated do
    @enforce_keys [:event_id, :occurred_at, :server_id, :channel_id, :name, :kind]
    defstruct [:event_id, :occurred_at, :server_id, :channel_id, :name, :kind]
  end

  defmodule ChannelDeleted do
    @enforce_keys [:event_id, :occurred_at, :server_id, :channel_id]
    defstruct [:event_id, :occurred_at, :server_id, :channel_id]
  end

  defmodule ServerDeleted do
    @enforce_keys [:event_id, :occurred_at, :server_id, :channel_ids]
    defstruct [:event_id, :occurred_at, :server_id, :channel_ids]
  end

  defmodule MemberJoined do
    @enforce_keys [:event_id, :occurred_at, :server_id, :user_id]
    defstruct [:event_id, :occurred_at, :server_id, :user_id]
  end

  defmodule MemberLeft do
    @enforce_keys [:event_id, :occurred_at, :server_id, :user_id]
    defstruct [:event_id, :occurred_at, :server_id, :user_id]
  end

  defmodule RoleUpdated do
    @enforce_keys [:event_id, :occurred_at, :server_id, :role_id, :permissions, :is_everyone]
    defstruct [:event_id, :occurred_at, :server_id, :role_id, :permissions, :is_everyone]
  end

  defmodule RoleDeleted do
    @enforce_keys [:event_id, :occurred_at, :server_id, :role_id]
    defstruct [:event_id, :occurred_at, :server_id, :role_id]
  end

  defmodule MemberRolesUpdated do
    @enforce_keys [:event_id, :occurred_at, :server_id, :user_id, :role_ids]
    defstruct [:event_id, :occurred_at, :server_id, :user_id, :role_ids]
  end

  defmodule ChannelOverridesUpdated do
    @enforce_keys [:event_id, :occurred_at, :server_id, :channel_id, :overrides]
    defstruct [:event_id, :occurred_at, :server_id, :channel_id, :overrides]
  end

  defmodule OwnerUpdated do
    @enforce_keys [:event_id, :occurred_at, :server_id, :owner_id]
    defstruct [:event_id, :occurred_at, :server_id, :owner_id]
  end

  defmodule MessageCreated do
    @enforce_keys [
      :event_id,
      :occurred_at,
      :server_id,
      :channel_id,
      :message_id,
      :author_id,
      :mentioned_user_ids
    ]
    defstruct [
      :event_id,
      :occurred_at,
      :server_id,
      :channel_id,
      :message_id,
      :author_id,
      :mentioned_user_ids,
      :channel_name,
      :content_preview
    ]
  end

  defmodule DirectMessageCreated do
    @enforce_keys [
      :event_id,
      :occurred_at,
      :conversation_id,
      :message_id,
      :author_id,
      :recipient_id
    ]
    defstruct [
      :event_id,
      :occurred_at,
      :conversation_id,
      :message_id,
      :author_id,
      :recipient_id,
      :content_preview
    ]
  end

  defmodule MessageUpdated do
    @enforce_keys [
      :event_id,
      :occurred_at,
      :server_id,
      :channel_id,
      :message_id,
      :author_id,
      :mentioned_user_ids
    ]
    defstruct [
      :event_id,
      :occurred_at,
      :server_id,
      :channel_id,
      :message_id,
      :author_id,
      :mentioned_user_ids,
      :channel_name,
      :content_preview
    ]
  end

  defmodule MessageDeleted do
    @enforce_keys [:event_id, :occurred_at, :channel_id, :message_id, :author_id]
    defstruct [:event_id, :occurred_at, :server_id, :channel_id, :message_id, :author_id]
  end

  defmodule UserProfileUpdated do
    @enforce_keys [:event_id, :occurred_at, :user_id, :version, :name]
    defstruct [:event_id, :occurred_at, :user_id, :version, :name]
  end

  defmodule ServerUpdated do
    @enforce_keys [:event_id, :occurred_at, :server_id, :name]
    defstruct [:event_id, :occurred_at, :server_id, :name]
  end

  defmodule UserPresenceChanged do
    @enforce_keys [:event_id, :occurred_at, :user_id, :connections, :do_not_disturb, :version]
    defstruct [:event_id, :occurred_at, :user_id, :connections, :do_not_disturb, :version]
  end

  @routing_keys [
    {"servers.channel_created", ChannelCreated},
    {"servers.channel_deleted", ChannelDeleted},
    {"servers.server_deleted", ServerDeleted},
    {"servers.member_joined", MemberJoined},
    {"servers.member_left", MemberLeft},
    {"servers.role_updated", RoleUpdated},
    {"servers.role_deleted", RoleDeleted},
    {"servers.member_roles_updated", MemberRolesUpdated},
    {"servers.channel_overrides_updated", ChannelOverridesUpdated},
    {"servers.owner_updated", OwnerUpdated},
    {"messaging.message_created", MessageCreated},
    {"messaging.direct_message_created", DirectMessageCreated},
    {"messaging.message_updated", MessageUpdated},
    {"messaging.message_deleted", MessageDeleted},
    {"users.profile_updated", UserProfileUpdated},
    {"servers.server_updated", ServerUpdated},
    {"messaging.user_presence_changed", UserPresenceChanged}
  ]

  @connections ~w(active idle none)

  @spec routing_keys() :: [String.t()]
  def routing_keys, do: Enum.map(@routing_keys, &elem(&1, 0))

  @spec parse(String.t(), map()) ::
          {:ok, struct()} | {:error, :unknown_routing_key | :invalid_payload}
  def parse(routing_key, payload) when is_map(payload) do
    case List.keyfind(@routing_keys, routing_key, 0) do
      nil ->
        {:error, :unknown_routing_key}

      {_key, module} ->
        with {:ok, fields} <- fields(module, payload),
             {:ok, occurred_at} <- parse_time(Map.get(payload, "occurred_at")) do
          {:ok, struct!(module, Map.merge(fields, %{occurred_at: occurred_at}))}
        end
    end
  end

  def parse(_routing_key, _payload), do: {:error, :invalid_payload}

  defp fields(ChannelCreated, payload),
    do: strings(payload, ~w(event_id server_id channel_id name kind)a)

  defp fields(ChannelDeleted, payload), do: strings(payload, ~w(event_id server_id channel_id)a)

  defp fields(ServerDeleted, payload) do
    with {:ok, base} <- strings(payload, ~w(event_id server_id)a),
         {:ok, channel_ids} <- string_list(payload, "channel_ids") do
      {:ok, Map.put(base, :channel_ids, channel_ids)}
    end
  end

  defp fields(MemberJoined, payload), do: strings(payload, ~w(event_id server_id user_id)a)
  defp fields(MemberLeft, payload), do: strings(payload, ~w(event_id server_id user_id)a)
  defp fields(RoleDeleted, payload), do: strings(payload, ~w(event_id server_id role_id)a)
  defp fields(OwnerUpdated, payload), do: strings(payload, ~w(event_id server_id owner_id)a)

  defp fields(RoleUpdated, payload) do
    with {:ok, base} <- strings(payload, ~w(event_id server_id role_id)a),
         {:ok, permissions} <- string_list(payload, "permissions"),
         %{"is_everyone" => is_everyone} when is_boolean(is_everyone) <- payload do
      {:ok,
       base |> Map.put(:permissions, Enum.uniq(permissions)) |> Map.put(:is_everyone, is_everyone)}
    else
      _invalid -> {:error, :invalid_payload}
    end
  end

  defp fields(MemberRolesUpdated, payload) do
    with {:ok, base} <- strings(payload, ~w(event_id server_id user_id)a),
         {:ok, role_ids} <- string_list(payload, "role_ids") do
      {:ok, Map.put(base, :role_ids, Enum.uniq(role_ids))}
    end
  end

  defp fields(ChannelOverridesUpdated, payload) do
    with {:ok, base} <- strings(payload, ~w(event_id server_id channel_id)a),
         {:ok, overrides} <- parse_overrides(Map.get(payload, "overrides")) do
      {:ok, Map.put(base, :overrides, overrides)}
    end
  end

  defp fields(DirectMessageCreated, payload) do
    with {:ok, base} <-
           strings(payload, ~w(event_id conversation_id message_id author_id recipient_id)a) do
      {:ok, Map.put(base, :content_preview, optional_text(payload, "content_preview"))}
    end
  end

  defp fields(MessageCreated, payload) do
    with {:ok, base} <- strings(payload, ~w(event_id server_id channel_id message_id author_id)a),
         {:ok, mentioned} <- string_list(payload, "mentioned_user_ids") do
      {:ok,
       base
       |> Map.put(:mentioned_user_ids, Enum.uniq(mentioned))
       |> Map.put(:channel_name, optional_text(payload, "channel_name"))
       |> Map.put(:content_preview, optional_text(payload, "content_preview"))}
    end
  end

  defp fields(MessageUpdated, payload) do
    with {:ok, base} <- strings(payload, ~w(event_id server_id channel_id message_id author_id)a),
         {:ok, mentioned} <- string_list(payload, "mentioned_user_ids") do
      {:ok,
       base
       |> Map.put(:mentioned_user_ids, Enum.uniq(mentioned))
       |> Map.put(:channel_name, optional_text(payload, "channel_name"))
       |> Map.put(:content_preview, optional_text(payload, "content_preview"))}
    end
  end

  defp fields(MessageDeleted, payload) do
    with {:ok, base} <- strings(payload, ~w(event_id channel_id message_id author_id)a) do
      {:ok, Map.put(base, :server_id, optional_text(payload, "server_id"))}
    end
  end

  defp fields(UserProfileUpdated, payload) do
    with {:ok, base} <- strings(payload, ~w(event_id user_id name)a),
         {:ok, version} <- integer(payload, "version") do
      {:ok, Map.put(base, :version, version)}
    end
  end

  defp fields(ServerUpdated, payload), do: strings(payload, ~w(event_id server_id name)a)

  defp fields(UserPresenceChanged, payload) do
    with {:ok, base} <- strings(payload, ~w(event_id user_id connections)a),
         true <- base.connections in @connections,
         %{"do_not_disturb" => dnd} when is_boolean(dnd) <- payload,
         {:ok, version} <- integer(payload, "version") do
      {:ok, base |> Map.put(:do_not_disturb, dnd) |> Map.put(:version, version)}
    else
      _invalid -> {:error, :invalid_payload}
    end
  end

  defp optional_text(payload, key) do
    case Map.get(payload, key) do
      text when is_binary(text) and text != "" -> text
      _other -> nil
    end
  end

  defp integer(payload, key) do
    case Map.get(payload, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> {:error, :invalid_payload}
    end
  end

  defp strings(payload, keys) do
    values = Map.new(keys, fn key -> {key, Map.get(payload, Atom.to_string(key))} end)

    if Enum.all?(values, fn {_key, value} -> is_binary(value) and value != "" end),
      do: {:ok, values},
      else: {:error, :invalid_payload}
  end

  defp string_list(payload, key) do
    case Map.get(payload, key) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: {:error, :invalid_payload}

      _other ->
        {:error, :invalid_payload}
    end
  end

  defp parse_overrides(raw) when is_list(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn
      %{"role_id" => role_id, "allow" => allow, "deny" => deny}, {:ok, acc}
      when is_binary(role_id) and role_id != "" and is_list(allow) and is_list(deny) ->
        if Enum.all?(allow ++ deny, &is_binary/1),
          do:
            {:cont,
             {:ok, [%{role_id: role_id, allow: Enum.uniq(allow), deny: Enum.uniq(deny)} | acc]}},
          else: {:halt, {:error, :invalid_payload}}

      _other, _acc ->
        {:halt, {:error, :invalid_payload}}
    end)
    |> case do
      {:ok, overrides} -> {:ok, Enum.reverse(overrides)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_overrides(_other), do: {:error, :invalid_payload}

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_payload}
    end
  end

  defp parse_time(_other), do: {:error, :invalid_payload}
end
