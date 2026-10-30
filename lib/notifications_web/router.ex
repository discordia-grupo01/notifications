defmodule NotificationsWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug NotificationsWeb.Plugs.Authenticate
  end

  scope "/", NotificationsWeb do
    pipe_through :api

    get "/health", HealthController, :health
    get "/livez", HealthController, :livez
    get "/readyz", HealthController, :readyz
  end

  scope "/v1/notifications", NotificationsWeb do
    pipe_through [:api, :authenticated]

    post "/socket-tickets", SocketTicketController, :create
  end
end
