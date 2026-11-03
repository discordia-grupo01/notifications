import Config

config :notifications, NotificationsWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [json: NotificationsWeb.ErrorJSON]],
  pubsub_server: Notifications.PubSub

config :logger, :console,
  format: {Notifications.Log.JSONFormatter, :format},
  metadata: [
    :request_id,
    :channel_id,
    :conversation_id,
    :server_id,
    :message_id,
    :user_id,
    :author_id,
    :hint,
    :count,
    :reason,
    :cause,
    :status,
    :attempt,
    :attempts,
    :retry_in_ms,
    :routing_key,
    :event_id,
    :exchange,
    :queue,
    :channels,
    :users,
    :method,
    :route,
    :duration_ms,
    :topic,
    :event,
    :result,
    :transport,
    :version,
    :provider,
    :device_id,
    :log_level
  ]

config :phoenix, :logger, false

config :phoenix,
       :filter_parameters,
       {:keep, ["id", "channel_id", "message_id", "vsn"]}

import_config "#{config_env()}.exs"
