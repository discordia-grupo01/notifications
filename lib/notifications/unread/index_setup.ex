defmodule Notifications.Unread.IndexSetup do
  use Task, restart: :transient

  alias Notifications.Log

  require Logger

  @default_retry_ms 2_000
  @max_attempts 30

  def start_link(opts), do: Task.start_link(__MODULE__, :run, [opts])

  @spec run(keyword()) :: :ok
  def run(opts \\ []), do: attempt(1, Keyword.get(opts, :retry_ms, @default_retry_ms))

  defp attempt(n, retry_ms) do
    case ensure_indexes() do
      :ok ->
        Logger.info("indexes_ready", attempts: n)

      {:error, reason} when n < @max_attempts ->
        Logger.warning("indexes_retry", attempt: n, reason: Log.reason(reason))
        Process.sleep(retry_ms)
        attempt(n + 1, retry_ms)

      {:error, reason} ->
        Logger.error("indexes_failed", attempts: n, reason: Log.reason(reason))
    end
  end

  defp ensure_indexes do
    with :ok <- Notifications.Unread.Repo.impl().ensure_indexes() do
      Notifications.Delivery.Repo.impl().ensure_indexes()
    end
  end
end
