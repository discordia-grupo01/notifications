defmodule NotificationsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :notifications

  @dialyzer {:nowarn_function, call: 2}

  socket "/notifications/socket", NotificationsWeb.UserSocket,
    websocket: true,
    longpoll: false

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug NotificationsWeb.Router
end
