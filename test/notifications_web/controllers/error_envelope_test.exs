defmodule NotificationsWeb.ErrorEnvelopeTest do
  use NotificationsWeb.ConnCase

  alias Notifications.AuthFixtures

  @code_regex ~r/^[A-Z][A-Z0-9_]*$/

  defp assert_envelope(body, code) do
    assert %{"error" => %{"code" => ^code, "message" => message, "details" => details}} =
             Jason.decode!(body)

    assert code =~ @code_regex
    assert is_binary(message) and message != ""
    assert is_map(details)
  end

  test "unknown route renders 404 NOT_FOUND with the envelope", %{conn: conn} do
    conn = get(conn, "/v1/notifications/nope")
    assert_envelope(response(conn, 404), "NOT_FOUND")
  end

  test "malformed JSON renders 400 INVALID_BODY with the envelope", %{conn: conn} do
    {400, _headers, body} =
      assert_error_sent(400, fn ->
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header(
          "authorization",
          "Bearer " <> AuthFixtures.token_for("user-1")
        )
        |> post("/v1/notifications/push/devices", "{not json")
      end)

    assert_envelope(body, "INVALID_BODY")
  end

  test "missing token renders 401 UNAUTHORIZED with the envelope", %{conn: conn} do
    conn = get(conn, "/v1/notifications/history")
    assert_envelope(response(conn, 401), "UNAUTHORIZED")
  end

  test "invalid token renders 401 UNAUTHORIZED with the envelope", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer nope")
      |> get("/v1/notifications/history")

    assert_envelope(response(conn, 401), "UNAUTHORIZED")
  end

  test "wrong Accept renders 406 NOT_ACCEPTABLE with the envelope", %{conn: conn} do
    {406, _headers, body} =
      assert_error_sent(406, fn ->
        conn
        |> Plug.Conn.put_req_header("accept", "text/html")
        |> get("/livez")
      end)

    assert_envelope(body, "NOT_ACCEPTABLE")
  end
end
