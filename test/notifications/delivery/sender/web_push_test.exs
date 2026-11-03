defmodule Notifications.Delivery.Sender.WebPushTest do
  use ExUnit.Case, async: false
  import Mox

  alias Notifications.Delivery.HttpMock
  alias Notifications.Delivery.Sender.WebPush
  alias Notifications.Delivery.WebPush.{Encryption, Vapid}

  setup :verify_on_exit!

  @payload %{title: "Mensaje directo", body: "Ana: hola", data: %{"kind" => "direct_message"}}

  setup do
    {ua_public, _ua_private} = Encryption.generate_keypair()
    {_public, vapid_private} = Encryption.generate_keypair()

    Application.put_env(:notifications, :push_delivery,
      vapid_private_key: Vapid.encode(vapid_private),
      vapid_subject: "mailto:a@b.c"
    )

    on_exit(fn -> Application.delete_env(:notifications, :push_delivery) end)

    device = %{
      "credential" => %{
        "endpoint" => "https://fcm.googleapis.com/fcm/send/abc",
        "p256dh" => Vapid.encode(ua_public),
        "auth" => Vapid.encode(:crypto.strong_rand_bytes(16))
      }
    }

    {:ok, device: device}
  end

  defp reply(status, headers \\ []), do: {:ok, %{status: status, headers: headers, body: ""}}

  test "posts an encrypted body with the VAPID header to the subscription endpoint", %{
    device: device
  } do
    expect(HttpMock, :post, fn url, headers, body, _timeout ->
      assert url == "https://fcm.googleapis.com/fcm/send/abc"
      assert {"content-encoding", "aes128gcm"} in headers
      assert {"urgency", "high"} in headers
      assert {"ttl", "86400"} in headers
      assert {"authorization", "vapid t=" <> _rest} = List.keyfind(headers, "authorization", 0)
      refute body =~ "hola"
      reply(201)
    end)

    assert WebPush.send(device, @payload) == :ok
  end

  test "404 and 410 mean the subscription is gone", %{device: device} do
    expect(HttpMock, :post, fn _u, _h, _b, _t -> reply(404) end)
    expect(HttpMock, :post, fn _u, _h, _b, _t -> reply(410) end)

    assert WebPush.send(device, @payload) == {:error, :invalid_token}
    assert WebPush.send(device, @payload) == {:error, :invalid_token}
  end

  test "429 and 5xx are retried, other statuses fail", %{device: device} do
    expect(HttpMock, :post, fn _u, _h, _b, _t -> reply(429, [{"retry-after", "2"}]) end)
    expect(HttpMock, :post, fn _u, _h, _b, _t -> reply(502) end)
    expect(HttpMock, :post, fn _u, _h, _b, _t -> reply(403) end)
    expect(HttpMock, :post, fn _u, _h, _b, _t -> {:error, :connect_failed} end)

    assert WebPush.send(device, @payload) == {:error, {:retry, :rate_limited, 2_000}}
    assert WebPush.send(device, @payload) == {:error, {:retry, :server_error, nil}}
    assert WebPush.send(device, @payload) == {:error, {:failed, :http_403}}
    assert WebPush.send(device, @payload) == {:error, {:retry, :connect_failed, nil}}
  end

  test "fails without calling anyone when VAPID is not configured", %{device: device} do
    Application.delete_env(:notifications, :push_delivery)

    assert WebPush.send(device, @payload) == {:error, {:failed, :not_configured}}
  end

  test "a subscription with broken keys is invalid", %{device: device} do
    broken = put_in(device, ["credential", "p256dh"], "***")

    assert WebPush.send(broken, @payload) == {:error, :invalid_token}
    assert WebPush.send(%{"credential" => %{}}, @payload) == {:error, :invalid_token}
  end

  test "a payload too large to encrypt is not retried", %{device: device} do
    huge = %{@payload | body: String.duplicate("a", 5_000)}

    assert WebPush.send(device, huge) == {:error, {:failed, :payload_too_large}}
  end
end
