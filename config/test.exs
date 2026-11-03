import Config

config :notifications, NotificationsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: "test_secret_key_base_at_least_64_bytes_long_for_phoenix_dev_only",
  server: false,
  debug_errors: false

config :notifications, :start_amqp_consumers, false
config :notifications, :ensure_indexes, false
config :notifications, :unread_repo, Notifications.Unread.RepoMock
config :notifications, :ticket_store, Notifications.Auth.TicketStoreMock
config :notifications, :delivery_repo, Notifications.Delivery.RepoMock
config :notifications, :delivery_http, Notifications.Delivery.HttpMock

config :notifications, :push_senders, %{
  "webpush" => Notifications.Delivery.SenderMock,
  "expo" => Notifications.Delivery.SenderMock
}

config :logger, level: :warning
config :logger, :console, colors: [enabled: false]
