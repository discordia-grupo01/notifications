defmodule NotificationsWeb.HistoryControllerTest do
  use NotificationsWeb.ConnCase
  import Mox

  alias Notifications.AuthFixtures
  alias Notifications.Unread.RepoMock

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @m1 "00000000-0000-7000-8000-000000000001"
  @m2 "00000000-0000-7000-8000-000000000002"
  @at ~U[2026-10-31 12:00:00.000000Z]

  defp authed(conn),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(@me))

  defp dm_doc(message_id),
    do: %{
      "user_id" => @me,
      "kind" => "direct_message",
      "message_id" => message_id,
      "author_id" => "author",
      "occurred_at" => @at,
      "conversation_id" => "conv-1"
    }

  test "requires Authorization", %{conn: conn} do
    assert json_response(get(conn, "/v1/notifications/history"), 401)["error"]["code"] ==
             "UNAUTHORIZED"
  end

  test "CA2: answers an empty list when there is nothing to show", %{conn: conn} do
    expect(RepoMock, :list_history, fn @me, nil, 50 -> {:ok, []} end)

    body = conn |> authed() |> get("/v1/notifications/history") |> json_response(200)

    assert body == %{"items" => [], "next_cursor" => nil}
  end

  test "CA1: lists the entries, newest first, with the ids to open each conversation", %{
    conn: conn
  } do
    expect(RepoMock, :list_history, fn @me, nil, 50 -> {:ok, [dm_doc(@m2), dm_doc(@m1)]} end)

    body = conn |> authed() |> get("/v1/notifications/history") |> json_response(200)

    assert %{"items" => [first, second], "next_cursor" => nil} = body
    assert first["message_id"] == @m2
    assert second["message_id"] == @m1
    assert first["kind"] == "direct_message"
    assert first["conversation_id"] == "conv-1"
    assert first["occurred_at"] == "2026-10-31T12:00:00.000000Z"
  end

  test "honours limit and before, and returns the cursor of a full page", %{conn: conn} do
    expect(RepoMock, :list_history, fn @me, @m2, 1 -> {:ok, [dm_doc(@m1)]} end)

    body =
      conn
      |> authed()
      |> get("/v1/notifications/history", %{"limit" => "1", "before" => @m2})
      |> json_response(200)

    assert body["next_cursor"] == @m1
  end

  for bad <- ["0", "-1", "101", "abc", "5x", ""] do
    test "400s for limit=#{inspect(bad)}", %{conn: conn} do
      conn = conn |> authed() |> get("/v1/notifications/history", %{"limit" => unquote(bad)})

      assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
    end
  end

  for bad <- ["nope", "123", "00000000-0000-4000-8000-000000000001", ""] do
    test "400s for before=#{inspect(bad)}", %{conn: conn} do
      conn = conn |> authed() |> get("/v1/notifications/history", %{"before" => unquote(bad)})

      assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
    end
  end

  test "400s when the parameters are not plain strings", %{conn: conn} do
    conn = conn |> authed() |> get("/v1/notifications/history?limit[]=1")

    assert json_response(conn, 400)["error"]["code"] == "INVALID_PAYLOAD"
  end

  test "503s when the storage fails", %{conn: conn} do
    expect(RepoMock, :list_history, fn _user, _before, _limit -> {:error, :timeout} end)

    conn = conn |> authed() |> get("/v1/notifications/history")

    assert json_response(conn, 503)["error"]["code"] == "HISTORY_UNAVAILABLE"
  end
end
