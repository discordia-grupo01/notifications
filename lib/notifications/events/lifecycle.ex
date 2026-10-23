defmodule Notifications.Events.Lifecycle do
  require Logger

  alias Notifications.Events.Event
  alias Notifications.Push
  alias Notifications.Unread.Repo

  @tombstone_ttl_seconds 7 * 24 * 60 * 60

  @type result :: :ok | {:ignored, :stale | :server_deleted} | {:error, term()}

  @spec handle(struct()) :: result()
  def handle(%Event.ChannelCreated{} = event) do
    with :alive <- server_state(event.server_id),
         {:ok, :applied} <- clock(channel_key(event.channel_id), "created", event.occurred_at),
         :ok <-
           repo().upsert_channel(%{
             "_id" => event.channel_id,
             "server_id" => event.server_id,
             "name" => event.name,
             "kind" => event.kind
           }),
         :ok <- resync_server(event.server_id) do
      Logger.info("channel_created_applied", channel_id: event.channel_id)
    else
      other -> outcome(other, "servers.channel_created")
    end
  end

  def handle(%Event.ChannelDeleted{} = event) do
    with {:ok, :applied} <-
           clock(channel_key(event.channel_id), "deleted", event.occurred_at, tombstone_expiry()),
         :ok <- repo().delete_channel(event.channel_id),
         :ok <- resync_server(event.server_id) do
      Logger.info("channel_deleted_applied", channel_id: event.channel_id)
    else
      other -> outcome(other, "servers.channel_deleted")
    end
  end

  def handle(%Event.ServerDeleted{} = event) do
    with {:ok, :applied} <-
           clock(server_key(event.server_id), "deleted", event.occurred_at, tombstone_expiry()),
         :ok <- repo().delete_server_data(event.server_id, event.channel_ids),
         :ok <- resync_server(event.server_id) do
      Logger.info("server_deleted_applied", server_id: event.server_id)
    else
      other -> outcome(other, "servers.server_deleted")
    end
  end

  def handle(%Event.MemberJoined{} = event) do
    with {:ok, :applied} <- clock(member_key(event), "joined", event.occurred_at),
         :ok <- repo().record_member_joined(event.server_id, event.user_id, event.occurred_at),
         :ok <- resync_user(event.user_id) do
      Logger.info("member_joined_applied", server_id: event.server_id, user_id: event.user_id)
    else
      other -> outcome(other, "servers.member_joined")
    end
  end

  def handle(%Event.MemberLeft{} = event) do
    with {:ok, :applied} <- clock(member_key(event), "left", event.occurred_at),
         {:ok, _outcome} <-
           repo().delete_member(event.server_id, event.user_id, event.occurred_at),
         :ok <- resync_user(event.user_id) do
      Logger.info("member_left_applied", server_id: event.server_id, user_id: event.user_id)
    else
      other -> outcome(other, "servers.member_left")
    end
  end

  def handle(%Event.RoleUpdated{} = event) do
    replica_write(event.server_id, "servers.role_updated", &resync_server/1, fn ->
      repo().apply_role(
        event.server_id,
        event.role_id,
        event.permissions,
        event.is_everyone,
        event.occurred_at
      )
    end)
  end

  def handle(%Event.RoleDeleted{} = event) do
    replica_write(event.server_id, "servers.role_deleted", &resync_server/1, fn ->
      repo().delete_role(event.server_id, event.role_id, event.occurred_at)
    end)
  end

  def handle(%Event.MemberRolesUpdated{} = event) do
    replica_write(
      event.server_id,
      "servers.member_roles_updated",
      fn _ -> resync_user(event.user_id) end,
      fn ->
        repo().apply_member_roles(
          event.server_id,
          event.user_id,
          event.role_ids,
          event.occurred_at
        )
      end
    )
  end

  def handle(%Event.ChannelOverridesUpdated{} = event) do
    replica_write(event.server_id, "servers.channel_overrides_updated", &resync_server/1, fn ->
      repo().apply_channel_overrides(
        event.server_id,
        event.channel_id,
        event.overrides,
        event.occurred_at
      )
    end)
  end

  def handle(%Event.OwnerUpdated{} = event) do
    replica_write(event.server_id, "servers.owner_updated", &resync_server/1, fn ->
      repo().apply_server_owner(event.server_id, event.owner_id, event.occurred_at)
    end)
  end

  def handle(%Event.MessageCreated{} = event) do
    with :alive <- server_state(event.server_id),
         :ok <-
           repo().record_message(%{
             channel_id: event.channel_id,
             server_id: event.server_id,
             message_id: event.message_id,
             author_id: event.author_id,
             mentioned_user_ids: event.mentioned_user_ids
           }),
         :ok <-
           Push.publish("server:" <> event.server_id, "message_created", %{
             "server_id" => event.server_id,
             "channel_id" => event.channel_id,
             "message_id" => event.message_id,
             "author_id" => event.author_id,
             "mentioned_user_ids" => event.mentioned_user_ids
           }) do
      Logger.debug("message_activity_recorded",
        channel_id: event.channel_id,
        message_id: event.message_id
      )
    else
      other -> outcome(other, "messaging.message_created")
    end
  end

  defp replica_write(server_id, routing_key, resync, write) do
    with :alive <- server_state(server_id),
         {:ok, :applied} <- write.(),
         :ok <- resync.(server_id) do
      Logger.info("replica_updated", routing_key: routing_key, server_id: server_id)
    else
      other -> outcome(other, routing_key)
    end
  end

  defp outcome(:deleted, routing_key), do: ignored(:server_deleted, routing_key)
  defp outcome({:ok, :stale}, routing_key), do: ignored(:stale, routing_key)
  defp outcome({:error, _reason} = error, _routing_key), do: error

  defp resync_server(server_id), do: Push.publish("server:" <> server_id, "resync", %{})
  defp resync_user(user_id), do: Push.publish("user:" <> user_id, "resync", %{})

  defp server_state(server_id) do
    case repo().get_clock(server_key(server_id)) do
      %{"state" => "deleted"} -> :deleted
      {:error, _reason} = error -> error
      _alive -> :alive
    end
  end

  defp clock(key, state, at, expires_at \\ nil),
    do: repo().apply_clock(key, state, at, expires_at)

  defp ignored(cause, routing_key) do
    Logger.info("event_ignored", cause: to_string(cause), routing_key: routing_key)
    {:ignored, cause}
  end

  defp repo, do: Repo.impl()

  defp tombstone_expiry, do: DateTime.add(DateTime.utc_now(), @tombstone_ttl_seconds, :second)

  defp channel_key(channel_id), do: "channel:" <> channel_id
  defp server_key(server_id), do: "server:" <> server_id
  defp member_key(%{server_id: server_id, user_id: user_id}), do: "member:#{server_id}:#{user_id}"
end
