defmodule NotificationsWeb.PushControllerTest do
  use NotificationsWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Notifications.AuthFixtures
  alias Notifications.Delivery.RepoMock
  alias Notifications.Delivery.WebPush.{Encryption, Vapid}

  setup :set_mox_global
  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @token "ExponentPushToken[abcDEF123]"

  defp authed(conn),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(@me))

  defp expo_body, do: %{"provider" => "expo", "platform" => "android", "token" => @token}

  describe "authentication" do
    test "every route needs a token", %{conn: conn} do
      for {method, path} <- [
            {:get, "/v1/notifications/push/settings"},
            {:put, "/v1/notifications/push/settings"},
            {:post, "/v1/notifications/push/devices"},
            {:delete, "/v1/notifications/push/devices/x"},
            {:get, "/v1/notifications/push/vapid-public-key"}
          ] do
        assert conn |> dispatch(@endpoint, method, path) |> json_response(401)
      end
    end
  end

  describe "GET and PUT /push/settings" do
    test "shows whether push is on", %{conn: conn} do
      expect(RepoMock, :get_push_enabled, fn @me -> {:ok, true} end)

      assert conn |> authed() |> get("/v1/notifications/push/settings") |> json_response(200) ==
               %{"enabled" => true}
    end

    test "turns push off and on", %{conn: conn} do
      expect(RepoMock, :put_push_enabled, fn @me, false -> :ok end)
      expect(RepoMock, :put_push_enabled, fn @me, true -> :ok end)

      assert conn
             |> authed()
             |> put("/v1/notifications/push/settings", %{"enabled" => false})
             |> json_response(200) == %{"enabled" => false}

      assert conn
             |> authed()
             |> put("/v1/notifications/push/settings", %{"enabled" => true})
             |> json_response(200) == %{"enabled" => true}
    end

    test "enabled must be a boolean", %{conn: conn} do
      for body <- [%{}, %{"enabled" => "false"}, %{"enabled" => nil}] do
        assert %{"error" => %{"code" => "INVALID_PAYLOAD"}} =
                 conn
                 |> authed()
                 |> put("/v1/notifications/push/settings", body)
                 |> json_response(400)
      end
    end

    test "a storage failure is a 503", %{conn: conn} do
      stub(RepoMock, :get_push_enabled, fn _id -> {:error, :timeout} end)
      stub(RepoMock, :put_push_enabled, fn _id, _enabled -> {:error, :timeout} end)

      capture_log(fn ->
        assert %{"error" => %{"code" => "PUSH_UNAVAILABLE"}} =
                 conn |> authed() |> get("/v1/notifications/push/settings") |> json_response(503)

        assert conn
               |> authed()
               |> put("/v1/notifications/push/settings", %{"enabled" => true})
               |> json_response(503)
      end)
    end
  end

  describe "POST /push/devices" do
    test "registers a device and answers 201 with an opaque id, never the token", %{conn: conn} do
      expect(RepoMock, :put_device, fn @me, _attrs, _max ->
        {:ok, %{id: "opaque", created: true}}
      end)

      response = conn |> authed() |> post("/v1/notifications/push/devices", expo_body())

      assert json_response(response, 201) == %{"id" => "opaque"}
      refute response.resp_body =~ "ExponentPushToken"
    end

    test "registering again answers 200 with the same id", %{conn: conn} do
      expect(RepoMock, :put_device, fn @me, _attrs, _max ->
        {:ok, %{id: "opaque", created: false}}
      end)

      assert conn
             |> authed()
             |> post("/v1/notifications/push/devices", expo_body())
             |> json_response(200) == %{"id" => "opaque"}
    end

    test "registers a web subscription", %{conn: conn} do
      {public, _private} = Encryption.generate_keypair()
      expect(RepoMock, :put_device, fn @me, _attrs, _max -> {:ok, %{id: "w", created: true}} end)

      body = %{
        "provider" => "webpush",
        "platform" => "web",
        "endpoint" => "https://fcm.googleapis.com/fcm/send/abc",
        "p256dh" => Vapid.encode(public),
        "auth" => Vapid.encode(:crypto.strong_rand_bytes(16))
      }

      assert conn
             |> authed()
             |> post("/v1/notifications/push/devices", body)
             |> json_response(201)
    end

    test "invalid devices are a 400", %{conn: conn} do
      assert %{"error" => %{"code" => "INVALID_PAYLOAD"}} =
               conn
               |> authed()
               |> post("/v1/notifications/push/devices", %{"provider" => "expo"})
               |> json_response(400)
    end

    test "the device cap is a 409", %{conn: conn} do
      expect(RepoMock, :put_device, fn _user, _attrs, _max -> {:error, :device_limit} end)

      assert %{"error" => %{"code" => "DEVICE_LIMIT"}} =
               conn
               |> authed()
               |> post("/v1/notifications/push/devices", expo_body())
               |> json_response(409)
    end

    test "a storage failure is a 503 whose log never holds the token", %{conn: conn} do
      expect(RepoMock, :put_device, fn _user, _attrs, _max -> {:error, :timeout} end)

      log =
        capture_log(fn ->
          conn
          |> authed()
          |> post("/v1/notifications/push/devices", expo_body())
          |> json_response(503)
        end)

      assert log =~ "push_request_failed"
      refute log =~ "ExponentPushToken"
    end
  end

  describe "DELETE /push/devices/:id" do
    test "removes the device of the caller, with a 204", %{conn: conn} do
      expect(RepoMock, :delete_device, fn @me, "opaque" -> :ok end)

      assert conn |> authed() |> delete("/v1/notifications/push/devices/opaque") |> response(204)
    end

    test "a storage failure is a 503", %{conn: conn} do
      expect(RepoMock, :delete_device, fn _user, _id -> {:error, :timeout} end)

      capture_log(fn ->
        conn |> authed() |> delete("/v1/notifications/push/devices/opaque") |> json_response(503)
      end)
    end
  end

  describe "GET /push/vapid-public-key" do
    test "answers the public key when VAPID is configured", %{conn: conn} do
      {public, private} = Encryption.generate_keypair()

      Application.put_env(:notifications, :push_delivery,
        vapid_private_key: Vapid.encode(private)
      )

      on_exit(fn -> Application.delete_env(:notifications, :push_delivery) end)

      assert conn
             |> authed()
             |> get("/v1/notifications/push/vapid-public-key")
             |> json_response(200) == %{"public_key" => Vapid.encode(public)}
    end

    test "is a 404 when VAPID is not configured", %{conn: conn} do
      assert %{"error" => %{"code" => "PUSH_NOT_CONFIGURED"}} =
               conn
               |> authed()
               |> get("/v1/notifications/push/vapid-public-key")
               |> json_response(404)
    end
  end
end
