defmodule Notifications.Delivery.Sender.Expo do
  @behaviour Notifications.Delivery.Sender

  alias Notifications.Delivery.{Config, Http}

  @incoming_call_category "private_call_incoming"
  @incoming_call_channel "private_calls"
  @incoming_call_sound "llamada_entrante.wav"
  @message_channel "messages"
  @message_sound "nuevo_mensaje.wav"

  @impl true
  def send(%{"credential" => %{"token" => token}}, payload) do
    message =
      put_incoming_call(
        %{
          "to" => token,
          "title" => payload.title,
          "body" => payload.body,
          "data" => payload.data,
          "sound" => @message_sound,
          "channelId" => @message_channel,
          "priority" => "high"
        },
        payload.data
      )

    Config.get(:expo_url)
    |> Http.post(headers(), Jason.encode!(message), Config.get(:http_timeout_ms))
    |> classify()
  end

  def send(_device, _payload), do: {:error, :invalid_token}

  defp put_incoming_call(message, %{"call_id" => _call_id, "status" => "ringing"}) do
    Map.merge(message, %{
      "categoryId" => @incoming_call_category,
      "channelId" => @incoming_call_channel,
      "sound" => @incoming_call_sound
    })
  end

  defp put_incoming_call(message, _data), do: message

  defp headers do
    base = [{"content-type", "application/json"}, {"accept", "application/json"}]

    case Config.get(:expo_access_token) do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer " <> token} | base]

      _none ->
        base
    end
  end

  defp classify({:ok, %{status: 200, body: body}}), do: ticket(body)

  defp classify({:ok, %{status: 429} = response}),
    do: {:error, {:retry, :rate_limited, Http.retry_after_ms(response)}}

  defp classify({:ok, %{status: status} = response}) when status >= 500,
    do: {:error, {:retry, :server_error, Http.retry_after_ms(response)}}

  defp classify({:ok, %{status: status}}), do: {:error, {:failed, :"http_#{status}"}}
  defp classify({:error, reason}), do: {:error, {:retry, reason, nil}}

  defp ticket(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => %{"status" => "ok"}}} -> :ok
      {:ok, %{"data" => %{"status" => "error"} = data}} -> ticket_error(data)
      _other -> {:error, {:failed, :unexpected_response}}
    end
  end

  defp ticket_error(%{"details" => %{"error" => "DeviceNotRegistered"}}),
    do: {:error, :invalid_token}

  defp ticket_error(%{"details" => %{"error" => "MessageRateExceeded"}}),
    do: {:error, {:retry, :rate_limited, nil}}

  defp ticket_error(_data), do: {:error, {:failed, :rejected}}
end
