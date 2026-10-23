defmodule NotificationsWeb.RequestLoggingTest do
  use NotificationsWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Notifications.Auth.TicketStoreMock
  alias Notifications.AuthFixtures

  setup :verify_on_exit!

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
  end

  @me "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"

  defp authed(conn),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> AuthFixtures.token_for(@me))

  defp entries(log), do: log |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  test "a real request is logged with its route pattern and the caller", %{conn: conn} do
    expect(TicketStoreMock, :put, fn _doc -> :ok end)

    log =
      capture_log([level: :debug], fn ->
        conn |> authed() |> post("/v1/notifications/socket-tickets")
      end)

    assert %{
             "route" => "/v1/notifications/socket-tickets",
             "method" => "POST",
             "status" => 201,
             "user_id" => @me
           } = Enum.find(entries(log), &(&1["message"] == "http_request"))
  end

  test "the query string never reaches the logs", %{conn: conn} do
    expect(TicketStoreMock, :put, fn _doc -> :ok end)

    log =
      capture_log([level: :debug], fn ->
        conn
        |> authed()
        |> post("/v1/notifications/socket-tickets?ticket=SECRET-TICKET&token=SECRET-TOKEN")
      end)

    refute log =~ "SECRET"
  end

  test "the request id travels with every line of the request", %{conn: conn} do
    expect(TicketStoreMock, :put, fn _doc -> :ok end)

    log =
      capture_log([level: :debug], fn ->
        conn |> authed() |> post("/v1/notifications/socket-tickets")
      end)

    lines = entries(log)

    request_ids = for %{"request_id" => id} <- lines, uniq: true, do: id
    assert [id] = request_ids
    assert is_binary(id)
    assert Enum.any?(lines, &(&1["message"] == "socket_ticket_issued"))
  end

  test "an unknown route is logged without its path", %{conn: conn} do
    log = capture_log([level: :debug], fn -> get(conn, "/no/existe/#{@other}") end)

    assert %{"route" => "unmatched", "status" => 404} =
             Enum.find(entries(log), &(&1["message"] == "http_request"))

    refute log =~ @other
  end

  test "no line is plain text: everything the request writes is JSON", %{conn: conn} do
    expect(TicketStoreMock, :put, fn _doc -> :ok end)

    log =
      capture_log([level: :debug], fn ->
        conn |> authed() |> post("/v1/notifications/socket-tickets")
      end)

    assert log != ""

    for line <- String.split(log, "\n", trim: true),
        do: assert(%{"level" => _} = Jason.decode!(line))

    refute log =~ "Processing with"
    refute log =~ "Parameters"
  end
end
