defmodule NotificationsWeb.SettingsController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Notifications.{Log, Mutes}
  alias NotificationsWeb.{ApiError, Schemas}

  tags ["settings"]

  @client_errors [:forbidden, :channel_not_found, :server_not_found, :invalid_payload]

  operation :index,
    summary: "Lista los servidores y canales que el usuario silenció",
    responses: [
      ok: {"Silenciados del usuario", "application/json", Schemas.MutedScopes},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo leer la configuración", "application/json", Schemas.ErrorResponse}
    ]

  operation :update_server,
    summary: "Silencia o reactiva un servidor completo",
    description:
      "Silenciar un servidor apaga las notificaciones destacadas (menciones) de todos sus canales. La actividad sigue contando como no leída. Es idempotente y las otras sesiones del usuario se enteran por `snapshot`.",
    parameters: [
      server_id: [in: :path, description: "Id del servidor", type: :string, required: true]
    ],
    request_body: {"Estado deseado", "application/json", Schemas.MuteRequest, required: true},
    responses: [
      ok: {"Estado resultante", "application/json", Schemas.ServerMute},
      bad_request: {"`muted` falta o no es booleano", "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      not_found:
        {"El usuario no es miembro del servidor", "application/json", Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo guardar la configuración", "application/json", Schemas.ErrorResponse}
    ]

  operation :update_channel,
    summary: "Silencia o reactiva un canal",
    description:
      "Silenciar un canal apaga sus notificaciones destacadas (menciones). La actividad sigue contando como no leída. Para silenciarlo hay que poder ver el canal; reactivarlo no tiene esa condición. Es idempotente y las otras sesiones del usuario se enteran por `snapshot`.",
    parameters: [
      channel_id: [in: :path, description: "Id del canal", type: :string, required: true]
    ],
    request_body: {"Estado deseado", "application/json", Schemas.MuteRequest, required: true},
    responses: [
      ok: {"Estado resultante", "application/json", Schemas.ChannelMute},
      bad_request: {"`muted` falta o no es booleano", "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      forbidden: {"El usuario no puede ver el canal", "application/json", Schemas.ErrorResponse},
      not_found: {"El canal no existe", "application/json", Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo guardar la configuración", "application/json", Schemas.ErrorResponse}
    ]

  def index(conn, _params) do
    case Mutes.list(conn.assigns.user_id) do
      {:ok, muted} -> json(conn, muted)
      {:error, reason} -> fail(conn, reason)
    end
  end

  def update_server(conn, %{"server_id" => server_id} = params) do
    with {:ok, muted} <- parse_muted(params),
         {:ok, muted} <- Mutes.set_server(conn.assigns.user_id, server_id, muted) do
      json(conn, %{"server_id" => server_id, "muted" => muted})
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  def update_channel(conn, %{"channel_id" => channel_id} = params) do
    with {:ok, muted} <- parse_muted(params),
         {:ok, muted} <- Mutes.set_channel(conn.assigns.user_id, channel_id, muted) do
      json(conn, %{"channel_id" => channel_id, "muted" => muted})
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  defp parse_muted(%{"muted" => muted}) when is_boolean(muted), do: {:ok, muted}
  defp parse_muted(_params), do: {:error, :invalid_payload}

  defp fail(conn, reason) when reason in @client_errors do
    conn
    |> put_status(ApiError.http_status(reason))
    |> json(ApiError.payload(reason))
  end

  defp fail(conn, reason) do
    Logger.error("settings_failed", user_id: conn.assigns.user_id, reason: Log.reason(reason))

    conn
    |> put_status(ApiError.http_status(:settings_unavailable))
    |> json(ApiError.payload(:settings_unavailable))
  end
end
