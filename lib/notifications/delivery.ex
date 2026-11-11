defmodule Notifications.Delivery do
  require Logger

  alias Notifications.Delivery.{Audience, Content, Dispatcher, Recipients, Repo}
  alias Notifications.Events.Event
  alias Notifications.Log

  @spec notify(struct()) :: :ok
  def notify(event) do
    case run(event) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("push_skipped", event_id: event.event_id, reason: Log.reason(reason))
    end
  rescue
    error ->
      Logger.warning("push_skipped", event_id: event.event_id, reason: Log.reason(error))
  end

  @spec notify_edit(struct(), [String.t()]) :: :ok
  def notify_edit(%Event.MessageUpdated{} = event, added) do
    case deliver(event, Map.new(added, &{&1, :mention})) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("push_skipped", event_id: event.event_id, reason: Log.reason(reason))
    end
  rescue
    error ->
      Logger.warning("push_skipped", event_id: event.event_id, reason: Log.reason(error))
  end

  defp run(%Event.MessageCreated{} = event) do
    with {:ok, recipients} <- Recipients.for_channel_message(event) do
      deliver(event, recipients)
    end
  end

  defp run(%Event.DirectMessageCreated{} = event) do
    with {:ok, recipients} <- Recipients.for_direct_message(event) do
      deliver(event, recipients)
    end
  end

  defp run(%Event.OwnershipTransferUpdated{} = event) do
    with {:ok, recipients} <- Recipients.for_ownership_transfer(event) do
      deliver(event, recipients)
    end
  end

  defp run(%Event.PrivateCall{} = event) do
    with {:ok, recipients} <- Recipients.for_private_call(event) do
      deliver(event, recipients)
    end
  end

  defp deliver(_event, recipients) when map_size(recipients) == 0, do: :ok

  defp deliver(event, recipients) do
    with {:ok, user_ids} <- Audience.reachable(Map.keys(recipients), DateTime.utc_now()) do
      send_to_devices(event, recipients, user_ids)
    end
  end

  defp send_to_devices(_event, _recipients, []), do: :ok

  defp send_to_devices(event, recipients, user_ids) do
    with {:ok, devices} <- Repo.impl().list_devices(user_ids),
         {:ok, content} <- content(event, devices) do
      Enum.each(devices, fn device ->
        payload = put_kind(content, Map.fetch!(recipients, device["user_id"]))
        Dispatcher.dispatch(event.event_id, [device], payload)
      end)
    end
  end

  defp content(_event, []), do: {:ok, nil}
  defp content(event, _devices), do: Content.build(event)

  defp put_kind(content, kind),
    do: %{content | data: Map.put(content.data, "kind", kind_name(kind))}

  defp kind_name(:mention), do: "mention"
  defp kind_name(:message), do: "message"
  defp kind_name(:direct), do: "direct_message"
  defp kind_name(:call), do: "voice_call"
  defp kind_name(:transfer), do: "ownership_transfer"
end
