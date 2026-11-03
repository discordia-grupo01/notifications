defmodule Notifications.Delivery.Devices do
  alias Notifications.Delivery.{Config, Repo}
  alias Notifications.Delivery.WebPush.Vapid

  @providers ~w(webpush expo)
  @platforms ~w(web android ios)
  @expo_token ~r/\A(Exponent|Expo)PushToken\[[A-Za-z0-9_\-]{1,100}\]\z/
  @max_endpoint 2_048

  @type params :: %{optional(String.t()) => term()}

  @spec providers() :: [String.t()]
  def providers, do: @providers

  @spec platforms() :: [String.t()]
  def platforms, do: @platforms

  @spec register(String.t(), params()) ::
          {:ok, %{id: String.t(), created: boolean()}}
          | {:error, :invalid_payload | :device_limit | term()}
  def register(user_id, params) do
    with {:ok, attrs} <- parse(params) do
      Repo.impl().put_device(user_id, attrs, Config.get(:max_devices))
    end
  end

  @spec unregister(String.t(), String.t()) :: :ok | {:error, term()}
  def unregister(user_id, device_id), do: Repo.impl().delete_device(user_id, device_id)

  @spec enabled?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def enabled?(user_id), do: Repo.impl().get_push_enabled(user_id)

  @spec set_enabled(String.t(), boolean()) :: {:ok, boolean()} | {:error, term()}
  def set_enabled(user_id, enabled) when is_boolean(enabled) do
    with :ok <- Repo.impl().put_push_enabled(user_id, enabled), do: {:ok, enabled}
  end

  @spec vapid_public_key() :: {:ok, String.t()} | {:error, :push_not_configured}
  def vapid_public_key do
    with key when is_binary(key) <- Config.get(:vapid_private_key),
         {:ok, private} <- Vapid.decode(key),
         {:ok, public} <- Vapid.public_key(private) do
      {:ok, Vapid.encode(public)}
    else
      _missing -> {:error, :push_not_configured}
    end
  end

  defp parse(%{"provider" => provider, "platform" => platform} = params)
       when provider in @providers and platform in @platforms do
    with {:ok, credential, identity} <- credential(provider, platform, params) do
      {:ok,
       %{
         provider: provider,
         platform: platform,
         credential: credential,
         credential_hash: hash(provider, identity)
       }}
    end
  end

  defp parse(_params), do: {:error, :invalid_payload}

  defp credential("expo", platform, %{"token" => token})
       when platform in ["android", "ios"] and is_binary(token) do
    if Regex.match?(@expo_token, token),
      do: {:ok, %{"token" => token}, token},
      else: {:error, :invalid_payload}
  end

  defp credential("webpush", "web", %{"endpoint" => endpoint, "p256dh" => p256dh, "auth" => auth})
       when is_binary(endpoint) and is_binary(p256dh) and is_binary(auth) do
    if valid_endpoint?(endpoint) and key?(p256dh, 65) and key?(auth, 16),
      do: {:ok, %{"endpoint" => endpoint, "p256dh" => p256dh, "auth" => auth}, endpoint},
      else: {:error, :invalid_payload}
  end

  defp credential(_provider, _platform, _params), do: {:error, :invalid_payload}

  defp valid_endpoint?(endpoint) do
    byte_size(endpoint) <= @max_endpoint and
      match?(
        %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host),
        URI.parse(endpoint)
      ) and allowed_host?(URI.parse(endpoint).host)
  end

  defp allowed_host?(host) do
    Enum.any?(Config.get(:allowed_hosts), fn allowed ->
      host == allowed or String.ends_with?(host, "." <> allowed)
    end)
  end

  defp key?(text, size) do
    match?({:ok, bin} when byte_size(bin) == size, Vapid.decode(text))
  end

  defp hash(provider, identity),
    do: :sha256 |> :crypto.hash(provider <> ":" <> identity) |> Base.encode16(case: :lower)
end
