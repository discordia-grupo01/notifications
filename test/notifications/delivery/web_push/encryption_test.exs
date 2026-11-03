defmodule Notifications.Delivery.WebPush.EncryptionTest do
  use ExUnit.Case, async: true

  alias Notifications.Delivery.WebPush.Encryption

  defp b64(text), do: Base.url_decode64!(text, padding: false)

  @plaintext "When I grow up, I want to be a watermelon"

  @expected "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

  test "reproduces the example of RFC 8291 appendix A" do
    keypair =
      {b64(
         "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
       ), b64("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")}

    assert {:ok, body} =
             Encryption.encrypt(
               @plaintext,
               b64(
                 "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
               ),
               b64("BTBZMqHH6r4Tts7J_aSIgg"),
               keypair: keypair,
               salt: b64("DGv6ra1nlYgDCS1FRnbzlw")
             )

    assert Base.url_encode64(body, padding: false) == @expected
  end

  test "the receiver can open what was sent with its own private key" do
    {ua_public, ua_private} = Encryption.generate_keypair()
    auth = :crypto.strong_rand_bytes(16)

    assert {:ok, body} = Encryption.encrypt("hola", ua_public, auth)

    <<salt::binary-16, 4096::32, 65, as_public::binary-65, rest::binary>> = body
    secret = :crypto.compute_key(:ecdh, as_public, ua_private, :secp256r1)

    hmac = fn key, data -> :crypto.mac(:hmac, :sha256, key, data) end
    ikm = hmac.(hmac.(auth, secret), "WebPush: info" <> <<0>> <> ua_public <> as_public <> <<1>>)
    prk = hmac.(salt, ikm)
    cek = binary_part(hmac.(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>), 0, 16)
    nonce = binary_part(hmac.(prk, "Content-Encoding: nonce" <> <<0, 1>>), 0, 12)

    size = byte_size(rest) - 16
    <<ciphertext::binary-size(size), tag::binary-16>> = rest

    assert :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false) ==
             "hola" <> <<2>>
  end

  test "every message uses a fresh key and salt" do
    {ua_public, _private} = Encryption.generate_keypair()
    auth = :crypto.strong_rand_bytes(16)

    assert {:ok, first} = Encryption.encrypt("x", ua_public, auth)
    assert {:ok, second} = Encryption.encrypt("x", ua_public, auth)

    refute first == second
  end

  test "refuses a payload that does not fit in a single record" do
    {ua_public, _private} = Encryption.generate_keypair()
    auth = :crypto.strong_rand_bytes(16)

    fits = String.duplicate("a", Encryption.max_plaintext())
    assert {:ok, _body} = Encryption.encrypt(fits, ua_public, auth)
    assert Encryption.encrypt(fits <> "a", ua_public, auth) == {:error, :payload_too_large}
  end

  test "refuses a browser key that is not a point of the curve" do
    assert Encryption.encrypt("x", <<4>> <> :binary.copy(<<1>>, 64), <<0::128>>) ==
             {:error, :invalid_key}

    assert Encryption.encrypt("x", "short", <<0::128>>) == {:error, :invalid_key}
  end
end
