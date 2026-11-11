defmodule Notifications.Realtime do
  require Logger

  alias Notifications.Events.Event
  alias Notifications.{Log, Push}
  alias Notifications.Realtime.Debouncer
  alias Notifications.Unread.Repo

  @type ping :: {:topic, String.t(), map()} | {:metrics, String.t()}

  @spec before_event(struct()) :: :ok
  def before_event(%Event.ServerDeleted{server_id: server_id}),
    do: send_pings([server(server_id, "servers")])

  def before_event(_event), do: :ok

  @spec after_event(struct()) :: :ok
  def after_event(%Event.ServerDeleted{}), do: :ok
  def after_event(event), do: event |> pings() |> send_pings()

  @spec pings(struct()) :: [ping()]
  def pings(%Event.MemberJoined{server_id: server_id, user_id: user_id}),
    do: [server(server_id, "members"), user(user_id, "servers", server_id), {:metrics, server_id}]

  def pings(%Event.MemberLeft{server_id: server_id, user_id: user_id}),
    do: [server(server_id, "members"), user(user_id, "servers", server_id), {:metrics, server_id}]

  def pings(%Event.ChannelCreated{server_id: server_id}), do: [server(server_id, "channels")]
  def pings(%Event.ChannelDeleted{server_id: server_id}), do: [server(server_id, "channels")]

  def pings(%Event.ChannelOverridesUpdated{server_id: server_id}),
    do: [server(server_id, "channels")]

  def pings(%Event.RoleUpdated{server_id: server_id}),
    do: [server(server_id, "roles"), server(server_id, "channels")]

  def pings(%Event.RoleDeleted{server_id: server_id}),
    do: [server(server_id, "roles"), server(server_id, "channels")]

  def pings(%Event.MemberRolesUpdated{server_id: server_id, user_id: user_id}),
    do: [
      server(server_id, "members"),
      user(user_id, "roles", server_id),
      user(user_id, "channels", server_id)
    ]

  def pings(%Event.OwnerUpdated{server_id: server_id}),
    do: [server(server_id, "server"), server(server_id, "members"), server(server_id, "roles")]

  def pings(%Event.ServerUpdated{server_id: server_id}), do: [server(server_id, "server")]

  def pings(%Event.UserProfileUpdated{user_id: user_id}) do
    [user(user_id, "profile", nil, %{"user_id" => user_id}) | profile_servers(user_id)]
  end

  def pings(%Event.OwnershipTransferUpdated{from_user_id: from, to_user_id: to}),
    do: [user(from, "notifications"), user(to, "notifications")]

  def pings(%Event.MessageCreated{} = event),
    do: [{:metrics, event.server_id} | notifications_for(event.mentioned_user_ids)]

  def pings(%Event.MessageUpdated{} = event), do: notifications_for(event.mentioned_user_ids)

  def pings(%Event.DirectMessageCreated{recipient_id: recipient_id}),
    do: [user(recipient_id, "notifications")]

  def pings(%Event.Ping{routing_key: key, fields: fields}), do: ping(key, fields)

  def pings(_event), do: []

  defp ping(key, %{server_id: server_id})
       when key in ["servers.member_banned", "servers.member_unbanned", "servers.member_kicked"],
       do: [server(server_id, "moderation"), server(server_id, "members")]

  defp ping(key, %{server_id: server_id})
       when key in ["servers.member_muted", "servers.member_unmuted"],
       do: [server(server_id, "moderation"), server(server_id, "members")]

  defp ping(key, %{server_id: server_id})
       when key in ["servers.word_filter_updated", "servers.moderation_action_recorded"],
       do: [server(server_id, "moderation")]

  defp ping("servers.report_updated", %{server_id: server_id}),
    do: [server(server_id, "reports")]

  defp ping(key, %{server_id: server_id})
       when key in ["servers.emoji_created", "servers.emoji_deleted"],
       do: [server(server_id, "emojis")]

  defp ping("servers.server_boost_updated", %{server_id: server_id}),
    do: [server(server_id, "server")]

  defp ping("servers.resource_changed", %{server_id: server_id, resource: resource})
       when resource in ["server", "channels", "roles"],
       do: [server(server_id, resource)]

  defp ping("billing.account_changed", %{user_id: user_id, resource: resource})
       when resource in ["points", "boosts", "purchases"],
       do: [user(user_id, resource)]

  defp ping("billing.premium_updated", %{user_id: user_id}),
    do: [user(user_id, "premium"), user(user_id, "profile", nil, %{"user_id" => user_id})]

  defp ping("admin.backoffice_changed", %{resource: resource, audience_user_ids: audience}),
    do: Enum.map(audience, &user(&1, "backoffice", nil, %{"kind" => resource}))

  defp ping(_key, _fields), do: []

  defp notifications_for(user_ids), do: Enum.map(user_ids, &user(&1, "notifications"))

  defp profile_servers(user_id) do
    case Repo.impl().list_memberships(user_id) do
      {:ok, memberships} ->
        memberships
        |> Enum.map(& &1["server_id"])
        |> Enum.filter(&is_binary/1)
        |> Enum.uniq()
        |> Enum.map(&server(&1, "profile", %{"user_id" => user_id}))

      {:error, reason} ->
        Logger.warning("realtime_profile_servers_failed",
          user_id: user_id,
          reason: Log.reason(reason)
        )

        []
    end
  end

  defp server(server_id, resource, extra \\ %{}),
    do: {:topic, "server:" <> server_id, change(resource, server_id, extra)}

  defp user(user_id, resource, server_id \\ nil, extra \\ %{}),
    do: {:topic, "user:" <> user_id, change(resource, server_id, extra)}

  defp change(resource, server_id, extra) do
    base = %{"resource" => resource}
    base = if server_id, do: Map.put(base, "server_id", server_id), else: base
    Map.merge(base, extra)
  end

  defp send_pings(pings) do
    Enum.each(pings, &send_ping/1)
  rescue
    error ->
      Logger.warning("realtime_ping_failed", reason: Log.reason(error))
  end

  defp send_ping({:topic, topic, payload}) do
    case Push.publish(topic, "changed", payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("realtime_ping_failed", topic: topic, reason: Log.reason(reason))
    end
  end

  defp send_ping({:metrics, server_id}) do
    Debouncer.run("metrics:" <> server_id, fn -> send_ping(server(server_id, "metrics")) end)
  end
end
