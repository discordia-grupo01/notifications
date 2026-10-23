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

config :notifications,
  mongo_url: System.get_env("MONGO_URL", default_mongo_url),
  mongo_pool_size: String.to_integer(System.get_env("MONGO_POOL_SIZE", "10")),
  rabbitmq_url: System.get_env("RABBITMQ_URL", "amqp://guest:guest@localhost:5672")

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
    rabbitmq_url: System.fetch_env!("RABBITMQ_URL")
end
