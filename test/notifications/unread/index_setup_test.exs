defmodule Notifications.Unread.IndexSetupTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox

  alias Notifications.Unread.IndexSetup

  setup :set_mox_global
  setup :verify_on_exit!

  test "runs once when the repo is ready" do
    expect(Notifications.Unread.RepoMock, :ensure_indexes, fn -> :ok end)
    expect(Notifications.Delivery.RepoMock, :ensure_indexes, fn -> :ok end)

    assert :ok = IndexSetup.run(retry_ms: 1)
  end

  test "retries while Mongo is not reachable yet" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    expect(Notifications.Unread.RepoMock, :ensure_indexes, 3, fn ->
      case Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) do
        3 -> :ok
        _ -> {:error, :not_connected}
      end
    end)

    expect(Notifications.Delivery.RepoMock, :ensure_indexes, fn -> :ok end)

    capture_log(fn -> assert :ok = IndexSetup.run(retry_ms: 1) end)
    assert Agent.get(calls, & &1) == 3
  end

  test "gives up after the maximum attempts without crashing" do
    stub(Notifications.Unread.RepoMock, :ensure_indexes, fn -> {:error, :down} end)

    log = capture_log(fn -> assert :ok = IndexSetup.run(retry_ms: 0) end)

    entries = log |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(
             entries,
             &match?(%{"message" => "indexes_failed", "level" => "error", "attempts" => 30}, &1)
           )
  end

  test "retries when only the delivery indexes fail" do
    stub(Notifications.Unread.RepoMock, :ensure_indexes, fn -> :ok end)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    expect(Notifications.Delivery.RepoMock, :ensure_indexes, 2, fn ->
      case Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) do
        2 -> :ok
        _ -> {:error, :not_connected}
      end
    end)

    capture_log(fn -> assert :ok = IndexSetup.run(retry_ms: 1) end)
    assert Agent.get(calls, & &1) == 2
  end
end
