defmodule NotificationsWeb.Plugs.PathParamLengthTest do
  use NotificationsWeb.ConnCase

  alias Notifications.AuthFixtures

  @me "11111111-1111-4111-8111-111111111111"

  defp authed(conn),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(@me))

  test "a path parameter longer than 64 characters is rejected before reaching the controller" do
    long = String.duplicate("a", 65)

    for {method, path} <- [
          {:delete, "/v1/notifications/push/devices/#{long}"},
          {:post, "/v1/notifications/notices/#{long}/seen"},
          {:put, "/v1/notifications/settings/servers/#{long}"},
          {:put, "/v1/notifications/settings/channels/#{long}"}
        ] do
      conn =
        build_conn() |> authed() |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = dispatch(conn, @endpoint, method, path, ~s({"muted":true}))

      assert json_response(conn, 400)["error"]["code"] == "INVALID_BODY",
             "#{method} #{path} was not rejected"
    end
  end

  test "a path parameter of exactly 64 characters is let through" do
    conn = %{Plug.Test.conn(:get, "/") | path_params: %{"id" => String.duplicate("a", 64)}}

    refute NotificationsWeb.Plugs.PathParamLength.call(conn, []).halted
  end

  test "a path parameter of 65 characters halts the request" do
    conn = %{Plug.Test.conn(:get, "/") | path_params: %{"id" => String.duplicate("a", 65)}}

    assert NotificationsWeb.Plugs.PathParamLength.call(conn, []).halted
  end

  test "counts characters, not bytes: 64 four-byte characters are let through" do
    conn = %{
      Plug.Test.conn(:get, "/")
      | path_params: %{"id" => String.duplicate("\u{10000}", 64)}
    }

    refute NotificationsWeb.Plugs.PathParamLength.call(conn, []).halted
  end
end
