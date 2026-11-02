defmodule Notifications.Unread do
  alias Notifications.UUID
  alias Notifications.Settings
  alias Notifications.Unread.{Access, Repo, State}

  @max_future_seconds 60

  @spec mongo_ready?() :: boolean()
  def mongo_ready?, do: Repo.impl().ping() == :ok

  @spec snapshot(String.t()) :: {:ok, State.t()} | {:error, term()}
  def snapshot(user_id) do
    repo = Repo.impl()

    with {:ok, visible} <- Access.visible_channels(user_id),
         channel_ids = Enum.map(visible, & &1.channel_id),
         {:ok, activity} <- repo.get_activity(channel_ids),
         {:ok, reads} <- repo.get_read_markers(user_id, channel_ids),
         {:ok, mentions} <- repo.get_mention_markers(user_id, channel_ids),
         {:ok, settings} <- Settings.scopes(user_id) do
      {:ok, visible |> State.build(activity, reads, mentions) |> State.apply_settings(settings)}
    end
  end

  @spec mark_read(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t() | nil}
          | {:error, :channel_not_found | :forbidden | :invalid_payload | term()}
  def mark_read(user_id, channel_id, message_id \\ nil) do
    repo = Repo.impl()

    with {:ok, requested} <- validate_message_id(message_id),
         {:ok, server_id} <- Access.authorize_channel(user_id, channel_id),
         {:ok, up_to} <- resolve(repo, channel_id, requested) do
      persist(repo, user_id, channel_id, server_id, up_to)
    end
  end

  @spec mark_all_read(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def mark_all_read(user_id) do
    repo = Repo.impl()

    with {:ok, visible} <- Access.visible_channels(user_id),
         channel_ids = Enum.map(visible, & &1.channel_id),
         {:ok, activity} <- repo.get_activity(channel_ids),
         {:ok, reads} <- repo.get_read_markers(user_id, channel_ids) do
      entries = unread_entries(visible, activity, reads)
      persist_all(repo, user_id, entries)
    end
  end

  defp unread_entries(visible, activity, reads) do
    for %{channel_id: id, server_id: server_id, floor: floor} <- visible,
        last = Map.get(activity, id),
        last > Enum.max([floor, Map.get(reads, id, "")]) do
      %{channel_id: id, server_id: server_id, message_id: last}
    end
  end

  defp persist_all(_repo, _user_id, []), do: {:ok, 0}

  defp persist_all(repo, user_id, entries) do
    with :ok <- repo.mark_all_read(user_id, entries), do: {:ok, length(entries)}
  end

  defp persist(_repo, _user_id, _channel_id, _server_id, nil), do: {:ok, nil}

  defp persist(repo, user_id, channel_id, server_id, up_to) do
    with :ok <- repo.mark_read(user_id, channel_id, server_id, up_to), do: {:ok, up_to}
  end

  defp resolve(_repo, _channel_id, requested) when is_binary(requested), do: {:ok, requested}

  defp resolve(repo, channel_id, nil) do
    with {:ok, activity} <- repo.get_activity([channel_id]),
         do: {:ok, Map.get(activity, channel_id)}
  end

  defp validate_message_id(id) when id in [nil, ""], do: {:ok, nil}

  defp validate_message_id(id) when is_binary(id) do
    if UUID.v7?(id) and id <= future_limit(),
      do: {:ok, id},
      else: {:error, :invalid_payload}
  end

  defp validate_message_id(_other), do: {:error, :invalid_payload}

  defp future_limit,
    do: DateTime.utc_now() |> DateTime.add(@max_future_seconds, :second) |> UUID.floor_v7()
end
