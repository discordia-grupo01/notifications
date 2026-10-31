defmodule NotificationsWeb.SettingsController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Notifications.{Log, Settings}
  alias NotificationsWeb.{ApiError, Schemas}

  tags ["settings"]

  @client_errors [:forbidden, :channel_not_found, :server_not_found, :invalid_payload]

  operation :index,
    summary: "Lista los servidores y canales que el usuario silenció o configuró",
    description:
      "`servers` y `channels` son los silenciados. `preferences` lista las preferencias de nivel (`all`, `mentions`, `none`) que el usuario fijó; lo que no aparece usa el valor heredado o el por defecto (`mentions`).",
    responses: [
      ok: {"Configuración del usuario", "application/json", Schemas.SettingsListing},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo leer la configuración", "application/json", Schemas.ErrorResponse}
    ]

  operation :update_server,
    summary: "Silencia, reactiva o configura el nivel de notificación de un servidor",
    description:
      "Acepta `muted`, `level` o ambos; solo cambia lo que se manda. Silenciar apaga todos los avisos destacados de sus canales (la actividad sigue contando como no leída). `level` elige qué avisa: `all` (todos los mensajes), `mentions` (solo menciones, el valor por defecto) o `none`. `level: null` borra la preferencia. Un canal con su propia preferencia gana sobre la del servidor; silenciar siempre gana. Es idempotente y las otras sesiones del usuario se enteran por `snapshot`.",
    parameters: [
      server_id: [in: :path, description: "Id del servidor", type: :string, required: true]
    ],
    request_body: {"Estado deseado", "application/json", Schemas.SettingsRequest, required: true},
    responses: [
      ok: {"Estado resultante", "application/json", Schemas.ServerSetting},
      bad_request:
        {"Falta `muted`/`level` o alguno es inválido", "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      not_found:
        {"El usuario no es miembro del servidor", "application/json", Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo guardar la configuración", "application/json", Schemas.ErrorResponse}
    ]

  operation :update_channel,
    summary: "Silencia, reactiva o configura el nivel de notificación de un canal",
    description:
      "Acepta `muted`, `level` o ambos; solo cambia lo que se manda. `level` elige qué avisa el canal: `all`, `mentions` o `none`, y reemplaza al nivel del servidor. `level: null` borra la preferencia y el canal vuelve a heredar. Para fijar algo hay que poder ver el canal; borrar o reactivar no tiene esa condición. Es idempotente y las otras sesiones del usuario se enteran por `snapshot`.",
    parameters: [
      channel_id: [in: :path, description: "Id del canal", type: :string, required: true]
    ],
    request_body: {"Estado deseado", "application/json", Schemas.SettingsRequest, required: true},
    responses: [
      ok: {"Estado resultante", "application/json", Schemas.ChannelSetting},
      bad_request:
        {"Falta `muted`/`level` o alguno es inválido", "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      forbidden: {"El usuario no puede ver el canal", "application/json", Schemas.ErrorResponse},
      not_found: {"El canal no existe", "application/json", Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo guardar la configuración", "application/json", Schemas.ErrorResponse}
    ]

  def index(conn, _params) do
    case Settings.list(conn.assigns.user_id) do
      {:ok, settings} -> json(conn, settings)
      {:error, reason} -> fail(conn, reason)
    end
  end

  def update_server(conn, %{"server_id" => server_id} = params) do
    with {:ok, changes} <- parse_changes(params),
         {:ok, setting} <- Settings.update_server(conn.assigns.user_id, server_id, changes) do
      json(conn, Map.put(setting_json(setting), "server_id", server_id))
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  def update_channel(conn, %{"channel_id" => channel_id} = params) do
    with {:ok, changes} <- parse_changes(params),
         {:ok, setting} <- Settings.update_channel(conn.assigns.user_id, channel_id, changes) do
      json(conn, Map.put(setting_json(setting), "channel_id", channel_id))
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  defp setting_json(%{muted: muted, level: level}), do: %{"muted" => muted, "level" => level}

  defp parse_changes(params) do
    with {:ok, muted} <- parse_muted(params),
         {:ok, level} <- parse_level(params) do
      case Map.merge(muted, level) do
        changes when map_size(changes) == 0 -> {:error, :invalid_payload}
        changes -> {:ok, changes}
      end
    end
  end

  defp parse_muted(%{"muted" => muted}) when is_boolean(muted), do: {:ok, %{muted: muted}}
  defp parse_muted(%{"muted" => _other}), do: {:error, :invalid_payload}
  defp parse_muted(_params), do: {:ok, %{}}

  defp parse_level(%{"level" => nil}), do: {:ok, %{level: nil}}

  defp parse_level(%{"level" => level}) when is_binary(level) do
    if level in Settings.levels(), do: {:ok, %{level: level}}, else: {:error, :invalid_payload}
  end

  defp parse_level(%{"level" => _other}), do: {:error, :invalid_payload}
  defp parse_level(_params), do: {:ok, %{}}

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
