defmodule Notifications.Delivery.Http.HttpcTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Notifications.Delivery.Http
  alias Notifications.Delivery.Http.Httpc

  defp serve(reply) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    test_pid = self()

    Task.start_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 2_000)
      {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
      send(test_pid, {:request, request})
      :gen_tcp.send(socket, reply)
      :gen_tcp.close(socket)
    end)

    "http://127.0.0.1:#{port}/push"
  end

  test "posts the body with its headers and returns status, headers and body" do
    url =
      serve(
        "HTTP/1.1 201 Created\r\nRetry-After: 7\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
      )

    assert {:ok, response} =
             Httpc.post(
               url,
               [{"content-type", "application/json"}, {"x-test", "1"}],
               "{\"a\":1}",
               2_000
             )

    assert response.status == 201
    assert response.body == "ok"
    assert Http.header(response, "retry-after") == "7"
    assert Http.retry_after_ms(response) == 7_000

    assert_receive {:request, request}
    assert request =~ "POST /push"
    assert request =~ ~r/content-type: application\/json/i
    assert request =~ ~r/x-test: 1/i
    assert request =~ "{\"a\":1}"
  end

  test "a request without content type is sent as binary" do
    url = serve("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")

    assert {:ok, %{status: 204}} = Httpc.post(url, [], <<1, 2, 3>>, 2_000)
    assert_receive {:request, request}
    assert request =~ ~r/content-type: application\/octet-stream/i
  end

  test "reports a refused connection without the address" do
    {:ok, listener} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    assert Httpc.post("http://127.0.0.1:#{port}/secret-endpoint", [], "x", 1_000) ==
             {:error, :connect_failed}
  end

  test "reports a timeout when the server never answers" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listener)

    assert Httpc.post("http://127.0.0.1:#{port}/x", [], "x", 100) == {:error, :timeout}
  end

  test "retry_after_ms ignores values that are not a number of seconds" do
    assert Http.retry_after_ms(%{headers: [{"Retry-After", "Wed, 21 Oct 2026 07:28:00 GMT"}]}) ==
             nil

    assert Http.retry_after_ms(%{headers: []}) == nil
  end

  test "stops calling an endpoint that keeps failing and answers fast" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    test_pid = self()

    server =
      spawn_link(fn ->
        for _ <- 1..5 do
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)
          send(test_pid, :hit)

          :gen_tcp.send(
            socket,
            "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          )

          :gen_tcp.close(socket)
        end
      end)

    url = "http://127.0.0.1:#{port}/push"
    on_exit(fn -> Notifications.CircuitBreaker.reset({:http, {"http", "127.0.0.1", port}}) end)

    capture_log(fn ->
      for _ <- 1..5, do: assert({:ok, %{status: 503}} = Httpc.post(url, [], "x", 2_000))
    end)

    for _ <- 1..5, do: assert_receive(:hit)

    assert Httpc.post(url, [], "x", 2_000) == {:error, :circuit_open}
    refute_receive :hit, 100
    Process.exit(server, :normal)
  end

  test "client errors do not open the circuit" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    spawn_link(fn ->
      for _ <- 1..7 do
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )

        :gen_tcp.close(socket)
      end
    end)

    url = "http://127.0.0.1:#{port}/push"
    on_exit(fn -> Notifications.CircuitBreaker.reset({:http, {"http", "127.0.0.1", port}}) end)

    for _ <- 1..7, do: assert({:ok, %{status: 404}} = Httpc.post(url, [], "x", 2_000))
  end
end
