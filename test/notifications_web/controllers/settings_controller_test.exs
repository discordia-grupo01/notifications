defmodule NotificationsWeb.SettingsControllerTest do
  use NotificationsWeb.ConnCase
  import Mox

  alias Notifications.AuthFixtures
  alias Notifications.Unread.RepoMock

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @s1 "s1"
  @c1 "c1"

  defp authed(conn),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(@me))

  defp stub_visible(channel_ids \\ [@c1]) do
    stub(RepoMock, :list_memberships, fn @me ->
      {:ok,
       [
         %{
           "server_id" => @s1,
           "user_id" => @me,
           "role_ids" => ["everyone"],
           "joined_at" => ~U[1970-01-01 00:00:00Z]
         }
       ]}
    end)

    stub(RepoMock, :get_server_owners, fn _ids -> {:ok, %{}} end)

    stub(RepoMock, :list_roles, fn _ids ->
      {:ok,
       [
         %{
           "_id" => "everyone",
           "server_id" => @s1,
           "permissions" => ["VIEW_CHANNELS"],
           "is_everyone" => true
         }
       ]}
    end)

    stub(RepoMock, :list_channels, fn _ids ->
      {:ok, Enum.map(channel_ids, &%{"_id" => &1, "server_id" => @s1, "kind" => "text"})}
    end)

    stub(RepoMock, :list_overrides, fn _ids -> {:ok, []} end)

    stub(RepoMock, :get_channel, fn id -> %{"_id" => id, "server_id" => @s1, "kind" => "text"} end)
  end

  describe "authentication" do
    test "GET /v1/notifications/settings requires Authorization", %{conn: conn} do
      assert json_response(get(conn, "/v1/notifications/settings"), 401)["error"]["code"] ==
               "UNAUTHORIZED"
    end

    test "PUT on a server requires Authorization", %{conn: conn} do
      conn = put(conn, "/v1/notifications/settings/servers/#{@s1}", %{"muted" => true})

      assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
    end

    test "PUT on a channel requires Authorization", %{conn: conn} do
      conn = put(conn, "/v1/notifications/settings/channels/#{@c1}", %{"muted" => true})

      assert json_response(conn, 401)["error"]["code"] == "UNAUTHORIZED"
    end
  end

  describe "GET /v1/notifications/settings" do
    test "lists what the caller muted", %{conn: conn} do
      expect(RepoMock, :list_mutes, fn @me ->
        {:ok,
         [
           %{"scope" => "server", "scope_id" => @s1, "server_id" => @s1},
           %{"scope" => "channel", "scope_id" => @c1, "server_id" => "s2"}
         ]}
      end)

      body = conn |> authed() |> get("/v1/notifications/settings") |> json_response(200)

      assert body == %{
               "servers" => [@s1],
               "channels" => [%{"channel_id" => @c1, "server_id" => "s2"}]
             }
    end

    test "answers empty lists when nothing is muted", %{conn: conn} do
      expect(RepoMock, :list_mutes, fn @me -> {:ok, []} end)

      body = conn |> authed() |> get("/v1/notifications/settings") |> json_response(200)

      assert body == %{"servers" => [], "channels" => []}
    end

    test "503s when the storage fails", %{conn: conn} do
      expect(RepoMock, :list_mutes, fn @me -> {:error, :timeout} end)

      conn = conn |> authed() |> get("/v1/notifications/settings")

      assert json_response(conn, 503)["error"]["code"] == "SETTINGS_UNAVAILABLE"
    end
  end

  describe "PUT /v1/notifications/settings/servers/:server_id" do
    test "CA2: mutes the server", %{conn: conn} do
      stub_visible()
      expect(RepoMock, :put_mute, fn @me, :server, @s1, @s1 -> :ok end)

      conn =
        conn |> authed() |> put("/v1/notifications/settings/servers/#{@s1}", %{"muted" => true})

      assert json_response(conn, 200) == %{"server_id" => @s1, "muted" => true}
    end

    test "CA3: unmutes the server", %{conn: conn} do
      expect(RepoMock, :delete_mute, fn @me, @s1 -> :ok end)

      conn =
        conn |> authed() |> put("/v1/notifications/settings/servers/#{@s1}", %{"muted" => false})

      assert json_response(conn, 200) == %{"server_id" => @s1, "muted" => false}
    end

    test "404s for a server the caller does not belong to", %{conn: conn} do
      stub(RepoMock, :list_memberships, fn @me -> {:ok, []} end)

      conn =
        conn |> authed() |> put("/v1/notifications/settings/servers/#{@s1}", %{"muted" => true})

      assert json_response(conn, 404)["error"]["code"] == "SERVER_NOT_FOUND"
    end

    test "400s when muted is missing", %{conn: conn} do
      conn = conn |> authed() |> put("/v1/notifications/settings/servers/#{@s1}", %{})

      assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
    end

    test "400s when muted is not a boolean", %{conn: conn} do
      conn =
        conn |> authed() |> put("/v1/notifications/settings/servers/#{@s1}", %{"muted" => "yes"})

      assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
    end

    test "503s when the storage fails", %{conn: conn} do
      stub_visible()
      expect(RepoMock, :put_mute, fn _user, _scope, _id, _server -> {:error, :timeout} end)

      conn =
        conn |> authed() |> put("/v1/notifications/settings/servers/#{@s1}", %{"muted" => true})

      assert json_response(conn, 503)["error"]["code"] == "SETTINGS_UNAVAILABLE"
    end
  end

  describe "PUT /v1/notifications/settings/channels/:channel_id" do
    test "CA1: mutes a channel the caller can see", %{conn: conn} do
      stub_visible()
      expect(RepoMock, :put_mute, fn @me, :channel, @c1, @s1 -> :ok end)

      conn =
        conn |> authed() |> put("/v1/notifications/settings/channels/#{@c1}", %{"muted" => true})

      assert json_response(conn, 200) == %{"channel_id" => @c1, "muted" => true}
    end

    test "CA3: unmutes a channel", %{conn: conn} do
      expect(RepoMock, :delete_mute, fn @me, @c1 -> :ok end)

      conn =
        conn |> authed() |> put("/v1/notifications/settings/channels/#{@c1}", %{"muted" => false})

      assert json_response(conn, 200) == %{"channel_id" => @c1, "muted" => false}
    end

    test "403s for a channel the caller cannot see", %{conn: conn} do
      stub_visible([])

      conn =
        conn |> authed() |> put("/v1/notifications/settings/channels/#{@c1}", %{"muted" => true})

      assert json_response(conn, 403)["error"]["code"] == "FORBIDDEN"
    end

    test "404s for an unknown channel", %{conn: conn} do
      stub(RepoMock, :get_channel, fn _id -> nil end)

      conn =
        conn |> authed() |> put("/v1/notifications/settings/channels/nope", %{"muted" => true})

      assert json_response(conn, 404)["error"]["code"] == "CHANNEL_NOT_FOUND"
    end

    test "400s when muted is not a boolean", %{conn: conn} do
      conn =
        conn |> authed() |> put("/v1/notifications/settings/channels/#{@c1}", %{"muted" => 1})

      assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
    end
  end
end
