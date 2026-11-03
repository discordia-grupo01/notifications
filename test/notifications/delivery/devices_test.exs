defmodule Notifications.Delivery.DevicesTest do
  use ExUnit.Case, async: false
  import Mox

  alias Notifications.Delivery.{Devices, RepoMock}
  alias Notifications.Delivery.WebPush.{Encryption, Vapid}

  setup :set_mox_global
  setup :verify_on_exit!

  @token "ExponentPushToken[abcDEF123_-]"

  defp web_params(extra \\ %{}) do
    {public, _private} = Encryption.generate_keypair()

    Map.merge(
      %{
        "provider" => "webpush",
        "platform" => "web",
        "endpoint" => "https://fcm.googleapis.com/fcm/send/abc",
        "p256dh" => Vapid.encode(public),
        "auth" => Vapid.encode(:crypto.strong_rand_bytes(16))
      },
      extra
    )
  end

  test "registers an Expo device keeping only the token and hashing it for lookups" do
    expect(RepoMock, :put_device, fn "u1", attrs, 10 ->
      assert attrs.provider == "expo"
      assert attrs.platform == "android"
      assert attrs.credential == %{"token" => @token}
      assert attrs.credential_hash =~ ~r/\A[0-9a-f]{64}\z/
      refute attrs.credential_hash =~ "abcDEF"
      {:ok, %{id: "id1", created: true}}
    end)

    params = %{"provider" => "expo", "platform" => "android", "token" => @token, "extra" => "x"}

    assert Devices.register("u1", params) == {:ok, %{id: "id1", created: true}}
  end

  test "registers a web subscription" do
    params = web_params()

    expect(RepoMock, :put_device, fn "u1", attrs, _max ->
      assert attrs.credential == Map.take(params, ["endpoint", "p256dh", "auth"])
      {:ok, %{id: "id2", created: false}}
    end)

    assert Devices.register("u1", params) == {:ok, %{id: "id2", created: false}}
  end

  test "the same credential always hashes the same, another provider does not collide" do
    test_pid = self()

    stub(RepoMock, :put_device, fn _user, attrs, _max ->
      send(test_pid, {:hash, attrs.credential_hash})
      {:ok, %{id: "x", created: true}}
    end)

    params = %{"provider" => "expo", "platform" => "ios", "token" => @token}
    Devices.register("u1", params)
    Devices.register("u2", params)
    assert_received {:hash, first}
    assert_received {:hash, second}
    assert first == second
  end

  test "rejects unknown providers, platforms and missing credentials" do
    for params <- [
          %{},
          %{"provider" => "sms", "platform" => "android", "token" => @token},
          %{"provider" => "expo", "platform" => "web", "token" => @token},
          %{"provider" => "expo", "platform" => "android"},
          %{"provider" => "expo", "platform" => "android", "token" => 1},
          %{"provider" => "webpush", "platform" => "android"},
          %{"provider" => "webpush", "platform" => "web"}
        ] do
      assert Devices.register("u1", params) == {:error, :invalid_payload}
    end
  end

  test "rejects an Expo token that does not look like one" do
    for token <- [
          "",
          "abc",
          "ExponentPushToken[]",
          "ExponentPushToken[a b]",
          "ExponentPushToken[x]\nz"
        ] do
      params = %{"provider" => "expo", "platform" => "android", "token" => token}
      assert Devices.register("u1", params) == {:error, :invalid_payload}
    end
  end

  test "web endpoints must be https on a known push service" do
    for endpoint <- [
          "http://fcm.googleapis.com/fcm/send/abc",
          "https://evil.example/fcm/send/abc",
          "https://fcm.googleapis.com.evil.example/x",
          "https://notfcm.googleapis.com.example/x",
          "https://user:pass@fcm.googleapis.com/x",
          "https://localhost/x",
          "https://169.254.169.254/latest",
          "ftp://fcm.googleapis.com/x",
          "fcm.googleapis.com/x",
          "https://fcm.googleapis.com/" <> String.duplicate("a", 2_100)
        ] do
      assert Devices.register("u1", web_params(%{"endpoint" => endpoint})) ==
               {:error, :invalid_payload}
    end
  end

  test "accepts subdomains of the known push services" do
    stub(RepoMock, :put_device, fn _user, _attrs, _max -> {:ok, %{id: "x", created: true}} end)

    for endpoint <- [
          "https://updates.push.services.mozilla.com/wpush/v2/abc",
          "https://web.push.apple.com/abc",
          "https://wns2-par02p.notify.windows.com/w/?token=abc"
        ] do
      assert {:ok, _} = Devices.register("u1", web_params(%{"endpoint" => endpoint}))
    end
  end

  test "the allowed hosts are configurable" do
    Application.put_env(:notifications, :push_delivery, allowed_hosts: ["push.example.org"])
    on_exit(fn -> Application.delete_env(:notifications, :push_delivery) end)
    stub(RepoMock, :put_device, fn _user, _attrs, _max -> {:ok, %{id: "x", created: true}} end)

    assert {:ok, _} =
             Devices.register("u1", web_params(%{"endpoint" => "https://push.example.org/a"}))

    assert Devices.register("u1", web_params()) == {:error, :invalid_payload}
  end

  test "rejects web keys of the wrong size or that are not base64url" do
    {public, _private} = Encryption.generate_keypair()

    for extra <- [
          %{"p256dh" => "***"},
          %{"p256dh" => Vapid.encode(binary_part(public, 0, 64))},
          %{"auth" => "***"},
          %{"auth" => Vapid.encode(:crypto.strong_rand_bytes(15))}
        ] do
      assert Devices.register("u1", web_params(extra)) == {:error, :invalid_payload}
    end
  end

  test "the device cap is passed down and reported" do
    Application.put_env(:notifications, :push_delivery, max_devices: 2)
    on_exit(fn -> Application.delete_env(:notifications, :push_delivery) end)
    expect(RepoMock, :put_device, fn "u1", _attrs, 2 -> {:error, :device_limit} end)

    params = %{"provider" => "expo", "platform" => "android", "token" => @token}
    assert Devices.register("u1", params) == {:error, :device_limit}
  end

  test "unregister deletes by user and id" do
    expect(RepoMock, :delete_device, fn "u1", "id1" -> :ok end)

    assert Devices.unregister("u1", "id1") == :ok
  end

  test "the push switch is read and written as a boolean" do
    expect(RepoMock, :get_push_enabled, fn "u1" -> {:ok, true} end)
    expect(RepoMock, :put_push_enabled, fn "u1", false -> :ok end)
    expect(RepoMock, :put_push_enabled, fn "u1", true -> {:error, :timeout} end)

    assert Devices.enabled?("u1") == {:ok, true}
    assert Devices.set_enabled("u1", false) == {:ok, false}
    assert Devices.set_enabled("u1", true) == {:error, :timeout}
  end

  test "the VAPID public key is derived from the private one" do
    {public, private} = Encryption.generate_keypair()
    Application.put_env(:notifications, :push_delivery, vapid_private_key: Vapid.encode(private))
    on_exit(fn -> Application.delete_env(:notifications, :push_delivery) end)

    assert Devices.vapid_public_key() == {:ok, Vapid.encode(public)}
  end

  test "without a valid VAPID key there is no public key" do
    assert Devices.vapid_public_key() == {:error, :push_not_configured}

    Application.put_env(:notifications, :push_delivery, vapid_private_key: "short")
    on_exit(fn -> Application.delete_env(:notifications, :push_delivery) end)

    assert Devices.vapid_public_key() == {:error, :push_not_configured}
  end
end
