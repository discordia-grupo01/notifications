defmodule Notifications.Delivery.Sender.ExpoTest do
  use ExUnit.Case, async: false
  import Mox

  alias Notifications.Delivery.HttpMock
  alias Notifications.Delivery.Sender.Expo

  setup :verify_on_exit!

  @device %{"credential" => %{"token" => "ExponentPushToken[abc]"}}
  @payload %{title: "Srv - general", body: "Ana: hola", data: %{"kind" => "mention"}}

  defp reply(status, body, headers \\ []),
    do: {:ok, %{status: status, headers: headers, body: Jason.encode!(body)}}

  test "sends one message with the title, body and data and accepts an ok ticket" do
    expect(HttpMock, :post, fn url, headers, body, _timeout ->
      assert url == "https://exp.host/--/api/v2/push/send"
      assert {"content-type", "application/json"} in headers
      refute Enum.any?(headers, fn {key, _value} -> key == "authorization" end)

      assert Jason.decode!(body) == %{
               "to" => "ExponentPushToken[abc]",
               "title" => "Srv - general",
               "body" => "Ana: hola",
               "data" => %{"kind" => "mention"},
               "sound" => "default",
               "priority" => "high"
             }

      reply(200, %{"data" => %{"status" => "ok", "id" => "t1"}})
    end)

    assert Expo.send(@device, @payload) == :ok
  end

  test "an incoming call carries the category with the answer and decline buttons" do
    ringing = %{
      title: "Llamada de voz",
      body: "Ana te está llamando",
      data: %{"call_id" => "call-1", "status" => "ringing", "kind" => "voice_call"}
    }

    expect(HttpMock, :post, fn _url, _headers, body, _timeout ->
      assert Jason.decode!(body)["categoryId"] == "private_call_incoming"
      reply(200, %{"data" => %{"status" => "ok"}})
    end)

    assert Expo.send(@device, ringing) == :ok
  end

  test "a call that is no longer ringing has no buttons" do
    missed = %{
      title: "Llamada de voz",
      body: "La llamada de voz no fue respondida",
      data: %{"call_id" => "call-1", "status" => "missed", "kind" => "voice_call"}
    }

    expect(HttpMock, :post, fn _url, _headers, body, _timeout ->
      refute Map.has_key?(Jason.decode!(body), "categoryId")
      reply(200, %{"data" => %{"status" => "ok"}})
    end)

    assert Expo.send(@device, missed) == :ok
  end

  test "sends the access token when one is configured" do
    Application.put_env(:notifications, :push_delivery, expo_access_token: "secret")
    on_exit(fn -> Application.delete_env(:notifications, :push_delivery) end)

    expect(HttpMock, :post, fn _url, headers, _body, _timeout ->
      assert {"authorization", "Bearer secret"} in headers
      reply(200, %{"data" => %{"status" => "ok"}})
    end)

    assert Expo.send(@device, @payload) == :ok
  end

  test "an unregistered device means the token is no longer valid" do
    expect(HttpMock, :post, fn _url, _headers, _body, _timeout ->
      reply(200, %{
        "data" => %{
          "status" => "error",
          "message" => "x",
          "details" => %{"error" => "DeviceNotRegistered"}
        }
      })
    end)

    assert Expo.send(@device, @payload) == {:error, :invalid_token}
  end

  test "rate limits are retried and other ticket errors are not" do
    expect(HttpMock, :post, 2, fn _url, _headers, _body, _timeout ->
      case Process.get(:calls, 0) do
        0 ->
          Process.put(:calls, 1)

          reply(200, %{
            "data" => %{"status" => "error", "details" => %{"error" => "MessageRateExceeded"}}
          })

        _ ->
          reply(200, %{
            "data" => %{"status" => "error", "details" => %{"error" => "MessageTooBig"}}
          })
      end
    end)

    assert Expo.send(@device, @payload) == {:error, {:retry, :rate_limited, nil}}
    assert Expo.send(@device, @payload) == {:error, {:failed, :rejected}}
  end

  test "429 and 5xx are retried honouring Retry-After; other statuses fail" do
    expect(HttpMock, :post, fn _u, _h, _b, _t -> reply(429, %{}, [{"Retry-After", "3"}]) end)
    expect(HttpMock, :post, fn _u, _h, _b, _t -> reply(503, %{}) end)
    expect(HttpMock, :post, fn _u, _h, _b, _t -> reply(400, %{}) end)

    assert Expo.send(@device, @payload) == {:error, {:retry, :rate_limited, 3_000}}
    assert Expo.send(@device, @payload) == {:error, {:retry, :server_error, nil}}
    assert Expo.send(@device, @payload) == {:error, {:failed, :http_400}}
  end

  test "network errors are retried" do
    expect(HttpMock, :post, fn _u, _h, _b, _t -> {:error, :timeout} end)

    assert Expo.send(@device, @payload) == {:error, {:retry, :timeout, nil}}
  end

  test "an answer that is not a ticket is a failure" do
    expect(HttpMock, :post, fn _u, _h, _b, _t ->
      {:ok, %{status: 200, headers: [], body: "<html>"}}
    end)

    assert Expo.send(@device, @payload) == {:error, {:failed, :unexpected_response}}
  end

  test "a device without token is invalid" do
    assert Expo.send(%{"credential" => %{}}, @payload) == {:error, :invalid_token}
  end
end
