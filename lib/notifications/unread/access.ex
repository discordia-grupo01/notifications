defmodule Notifications.Unread.Access do
  alias Notifications.UUID
  alias Notifications.Unread.{Permissions, Repo}

  @epoch ~U[1970-01-01 00:00:00Z]

  @type visible :: %{channel_id: String.t(), server_id: String.t(), floor: String.t()}

  @spec visible_channels(String.t()) :: {:ok, [visible()]} | {:error, term()}
  def visible_channels(user_id) do
    repo = Repo.impl()

    with {:ok, memberships} <- repo.list_memberships(user_id),
         server_ids = Enum.map(memberships, & &1["server_id"]),
         {:ok, owners} <- repo.get_server_owners(server_ids),
         {:ok, roles} <- repo.list_roles(server_ids),
         {:ok, channels} <- repo.list_channels(server_ids),
         {:ok, overrides} <- repo.list_overrides(server_ids) do
      {:ok, compute(user_id, memberships, owners, roles, channels, overrides)}
    end
  end

  @spec authorize_channel(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :channel_not_found | :forbidden | term()}
  def authorize_channel(user_id, channel_id) do
    with {:ok, server_id} <- fetch_text_channel(Repo.impl(), channel_id),
         {:ok, visible} <- visible_channels(user_id) do
      if Enum.any?(visible, &(&1.channel_id == channel_id)),
        do: {:ok, server_id},
        else: {:error, :forbidden}
    end
  end

  @spec member?(String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def member?(user_id, server_id) do
    with {:ok, memberships} <- Repo.impl().list_memberships(user_id) do
      {:ok, Enum.any?(memberships, &(&1["server_id"] == server_id))}
    end
  end

  @spec compute(String.t(), [map()], map(), [map()], [map()], [map()]) :: [visible()]
  def compute(user_id, memberships, owners, roles, channels, overrides) do
    roles_by_server =
      roles
      |> Enum.group_by(& &1["server_id"])
      |> Map.new(fn {server_id, docs} -> {server_id, Map.new(docs, &role_entry/1)} end)

    channels_by_server =
      channels
      |> Enum.filter(&(&1["kind"] == "text"))
      |> Enum.group_by(& &1["server_id"])

    overrides_by_channel = Map.new(overrides, &override_entry/1)

    for member <- memberships,
        channel <- Map.get(channels_by_server, member["server_id"], []),
        can_view?(user_id, member, channel, owners, roles_by_server, overrides_by_channel) do
      %{
        channel_id: channel["_id"],
        server_id: member["server_id"],
        floor: member |> member_since() |> UUID.floor_v7()
      }
    end
  end

  defp fetch_text_channel(repo, channel_id) do
    case repo.get_channel(channel_id) do
      %{"kind" => "text", "server_id" => server_id} -> {:ok, server_id}
      nil -> {:error, :channel_not_found}
      %{} -> {:error, :channel_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp can_view?(user_id, member, channel, owners, roles_by_server, overrides_by_channel) do
    server_id = member["server_id"]

    user_id
    |> owner?(Map.get(owners, server_id))
    |> Permissions.effective(
      Map.get(member, "role_ids", []),
      Map.get(roles_by_server, server_id, %{}),
      Map.get(overrides_by_channel, channel["_id"], %{})
    )
    |> Permissions.can?("VIEW_CHANNELS")
  end

  defp owner?(user_id, owner_id), do: user_id == owner_id

  defp member_since(member) do
    case Map.get(member, "joined_at") || Map.get(member, "inserted_at") do
      %DateTime{} = at -> at
      _missing -> @epoch
    end
  end

  defp role_entry(%{"_id" => id, "permissions" => permissions, "is_everyone" => is_everyone}),
    do: {id, %{permissions: permissions, is_everyone: is_everyone}}

  defp override_entry(%{"_id" => channel_id, "overrides" => overrides}) do
    {channel_id,
     Map.new(overrides, fn %{"role_id" => role_id, "allow" => allow, "deny" => deny} ->
       {role_id, %{allow: allow, deny: deny}}
     end)}
  end
end
