defmodule Notifications.PushTest do
  use ExUnit.Case, async: false
  import Mox

  setup :verify_on_exit!

  test "the facade delegates to the configured implementation" do
    Application.put_env(:notifications, :push, Notifications.PushMock)
    on_exit(fn -> Application.delete_env(:notifications, :push) end)

    expect(Notifications.PushMock, :publish, fn "user:u", "resync", %{} -> :ok end)

    assert Notifications.Push.publish("user:u", "resync", %{}) == :ok
  end

  test "by default it broadcasts to the sockets of this instance" do
    NotificationsWeb.Endpoint.subscribe("user:local")

    assert Notifications.Push.publish("user:local", "resync", %{"a" => 1}) == :ok

    assert_receive %Phoenix.Socket.Broadcast{event: "resync", payload: %{"a" => 1}}
  end
end
