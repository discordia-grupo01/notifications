defmodule Notifications.Delivery.Sender do
  @type device :: %{String.t() => term()}
  @type payload :: %{title: String.t(), body: String.t(), data: map()}
  @type outcome ::
          :ok
          | {:error, :invalid_token}
          | {:error, {:retry, reason :: atom(), delay_ms :: non_neg_integer() | nil}}
          | {:error, {:failed, reason :: atom()}}

  @callback send(device(), payload()) :: outcome()

  @spec impl(String.t()) :: module() | nil
  def impl(provider) do
    :notifications
    |> Application.get_env(:push_senders, default_senders())
    |> Map.get(provider)
  end

  defp default_senders,
    do: %{
      "webpush" => Notifications.Delivery.Sender.WebPush,
      "expo" => Notifications.Delivery.Sender.Expo
    }
end
