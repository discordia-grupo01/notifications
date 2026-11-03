defmodule Notifications.Delivery.Sender.WebPush do
  @behaviour Notifications.Delivery.Sender

  alias Notifications.Delivery.{Config, Http}
  alias Notifications.Delivery.WebPush.{Encryption, Vapid}

  @ttl_seconds 24 * 60 * 60

  @impl true
  def send(%{"credential" => credential}, payload) do
    with {:ok, private_key, subject} <- vapid(),
         {:ok, keys} <- decode_keys(credential),
         {:ok, body} <- encrypt(payload, keys),
         {:ok, authorization} <-
           Vapid.authorization(credential["endpoint"], private_key, subject) do
      credential["endpoint"]
      |> Http.post(headers(authorization), body, Config.get(:http_timeout_ms))
      |> classify()
    else
      {:error, :not_configured} -> {:error, {:failed, :not_configured}}
      {:error, :payload_too_large} -> {:error, {:failed, :payload_too_large}}
      {:error, _reason} -> {:error, :invalid_token}
    end
  end

  defp vapid do
    with key when is_binary(key) <- Config.get(:vapid_private_key),
         subject when is_binary(subject) <- Config.get(:vapid_subject),
         {:ok, private_key} <- Vapid.decode(key) do
      {:ok, private_key, subject}
    else
      _missing -> {:error, :not_configured}
    end
  end

  defp decode_keys(%{"p256dh" => p256dh, "auth" => auth}) do
    with {:ok, public} <- Vapid.decode(p256dh),
         {:ok, secret} <- Vapid.decode(auth) do
      {:ok, {public, secret}}
    else
      :error -> {:error, :invalid_key}
    end
  end

  defp decode_keys(_credential), do: {:error, :invalid_key}

  defp encrypt(payload, {public, secret}) do
    payload
    |> Jason.encode!()
    |> Encryption.encrypt(public, secret)
  end

  defp headers(authorization),
    do: [
      {"authorization", authorization},
      {"content-encoding", "aes128gcm"},
      {"content-type", "application/octet-stream"},
      {"ttl", Integer.to_string(@ttl_seconds)},
      {"urgency", "high"}
    ]

  defp classify({:ok, %{status: status}}) when status in 200..299, do: :ok
  defp classify({:ok, %{status: status}}) when status in [404, 410], do: {:error, :invalid_token}

  defp classify({:ok, %{status: 429} = response}),
    do: {:error, {:retry, :rate_limited, Http.retry_after_ms(response)}}

  defp classify({:ok, %{status: status} = response}) when status >= 500,
    do: {:error, {:retry, :server_error, Http.retry_after_ms(response)}}

  defp classify({:ok, %{status: status}}), do: {:error, {:failed, :"http_#{status}"}}
  defp classify({:error, reason}), do: {:error, {:retry, reason, nil}}
end
