defmodule Notifications.Push.Local do
  @behaviour Notifications.Push

  @impl true
  def publish(topic, event, payload) do
    NotificationsWeb.Endpoint.broadcast!(topic, event, payload)
  end
end
