defmodule Notifications.Delivery.Recipients do
  alias Notifications.Settings
  alias Notifications.Unread.{Access, Repo}

  @type kind :: :mention | :message | :direct

  @spec for_channel_message(map()) :: {:ok, %{String.t() => kind()}} | {:error, term()}
  def for_channel_message(%{channel_id: channel_id, server_id: server_id} = event) do
    mentioned = Enum.reject(event.mentioned_user_ids, &(&1 == event.author_id))

    with {:ok, docs} <- Repo.impl().list_settings_by_scope([channel_id, server_id]) do
      by_user = Enum.group_by(docs, & &1["user_id"])

      mentions =
        for user_id <- mentioned, level(by_user, user_id, event) != "none", into: %{} do
          {user_id, :mention}
        end

      with {:ok, everything} <- every_message(by_user, mentioned, event) do
        {:ok, Map.merge(everything, mentions)}
      end
    end
  end

  @spec for_direct_message(map()) :: {:ok, %{String.t() => kind()}}
  def for_direct_message(%{author_id: author_id, recipient_id: author_id}), do: {:ok, %{}}
  def for_direct_message(%{recipient_id: recipient_id}), do: {:ok, %{recipient_id => :direct}}

  defp every_message(by_user, mentioned, event) do
    by_user
    |> Enum.filter(fn {user_id, _docs} ->
      user_id != event.author_id and user_id not in mentioned and
        level(by_user, user_id, event) == "all"
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn user_id, {:ok, acc} ->
      case can_view?(user_id, event.channel_id) do
        {:ok, true} -> {:cont, {:ok, Map.put(acc, user_id, :message)}}
        {:ok, false} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp can_view?(user_id, channel_id) do
    with {:ok, visible} <- Access.visible_channels(user_id) do
      {:ok, Enum.any?(visible, &(&1.channel_id == channel_id))}
    end
  end

  defp level(by_user, user_id, event) do
    by_user
    |> Map.get(user_id, [])
    |> Settings.effective_level_for(event.channel_id, event.server_id)
  end
end
