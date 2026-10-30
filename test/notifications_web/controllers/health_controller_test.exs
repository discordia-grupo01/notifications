defmodule NotificationsWeb.HealthControllerTest do
  use NotificationsWeb.ConnCase
  import Mox

  setup :verify_on_exit!

  test "GET /health answers 200 with a JSON body and never touches Mongo", %{conn: conn} do
    conn = get(conn, "/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "GET /livez never touches Mongo and always answers 200", %{conn: conn} do
    conn = get(conn, "/livez")
    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "GET /readyz is 200 when Mongo is reachable", %{conn: conn} do
    expect(Notifications.Unread.RepoMock, :ping, fn -> :ok end)

    conn = get(conn, "/readyz")
    assert json_response(conn, 200) == %{"status" => "ready"}
  end

  test "GET /readyz is 503 when Mongo isn't reachable", %{conn: conn} do
    expect(Notifications.Unread.RepoMock, :ping, fn -> {:error, :timeout} end)

    conn = get(conn, "/readyz")
    assert json_response(conn, 503) == %{"status" => "unavailable", "detail" => "mongo"}
  end
end
