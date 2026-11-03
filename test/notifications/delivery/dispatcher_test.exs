defmodule Notifications.Delivery.DispatcherTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox
  import Notifications.DeliveryHelpers

  alias Notifications.Delivery.{Dispatcher, RepoMock, SenderMock}

  setup :set_mox_global
  setup :verify_on_exit!

  @payload %{title: "t", body: "b", data: %{}}

  defp device(extra \\ %{}),
    do: Map.merge(%{"_id" => "d1", "user_id" => "u1", "provider" => "expo"}, extra)

  test "sends once and records that the device was reached" do
    expect(RepoMock, :claim_delivery, fn "e1", "d1", %DateTime{} -> :claimed end)
    expect(SenderMock, :send, fn %{"_id" => "d1"}, @payload -> :ok end)
    expect(RepoMock, :mark_device, fn "d1", :ok -> :ok end)

    assert Dispatcher.deliver("e1", device(), @payload) == :ok
  end

  test "an event delivered twice to the same device is sent once" do
    expect(RepoMock, :claim_delivery, fn _e, _d, _at -> :duplicate end)

    assert Dispatcher.deliver("e1", device(), @payload) == :duplicate
  end

  test "an invalid token removes the device" do
    expect(RepoMock, :claim_delivery, fn _e, _d, _at -> :claimed end)
    expect(SenderMock, :send, fn _device, _payload -> {:error, :invalid_token} end)
    expect(RepoMock, :delete_devices, fn ["d1"] -> :ok end)

    assert Dispatcher.deliver("e1", device(), @payload) == :ok
  end

  test "a temporary failure is retried and then succeeds" do
    expect(RepoMock, :claim_delivery, fn _e, _d, _at -> :claimed end)

    expect(SenderMock, :send, 3, fn _device, _payload ->
      case Process.get(:attempts, 0) do
        n when n < 2 ->
          Process.put(:attempts, n + 1)
          {:error, {:retry, :server_error, nil}}

        _ ->
          :ok
      end
    end)

    expect(RepoMock, :mark_device, fn "d1", :ok -> :ok end)

    assert Dispatcher.deliver("e1", device(), @payload) == :ok
  end

  test "gives up after the maximum attempts without removing the device" do
    expect(RepoMock, :claim_delivery, fn _e, _d, _at -> :claimed end)

    expect(SenderMock, :send, 3, fn _device, _payload -> {:error, {:retry, :rate_limited, 50}} end)

    expect(RepoMock, :mark_device, fn "d1", {:error, "gave_up_rate_limited"} -> :ok end)

    log = capture_log(fn -> assert Dispatcher.deliver("e1", device(), @payload) == :ok end)
    assert log =~ "push_gave_up"
  end

  test "a permanent failure is recorded and not retried" do
    expect(RepoMock, :claim_delivery, fn _e, _d, _at -> :claimed end)
    expect(SenderMock, :send, fn _device, _payload -> {:error, {:failed, :http_403}} end)
    expect(RepoMock, :mark_device, fn "d1", {:error, "http_403"} -> :ok end)

    assert capture_log(fn -> Dispatcher.deliver("e1", device(), @payload) end) =~ "push_failed"
  end

  test "a failure to claim does not send" do
    expect(RepoMock, :claim_delivery, fn _e, _d, _at -> {:error, :timeout} end)

    assert capture_log(fn -> Dispatcher.deliver("e1", device(), @payload) end) =~
             "push_claim_failed"
  end

  test "a failure to record the outcome is only logged" do
    expect(RepoMock, :claim_delivery, fn _e, _d, _at -> :claimed end)
    expect(SenderMock, :send, fn _device, _payload -> :ok end)
    expect(RepoMock, :mark_device, fn _id, _outcome -> {:error, :timeout} end)

    assert capture_log(fn -> Dispatcher.deliver("e1", device(), @payload) end) =~
             "push_mark_failed"
  end

  test "dispatch sends in the background, one task per device" do
    test_pid = self()
    stub(RepoMock, :claim_delivery, fn _e, _d, _at -> :claimed end)
    stub(RepoMock, :mark_device, fn _id, _outcome -> :ok end)

    stub(SenderMock, :send, fn %{"_id" => id}, _payload ->
      send(test_pid, {:sent, id})
      :ok
    end)

    assert Dispatcher.dispatch("e1", [device(), device(%{"_id" => "d2"})], @payload) == :ok
    await_deliveries()

    assert_received {:sent, "d1"}
    assert_received {:sent, "d2"}
  end

  test "when too many deliveries are in flight the extra ones are dropped, not queued" do
    test_pid = self()
    stub(RepoMock, :claim_delivery, fn _e, _d, _at -> :claimed end)
    stub(RepoMock, :mark_device, fn _id, _outcome -> :ok end)

    stub(SenderMock, :send, fn _device, _payload ->
      receive do
        :go -> send(test_pid, :sent)
      end

      :ok
    end)

    devices = for n <- 1..8, do: device(%{"_id" => "d#{n}"})

    log = capture_log(fn -> Dispatcher.dispatch("e1", devices, @payload) end)

    assert log =~ "push_dropped"
    pids = Task.Supervisor.children(Notifications.Delivery.TaskSupervisor)
    assert length(pids) == 5
    Enum.each(pids, &send(&1, :go))
    await_deliveries()
  end
end
