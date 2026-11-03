defmodule Notifications.Delivery.WebPush.Vapid do
  @curve :secp256r1
  @lifetime_seconds 12 * 60 * 60

  @spec public_key(binary()) :: {:ok, binary()} | {:error, :invalid_key}
  def public_key(private_key) when is_binary(private_key) and byte_size(private_key) == 32 do
    {public, _private} = :crypto.generate_key(:ecdh, @curve, private_key)
    {:ok, public}
  rescue
    _error -> {:error, :invalid_key}
  end

  def public_key(_private_key), do: {:error, :invalid_key}

  @spec authorization(String.t(), binary(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_key}
  def authorization(endpoint, private_key, subject, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    with {:ok, public} <- public_key(private_key) do
      claims = %{"aud" => audience(endpoint), "exp" => now + @lifetime_seconds, "sub" => subject}
      jwt = sign(claims, private_key)
      {:ok, "vapid t=#{jwt}, k=#{encode(public)}"}
    end
  end

  @spec audience(String.t()) :: String.t()
  def audience(endpoint) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(endpoint)
    default = if scheme == "https", do: 443, else: 80
    if port in [nil, default], do: "#{scheme}://#{host}", else: "#{scheme}://#{host}:#{port}"
  end

  @spec encode(binary()) :: String.t()
  def encode(binary), do: Base.url_encode64(binary, padding: false)

  @spec decode(String.t()) :: {:ok, binary()} | :error
  def decode(text) when is_binary(text), do: Base.url_decode64(text, padding: false)

  defp sign(claims, private_key) do
    header = encode(Jason.encode!(%{"typ" => "JWT", "alg" => "ES256"}))
    payload = encode(Jason.encode!(claims))
    signing_input = header <> "." <> payload

    der = :crypto.sign(:ecdsa, :sha256, signing_input, [private_key, @curve])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)

    signing_input <> "." <> encode(pad(r) <> pad(s))
  end

  defp pad(integer) do
    binary = :binary.encode_unsigned(integer)
    :binary.copy(<<0>>, 32 - byte_size(binary)) <> binary
  end
end
