defmodule Notifications.Push do
  @callback publish(topic :: String.t(), event :: String.t(), payload :: map()) ::
              :ok | {:error, term()}

  @spec publish(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def publish(topic, event, payload), do: impl().publish(topic, event, payload)

  defp impl, do: Application.get_env(:notifications, :push, Notifications.Push.Local)
end
