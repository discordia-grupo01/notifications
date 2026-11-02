defmodule Notifications.Settings do
  require Logger

  alias Notifications.{Log, Push}
  alias Notifications.Unread.{Access, Repo}

  @levels ~w(all mentions none)
  @default_level "mentions"

  @type level :: String.t()
  @type setting :: %{muted: boolean(), level: level() | nil}
  @type changes :: %{optional(:muted) => boolean(), optional(:level) => level() | nil}
  @type listing :: %{
          servers: [String.t()],
          channels: [%{channel_id: String.t(), server_id: String.t()}],
          preferences: %{
            servers: [%{server_id: String.t(), level: level()}],
            channels: [%{channel_id: String.t(), server_id: String.t(), level: level()}]
          }
        }
  @type scopes :: %{
          muted_servers: MapSet.t(String.t()),
          muted_channels: MapSet.t(String.t()),
          server_levels: %{String.t() => level()},
          channel_levels: %{String.t() => level()}
        }

  @spec levels() :: [level()]
  def levels, do: @levels

  @spec effective_level(%{
          required(:channel_muted) => boolean(),
          required(:server_muted) => boolean(),
          required(:channel_level) => level() | nil,
          required(:server_level) => level() | nil,
          optional(atom()) => term()
        }) :: level()
  def effective_level(%{channel_muted: true}), do: "none"
  def effective_level(%{server_muted: true}), do: "none"

  def effective_level(%{channel_level: channel_level, server_level: server_level}),
    do: channel_level || server_level || @default_level

  @spec effective_level_for([map()], String.t(), String.t()) :: level()
  def effective_level_for(docs, channel_id, server_id) do
    channel_doc = Enum.find(docs, &(&1["scope_id"] == channel_id))
    server_doc = Enum.find(docs, &(&1["scope_id"] == server_id))

    effective_level(%{
      channel_muted: muted?(channel_doc),
      server_muted: muted?(server_doc),
      channel_level: leveled(channel_doc),
      server_level: leveled(server_doc)
    })
  end

  @spec list(String.t()) :: {:ok, listing()} | {:error, term()}
  def list(user_id) do
    with {:ok, docs} <- Repo.impl().list_settings(user_id) do
      servers = scope_docs(docs, "server")
      channels = scope_docs(docs, "channel")

      {:ok,
       %{
         servers: servers |> Enum.filter(&muted?/1) |> Enum.map(& &1["scope_id"]) |> Enum.sort(),
         channels:
           channels
           |> Enum.filter(&muted?/1)
           |> Enum.map(&%{channel_id: &1["scope_id"], server_id: &1["server_id"]})
           |> Enum.sort_by(& &1.channel_id),
         preferences: %{
           servers:
             servers
             |> Enum.filter(&leveled?/1)
             |> Enum.map(&%{server_id: &1["scope_id"], level: &1["level"]})
             |> Enum.sort_by(& &1.server_id),
           channels:
             channels
             |> Enum.filter(&leveled?/1)
             |> Enum.map(
               &%{channel_id: &1["scope_id"], server_id: &1["server_id"], level: &1["level"]}
             )
             |> Enum.sort_by(& &1.channel_id)
         }
       }}
    end
  end

  @spec scopes(String.t()) :: {:ok, scopes()} | {:error, term()}
  def scopes(user_id) do
    with {:ok, docs} <- Repo.impl().list_settings(user_id) do
      servers = scope_docs(docs, "server")
      channels = scope_docs(docs, "channel")

      {:ok,
       %{
         muted_servers: servers |> Enum.filter(&muted?/1) |> ids() |> MapSet.new(),
         muted_channels: channels |> Enum.filter(&muted?/1) |> ids() |> MapSet.new(),
         server_levels: levels_by_id(servers),
         channel_levels: levels_by_id(channels)
       }}
    end
  end

  @spec update_server(String.t(), String.t(), changes()) ::
          {:ok, setting()} | {:error, :server_not_found | term()}
  def update_server(user_id, server_id, changes) do
    with :ok <- authorize_server(user_id, server_id, changes),
         :ok <- Repo.impl().put_setting(user_id, :server, server_id, server_id, changes) do
      saved(user_id, server_id)
    end
  end

  @spec update_channel(String.t(), String.t(), changes()) ::
          {:ok, setting()} | {:error, :channel_not_found | :forbidden | term()}
  def update_channel(user_id, channel_id, changes) do
    with {:ok, server_id} <- authorize_channel(user_id, channel_id, changes),
         :ok <- Repo.impl().put_setting(user_id, :channel, channel_id, server_id, changes) do
      saved(user_id, channel_id)
    end
  end

  defp authorize_server(user_id, server_id, changes) do
    if stores_something?(changes), do: member(user_id, server_id), else: :ok
  end

  defp authorize_channel(user_id, channel_id, changes) do
    if stores_something?(changes),
      do: Access.authorize_channel(user_id, channel_id),
      else: {:ok, nil}
  end

  defp stores_something?(changes),
    do: Map.get(changes, :muted) == true or is_binary(Map.get(changes, :level))

  defp member(user_id, server_id) do
    case Access.member?(user_id, server_id) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :server_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp saved(user_id, scope_id) do
    case Repo.impl().get_setting(user_id, scope_id) do
      {:error, _reason} = error ->
        error

      doc ->
        resync(user_id)
        {:ok, %{muted: muted?(doc), level: doc && doc["level"]}}
    end
  end

  defp resync(user_id) do
    case Push.publish("user:" <> user_id, "resync", %{}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("resync_broadcast_failed", user_id: user_id, reason: Log.reason(reason))
    end
  end

  defp scope_docs(docs, scope), do: Enum.filter(docs, &(&1["scope"] == scope))
  defp muted?(doc), do: is_map(doc) and doc["muted"] == true
  defp leveled?(doc), do: doc["level"] in @levels
  defp leveled(%{"level" => level}) when level in @levels, do: level
  defp leveled(_doc), do: nil
  defp ids(docs), do: Enum.map(docs, & &1["scope_id"])

  defp levels_by_id(docs),
    do: docs |> Enum.filter(&leveled?/1) |> Map.new(&{&1["scope_id"], &1["level"]})
end
