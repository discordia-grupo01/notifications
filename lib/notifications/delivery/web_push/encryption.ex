defmodule Notifications.Delivery.WebPush.Encryption do
  @record_size 4096
  @max_plaintext @record_size - 17
  @curve :secp256r1

  @type keypair :: {public :: binary(), private :: binary()}

  @spec max_plaintext() :: pos_integer()
  def max_plaintext, do: @max_plaintext

  @spec encrypt(binary(), binary(), binary(), keyword()) ::
          {:ok, binary()} | {:error, :payload_too_large | :invalid_key}
  def encrypt(plaintext, ua_public, auth_secret, opts \\ [])
      when is_binary(plaintext) and is_binary(ua_public) and is_binary(auth_secret) do
    if byte_size(plaintext) > @max_plaintext do
      {:error, :payload_too_large}
    else
      {as_public, as_private} = Keyword.get_lazy(opts, :keypair, &generate_keypair/0)
      salt = Keyword.get_lazy(opts, :salt, fn -> :crypto.strong_rand_bytes(16) end)

      with {:ok, secret} <- shared_secret(ua_public, as_private) do
        {:ok, seal(plaintext, secret, ua_public, as_public, auth_secret, salt)}
      end
    end
  end

  @spec generate_keypair() :: keypair()
  def generate_keypair, do: :crypto.generate_key(:ecdh, @curve)

  defp seal(plaintext, secret, ua_public, as_public, auth_secret, salt) do
    prk_key = hmac(auth_secret, secret)
    key_info = "WebPush: info" <> <<0>> <> ua_public <> as_public
    ikm = hkdf_expand(prk_key, key_info, 32)
    prk = hmac(salt, ikm)
    cek = hkdf_expand(prk, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf_expand(prk, "Content-Encoding: nonce" <> <<0>>, 12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, plaintext <> <<2>>, <<>>, 16, true)

    header = salt <> <<@record_size::32>> <> <<byte_size(as_public)::8>> <> as_public
    header <> ciphertext <> tag
  end

  defp shared_secret(ua_public, as_private) do
    {:ok, :crypto.compute_key(:ecdh, ua_public, as_private, @curve)}
  rescue
    _error -> {:error, :invalid_key}
  end

  defp hkdf_expand(prk, info, length),
    do: prk |> hmac(info <> <<1>>) |> binary_part(0, length)

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
