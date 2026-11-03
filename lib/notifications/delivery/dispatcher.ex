defmodule Notifications.Delivery.Dispatcher do
  require Logger

  alias Notifications.Delivery.{Config, Repo, Sender}
  alias Notifications.Log

  @supervisor Notifications.Delivery.TaskSupervisor

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts),
    do:
      Supervisor.child_spec(
        {Task.Supervisor, name: @supervisor, max_children: Config.get(:max_concurrency)},
        id: __MODULE__
      )

  @spec dispatch(String.t(), [map()], %{title: String.t(), body: String.t(), data: map()}) :: :ok
  def dispatch(event_id, devices, payload) do
    Enum.each(devices, fn device ->
      case Task.Supervisor.start_child(@supervisor, fn -> deliver(event_id, device, payload) end) do
        {:ok, _pid} ->
          :ok

        {:error, :max_children} ->
          Logger.warning("push_dropped", event_id: event_id, reason: "overloaded")
      end
    end)
  end

  @spec deliver(String.t(), map(), map()) :: :ok | :duplicate
  def deliver(event_id, %{"_id" => device_id} = device, payload) do
    expires_at = DateTime.add(DateTime.utc_now(), Config.get(:claim_ttl_seconds), :second)

    case Repo.impl().claim_delivery(event_id, device_id, expires_at) do
      :claimed ->
        attempt(device, payload, 1)

      :duplicate ->
        :duplicate

      {:error, reason} ->
        Logger.warning("push_claim_failed", event_id: event_id, reason: Log.reason(reason))
    end
  end

  defp attempt(device, payload, number) do
    case sender(device).send(device, payload) do
      :ok ->
        record(device, :ok)

      {:error, :invalid_token} ->
        Logger.info("push_device_removed", provider: device["provider"], device_id: device["_id"])
        Repo.impl().delete_devices([device["_id"]])

      {:error, {:retry, reason, delay}} ->
        retry(device, payload, number, reason, delay)

      {:error, {:failed, reason}} ->
        Logger.warning("push_failed",
          provider: device["provider"],
          device_id: device["_id"],
          reason: Log.reason(reason)
        )

        record(device, {:error, to_string(reason)})
    end

    :ok
  end

  defp retry(device, payload, number, reason, delay) do
    if number < Config.get(:max_attempts) do
      Process.sleep(backoff(number, delay))
      attempt(device, payload, number + 1)
    else
      Logger.warning("push_gave_up",
        provider: device["provider"],
        device_id: device["_id"],
        attempts: number,
        reason: Log.reason(reason)
      )

      record(device, {:error, "gave_up_" <> to_string(reason)})
    end
  end

  defp backoff(number, nil),
    do: min(Config.get(:retry_base_ms) * Integer.pow(2, number - 1), Config.get(:retry_max_ms))

  defp backoff(_number, delay), do: min(delay, Config.get(:retry_max_ms))

  defp record(device, outcome) do
    case Repo.impl().mark_device(device["_id"], outcome) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("push_mark_failed", reason: Log.reason(reason))
    end
  end

  defp sender(%{"provider" => provider}), do: Sender.impl(provider)
end
