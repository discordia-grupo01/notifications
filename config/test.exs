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

config :notifications, :push_delivery,
  retry_base_ms: 0,
  retry_max_ms: 0,
  max_concurrency: 5

config :opentelemetry, traces_exporter: :none, processors: [{:otel_simple_processor, %{}}]

config :opentelemetry_experimental,
  readers: [
    %{
      module: :otel_metric_reader,
      config: %{
        exporter: {:otel_metric_exporter_pid, {:otel_metric, :notifications_metric_sink}},
        default_temporality_mapping: %{
          counter: :temporality_delta,
          observable_counter: :temporality_delta,
          histogram: :temporality_delta,
          observable_gauge: :temporality_cumulative,
          updown_counter: :temporality_cumulative,
          observable_updowncounter: :temporality_cumulative
        }
      }
    }
  ]

config :logger, level: :warning
config :logger, :console, colors: [enabled: false]
