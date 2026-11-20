defmodule NotificationsWeb.NoticesControllerTest do
  use NotificationsWeb.ConnCase
  import Mox

  alias Notifications.AuthFixtures
  alias Notifications.Notices.RepoMock
  alias Notifications.PushMock

  setup :verify_on_exit!

  setup do
    stub(PushMock, :publish, fn _topic, _event, _payload -> :ok end)
    Application.put_env(:notifications, :push, PushMock)
    on_exit(fn -> Application.delete_env(:notifications, :push) end)
  end

  @me "11111111-1111-4111-8111-111111111111"
  @notice_id "00000000-0000-7000-8000-000000000001"
  @server_id "22222222-2222-4222-8222-222222222222"
  @at ~U[2026-11-20 14:03:11.000000Z]

  defp authed(conn),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(@me))

  test "requires Authorization", %{conn: conn} do
    assert json_response(get(conn, "/v1/notifications/notices"), 401)["error"]["code"] ==
             "UNAUTHORIZED"

    assert json_response(post(conn, "/v1/notifications/notices/#{@notice_id}/seen"), 401)
  end

  test "lists the notices the user has not seen", %{conn: conn} do
    expect(RepoMock, :list_unseen, fn @me ->
      {:ok,
       [
         %{
           "_id" => @me <> ":" <> @server_id,
           "notice_id" => @notice_id,
           "user_id" => @me,
           "kind" => "server_deleted",
           "server_id" => @server_id,
           "server_name" => "Club de Lectura",
           "occurred_at" => @at,
           "seen_at" => nil
         }
       ]}
    end)

    body = conn |> authed() |> get("/v1/notifications/notices") |> json_response(200)

    assert body == %{
             "items" => [
               %{
                 "id" => @notice_id,
                 "kind" => "server_deleted",
                 "server_id" => @server_id,
                 "server_name" => "Club de Lectura",
                 "occurred_at" => "2026-11-20T14:03:11.000000Z"
               }
             ]
           }
  end

  test "answers an empty list when there is nothing to show", %{conn: conn} do
    expect(RepoMock, :list_unseen, fn @me -> {:ok, []} end)

    assert conn |> authed() |> get("/v1/notifications/notices") |> json_response(200) ==
             %{"items" => []}
  end

  test "answers 503 when the notices can't be read", %{conn: conn} do
    expect(RepoMock, :list_unseen, fn @me -> {:error, :down} end)

    assert json_response(conn |> authed() |> get("/v1/notifications/notices"), 503)["error"][
             "code"
           ] == "NOTICES_UNAVAILABLE"
  end

  test "marks a notice as seen and tells the other devices", %{conn: conn} do
    expect(RepoMock, :mark_seen, fn @me, @notice_id, %DateTime{} -> :ok end)

    expect(PushMock, :publish, fn "user:" <> @me, "changed", %{"resource" => "notices"} ->
      :ok
    end)

    conn = conn |> authed() |> post("/v1/notifications/notices/#{@notice_id}/seen")

    assert response(conn, 204) == ""
  end

  test "rejects an id that is not a UUID without touching the store", %{conn: conn} do
    conn = conn |> authed() |> post("/v1/notifications/notices/not-a-uuid/seen")

    assert json_response(conn, 400)["error"]["code"] == "INVALID_BODY"
  end

  test "answers 503 when the seen mark can't be saved", %{conn: conn} do
    expect(RepoMock, :mark_seen, fn @me, @notice_id, %DateTime{} -> {:error, :down} end)

    conn = conn |> authed() |> post("/v1/notifications/notices/#{@notice_id}/seen")

    assert json_response(conn, 503)["error"]["code"] == "NOTICES_UNAVAILABLE"
  end
end
