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

  defp put_json(conn, path, body), do: conn |> authed() |> put(path, body)

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

  defp saved(scope_id, attrs),
    do:
      expect(RepoMock, :get_setting, fn @me, ^scope_id ->
        Map.merge(%{"scope_id" => scope_id, "muted" => false, "level" => nil}, attrs)
      end)

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
    test "lists what the caller muted and the levels they chose", %{conn: conn} do
      expect(RepoMock, :list_settings, fn @me ->
        {:ok,
         [
           %{"scope" => "server", "scope_id" => @s1, "server_id" => @s1, "muted" => true},
           %{
             "scope" => "channel",
             "scope_id" => @c1,
             "server_id" => "s2",
             "muted" => false,
             "level" => "all"
           }
         ]}
      end)

      body = conn |> authed() |> get("/v1/notifications/settings") |> json_response(200)

      assert body == %{
               "servers" => [@s1],
               "channels" => [],
               "preferences" => %{
                 "servers" => [],
                 "channels" => [%{"channel_id" => @c1, "server_id" => "s2", "level" => "all"}]
               }
             }
    end

    test "answers empty lists when nothing is configured", %{conn: conn} do
      expect(RepoMock, :list_settings, fn @me -> {:ok, []} end)

      body = conn |> authed() |> get("/v1/notifications/settings") |> json_response(200)

      assert body == %{
               "servers" => [],
               "channels" => [],
               "preferences" => %{"servers" => [], "channels" => []}
             }
    end

    test "503s when the storage fails", %{conn: conn} do
      expect(RepoMock, :list_settings, fn @me -> {:error, :timeout} end)

      conn = conn |> authed() |> get("/v1/notifications/settings")

      assert json_response(conn, 503)["error"]["code"] == "SETTINGS_UNAVAILABLE"
    end
  end

  describe "PUT /v1/notifications/settings/servers/:server_id" do
    test "CA2 (mute): mutes the server", %{conn: conn} do
      stub_visible()
      expect(RepoMock, :put_setting, fn @me, :server, @s1, @s1, %{muted: true} -> :ok end)
      saved(@s1, %{"muted" => true})

      conn = put_json(conn, "/v1/notifications/settings/servers/#{@s1}", %{"muted" => true})

      assert json_response(conn, 200) == %{"server_id" => @s1, "muted" => true, "level" => nil}
    end

    test "CA1 (levels): stores the level without touching muted", %{conn: conn} do
      stub_visible()

      expect(RepoMock, :put_setting, fn @me, :server, @s1, @s1, changes ->
        assert changes == %{level: "none"}
        :ok
      end)

      saved(@s1, %{"level" => "none"})

      conn = put_json(conn, "/v1/notifications/settings/servers/#{@s1}", %{"level" => "none"})

      assert json_response(conn, 200) == %{
               "server_id" => @s1,
               "muted" => false,
               "level" => "none"
             }
    end

    test "accepts muted and level in the same request", %{conn: conn} do
      stub_visible()

      expect(RepoMock, :put_setting, fn @me, :server, @s1, @s1, changes ->
        assert changes == %{muted: true, level: "all"}
        :ok
      end)

      saved(@s1, %{"muted" => true, "level" => "all"})

      conn =
        put_json(conn, "/v1/notifications/settings/servers/#{@s1}", %{
          "muted" => true,
          "level" => "all"
        })

      assert json_response(conn, 200) == %{"server_id" => @s1, "muted" => true, "level" => "all"}
    end

    test "a null level clears the preference", %{conn: conn} do
      expect(RepoMock, :put_setting, fn @me, :server, @s1, @s1, changes ->
        assert changes == %{level: nil}
        :ok
      end)

      expect(RepoMock, :get_setting, fn @me, @s1 -> nil end)

      conn = put_json(conn, "/v1/notifications/settings/servers/#{@s1}", %{"level" => nil})

      assert json_response(conn, 200) == %{"server_id" => @s1, "muted" => false, "level" => nil}
    end

    test "CA3: unmutes the server", %{conn: conn} do
      expect(RepoMock, :put_setting, fn @me, :server, @s1, @s1, %{muted: false} -> :ok end)
      expect(RepoMock, :get_setting, fn @me, @s1 -> nil end)

      conn = put_json(conn, "/v1/notifications/settings/servers/#{@s1}", %{"muted" => false})

      assert json_response(conn, 200) == %{"server_id" => @s1, "muted" => false, "level" => nil}
    end

    test "404s for a server the caller does not belong to", %{conn: conn} do
      stub(RepoMock, :list_memberships, fn @me -> {:ok, []} end)

      conn = put_json(conn, "/v1/notifications/settings/servers/#{@s1}", %{"level" => "all"})

      assert json_response(conn, 404)["error"]["code"] == "SERVER_NOT_FOUND"
    end

    test "400s when neither muted nor level is sent", %{conn: conn} do
      conn = put_json(conn, "/v1/notifications/settings/servers/#{@s1}", %{})

      assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
    end

    test "400s when muted is not a boolean", %{conn: conn} do
      conn = put_json(conn, "/v1/notifications/settings/servers/#{@s1}", %{"muted" => "yes"})

      assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
    end

    test "400s for a level it does not know", %{conn: conn} do
      conn = put_json(conn, "/v1/notifications/settings/servers/#{@s1}", %{"level" => "shouting"})

      assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
    end

    test "400s when level is not a string", %{conn: conn} do
      conn = put_json(conn, "/v1/notifications/settings/servers/#{@s1}", %{"level" => 3})

      assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
    end

    test "503s when the storage fails", %{conn: conn} do
      stub_visible()

      expect(RepoMock, :put_setting, fn _user, _scope, _id, _server, _changes ->
        {:error, :timeout}
      end)

      conn = put_json(conn, "/v1/notifications/settings/servers/#{@s1}", %{"muted" => true})

      assert json_response(conn, 503)["error"]["code"] == "SETTINGS_UNAVAILABLE"
    end
  end

  describe "PUT /v1/notifications/settings/channels/:channel_id" do
    test "CA1 (mute): mutes a channel the caller can see", %{conn: conn} do
      stub_visible()
      expect(RepoMock, :put_setting, fn @me, :channel, @c1, @s1, %{muted: true} -> :ok end)
      saved(@c1, %{"muted" => true})

      conn = put_json(conn, "/v1/notifications/settings/channels/#{@c1}", %{"muted" => true})

      assert json_response(conn, 200) == %{"channel_id" => @c1, "muted" => true, "level" => nil}
    end

    test "CA1 (levels): stores the channel level", %{conn: conn} do
      stub_visible()
      expect(RepoMock, :put_setting, fn @me, :channel, @c1, @s1, %{level: "all"} -> :ok end)
      saved(@c1, %{"level" => "all"})

      conn = put_json(conn, "/v1/notifications/settings/channels/#{@c1}", %{"level" => "all"})

      assert json_response(conn, 200) == %{
               "channel_id" => @c1,
               "muted" => false,
               "level" => "all"
             }
    end

    test "CA3: unmutes a channel", %{conn: conn} do
      expect(RepoMock, :put_setting, fn @me, :channel, @c1, nil, %{muted: false} -> :ok end)
      expect(RepoMock, :get_setting, fn @me, @c1 -> nil end)

      conn = put_json(conn, "/v1/notifications/settings/channels/#{@c1}", %{"muted" => false})

      assert json_response(conn, 200) == %{"channel_id" => @c1, "muted" => false, "level" => nil}
    end

    test "403s for a channel the caller cannot see", %{conn: conn} do
      stub_visible([])

      conn = put_json(conn, "/v1/notifications/settings/channels/#{@c1}", %{"level" => "none"})

      assert json_response(conn, 403)["error"]["code"] == "FORBIDDEN"
    end

    test "404s for an unknown channel", %{conn: conn} do
      stub(RepoMock, :get_channel, fn _id -> nil end)

      conn = put_json(conn, "/v1/notifications/settings/channels/nope", %{"muted" => true})

      assert json_response(conn, 404)["error"]["code"] == "CHANNEL_NOT_FOUND"
    end

    test "400s when muted is not a boolean", %{conn: conn} do
      conn = put_json(conn, "/v1/notifications/settings/channels/#{@c1}", %{"muted" => 1})

      assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
    end

    test "400s for a level it does not know", %{conn: conn} do
      conn = put_json(conn, "/v1/notifications/settings/channels/#{@c1}", %{"level" => "ALL"})

      assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
    end
  end
end
