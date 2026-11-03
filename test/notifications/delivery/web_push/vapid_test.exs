defmodule Notifications.Delivery.WebPush.VapidTest do
  use ExUnit.Case, async: true

  alias Notifications.Delivery.WebPush.{Encryption, Vapid}

  setup do
    {public, private} = Encryption.generate_keypair()
    {:ok, public: public, private: private}
  end

  test "derives the public key from the private one", %{public: public, private: private} do
    assert Vapid.public_key(private) == {:ok, public}
  end

  test "rejects a private key that is not 32 bytes" do
    assert Vapid.public_key("short") == {:error, :invalid_key}

    assert Vapid.authorization("https://push.example/x", "short", "mailto:a@b.c") ==
             {:error, :invalid_key}
  end

  test "signs a JWT the push service can verify with the announced key", %{
    public: public,
    private: private
  } do
    endpoint = "https://fcm.googleapis.com/fcm/send/abc"

    assert {:ok, "vapid t=" <> rest} =
             Vapid.authorization(endpoint, private, "mailto:a@b.c", now: 1_000)

    [jwt, "k=" <> key] = String.split(rest, ", ")
    assert key == Vapid.encode(public)

    [header, claims, signature] = String.split(jwt, ".")
    assert Jason.decode!(Vapid.decode(header) |> elem(1)) == %{"typ" => "JWT", "alg" => "ES256"}

    assert Jason.decode!(Vapid.decode(claims) |> elem(1)) == %{
             "aud" => "https://fcm.googleapis.com",
             "exp" => 1_000 + 12 * 60 * 60,
             "sub" => "mailto:a@b.c"
           }

    {:ok, raw} = Vapid.decode(signature)
    assert byte_size(raw) == 64
    <<r::binary-32, s::binary-32>> = raw

    der =
      :public_key.der_encode(
        :"ECDSA-Sig-Value",
        {:"ECDSA-Sig-Value", :binary.decode_unsigned(r), :binary.decode_unsigned(s)}
      )

    assert :crypto.verify(:ecdsa, :sha256, header <> "." <> claims, der, [public, :secp256r1])
  end

  test "the audience is the origin of the endpoint" do
    assert Vapid.audience("https://updates.push.services.mozilla.com/wpush/v2/abc") ==
             "https://updates.push.services.mozilla.com"

    assert Vapid.audience("https://push.example:8443/x") == "https://push.example:8443"
  end

  test "decode returns :error for text that is not base64url" do
    assert Vapid.decode("***") == :error
  end
end
