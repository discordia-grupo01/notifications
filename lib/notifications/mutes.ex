defmodule Notifications.Mutes do
  require Logger

  alias Notifications.{Log, Push}
  alias Notifications.Unread.{Access, Repo}

  @type muted :: %{
          servers: [String.t()],
          channels: [%{channel_id: String.t(), server_id: String.t()}]
        }

  @spec list(String.t()) :: {:ok, muted()} | {:error, term()}
  def list(user_id) do
    with {:ok, docs} <- Repo.impl().list_mutes(user_id) do
      {:ok,
       %{
         servers: docs |> scope_docs("server") |> Enum.map(& &1["scope_id"]) |> Enum.sort(),
         channels:
           docs
           |> scope_docs("channel")
           |> Enum.map(&%{channel_id: &1["scope_id"], server_id: &1["server_id"]})
           |> Enum.sort_by(& &1.channel_id)
       }}
    end
  end

  @spec scopes(String.t()) :: {:ok, Notifications.Unread.State.mutes()} | {:error, term()}
  def scopes(user_id) do
    with {:ok, docs} <- Repo.impl().list_mutes(user_id) do
      {:ok,
       %{
         servers: docs |> scope_docs("server") |> Enum.map(& &1["scope_id"]) |> MapSet.new(),
         channels: docs |> scope_docs("channel") |> Enum.map(& &1["scope_id"]) |> MapSet.new()
       }}
    end
  end

  @spec set_server(String.t(), String.t(), boolean()) ::
          {:ok, boolean()} | {:error, :server_not_found | term()}
  def set_server(user_id, server_id, true) do
    with {:ok, true} <- member(user_id, server_id),
         :ok <- Repo.impl().put_mute(user_id, :server, server_id, server_id) do
      synced(user_id, true)
    end
  end

  def set_server(user_id, server_id, false) do
    with :ok <- Repo.impl().delete_mute(user_id, server_id), do: synced(user_id, false)
  end

  @spec set_channel(String.t(), String.t(), boolean()) ::
          {:ok, boolean()} | {:error, :channel_not_found | :forbidden | term()}
  def set_channel(user_id, channel_id, true) do
    with {:ok, server_id} <- Access.authorize_channel(user_id, channel_id),
         :ok <- Repo.impl().put_mute(user_id, :channel, channel_id, server_id) do
      synced(user_id, true)
    end
  end

  def set_channel(user_id, channel_id, false) do
    with :ok <- Repo.impl().delete_mute(user_id, channel_id), do: synced(user_id, false)
  end

  defp member(user_id, server_id) do
    case Access.member?(user_id, server_id) do
      {:ok, true} -> {:ok, true}
      {:ok, false} -> {:error, :server_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp scope_docs(docs, scope), do: Enum.filter(docs, &(&1["scope"] == scope))

  defp synced(user_id, muted) do
    case Push.publish("user:" <> user_id, "resync", %{}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("resync_broadcast_failed", user_id: user_id, reason: Log.reason(reason))
    end

    {:ok, muted}
  end
end
