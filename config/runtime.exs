import Config

default_mongo_url =
  if config_env() == :test,
    do: "mongodb://localhost:27017/notifications_test",
    else: "mongodb://localhost:27017/notifications_dev"

log_level =
  case config_env() do
    :dev -> "debug"
    :test -> "warning"
    :prod -> "info"
  end
  |> then(&System.get_env("LOG_LEVEL", &1))
  |> String.downcase()
  |> case do
    "debug" -> :debug
    "info" -> :info
    level when level in ["warn", "warning"] -> :warning
    "error" -> :error
    other -> raise "LOG_LEVEL must be one of debug, info, warning, error (got: #{inspect(other)})"
  end

config :logger, level: log_level

otlp_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "")

config :opentelemetry,
  text_map_propagators: [:trace_context],
  resource: [service: [name: System.get_env("OTEL_SERVICE_NAME", "notifications")]]

if config_env() != :test do
  if otlp_endpoint == "" do
    config :opentelemetry, traces_exporter: :none
    config :opentelemetry_experimental, readers: []
  else
    config :opentelemetry, traces_exporter: :otlp
    config :opentelemetry_exporter, otlp_protocol: :http_protobuf

    config :opentelemetry_experimental,
      readers: [
        %{
          module: :otel_metric_reader,
          config: %{
            exporter: {:otel_exporter_metrics_otlp, %{}},
            export_interval_ms: 60_000,
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
  end
end

if config_env() != :test do
  log_ship_url = System.get_env("LOG_SHIP_URL", "")

  log_ship_key =
    case System.get_env("LOG_SHIP_API_KEY", "") do
      "" ->
        System.get_env("OTEL_EXPORTER_OTLP_HEADERS", "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.split(&1, "=", parts: 2))
        |> Enum.find_value("", fn
          [name, value] ->
            if String.downcase(String.trim(name)) == "api-key", do: String.trim(value)

          _other ->
            nil
        end)

      key ->
        key
    end

  if log_ship_url != "" and log_ship_key != "" do
    config :notifications, :log_shipper,
      url: log_ship_url,
      api_key: log_ship_key,
      service: System.get_env("OTEL_SERVICE_NAME", "notifications")
  end
end

config :notifications,
  mongo_url: System.get_env("MONGO_URL", default_mongo_url),
  mongo_pool_size: String.to_integer(System.get_env("MONGO_POOL_SIZE", "10")),
  rabbitmq_url: System.get_env("RABBITMQ_URL", "amqp://guest:guest@localhost:5672")

if config_env() != :test do
  present = fn name ->
    case System.get_env(name) do
      value when value in [nil, ""] -> nil
      value -> value
    end
  end

  push_delivery =
    [
      vapid_private_key: present.("VAPID_PRIVATE_KEY"),
      vapid_subject: present.("VAPID_SUBJECT"),
      expo_url: present.("EXPO_PUSH_URL"),
      expo_access_token: present.("EXPO_ACCESS_TOKEN"),
      max_devices:
        present.("PUSH_MAX_DEVICES") && String.to_integer(present.("PUSH_MAX_DEVICES")),
      allowed_hosts:
        present.("PUSH_ALLOWED_HOSTS") &&
          String.split(present.("PUSH_ALLOWED_HOSTS"), ",", trim: true)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)

  config :notifications, :push_delivery, push_delivery
end

if config_env() == :prod do
  allowed_origins =
    System.get_env(
      "CHECK_ORIGIN",
      "https://discordia-g1.vercel.app,https://discordia-g1.duckdns.org"
    )

  config :notifications, NotificationsWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE"),
    check_origin:
      if(allowed_origins == "false",
        do: false,
        else: String.split(allowed_origins, ",", trim: true)
      ),
    server: true

  config :notifications,
    mongo_url: System.fetch_env!("MONGO_URL"),
    rabbitmq_url: System.fetch_env!("RABBITMQ_URL"),
    history_retention_days: String.to_integer(System.get_env("HISTORY_RETENTION_DAYS", "0"))
end
