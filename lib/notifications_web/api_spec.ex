defmodule NotificationsWeb.ApiSpec do
  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Info, OpenApi, Paths, Server}

  @impl true
  def spec(_opts \\ []) do
    %OpenApi{
      servers: [Server.from_endpoint(NotificationsWeb.Endpoint)],
      info: %Info{
        title: "Discordia — Notifications",
        description:
          "Indicadores de no leído por canal y por servidor. Todo el estado viaja por WebSocket " <>
            "(canal `notifications:<user_id>` en `/notifications/socket`): al unirse se recibe el " <>
            "estado completo y después los cambios en vivo. Lo único que se pide por REST es el " <>
            "ticket para abrir ese socket.",
        version: "0.1.0"
      },
      paths: Paths.from_router(NotificationsWeb.Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
