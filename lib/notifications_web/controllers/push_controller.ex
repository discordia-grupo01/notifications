defmodule NotificationsWeb.PushController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Notifications.Log
  alias Notifications.Delivery.Devices
  alias NotificationsWeb.{ApiError, Schemas}

  tags ["push"]

  @client_errors [:invalid_payload, :device_limit, :push_not_configured]

  operation :show_settings,
    summary: "Dice si el usuario recibe notificaciones push",
    description:
      "Es un interruptor único por usuario, válido para todos sus dispositivos. Por defecto está activado.",
    responses: [
      ok: {"Estado del interruptor", "application/json", Schemas.PushSettings},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo leer la configuración", "application/json", Schemas.ErrorResponse}
    ]

  operation :update_settings,
    summary: "Activa o desactiva las notificaciones push del usuario",
    description:
      "Con `enabled: false` no se manda ningún push a ningún dispositivo del usuario. No cambia los indicadores ni el historial dentro de la app. Es idempotente.",
    request_body:
      {"Estado deseado", "application/json", Schemas.PushSettingsRequest, required: true},
    responses: [
      ok: {"Estado resultante", "application/json", Schemas.PushSettings},
      bad_request:
        {"`enabled` falta o no es booleano", "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo guardar la configuración", "application/json", Schemas.ErrorResponse}
    ]

  operation :register_device,
    summary: "Registra un dispositivo para recibir notificaciones push",
    description:
      "Se llama después de que el usuario da el permiso de notificaciones. El token o la suscripción viajan solo en el cuerpo. Es idempotente: registrar de nuevo el mismo dispositivo devuelve el mismo `id` (200) y, si estaba asociado a otro usuario, pasa a este. El máximo es de 10 dispositivos por usuario.",
    request_body: {"Dispositivo", "application/json", Schemas.PushDeviceRequest, required: true},
    responses: [
      created: {"Dispositivo registrado", "application/json", Schemas.PushDevice},
      ok: {"El dispositivo ya estaba registrado", "application/json", Schemas.PushDevice},
      bad_request:
        {"Proveedor, plataforma o credenciales inválidos", "application/json",
         Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      conflict:
        {"Se alcanzó el máximo de dispositivos", "application/json", Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo guardar el dispositivo", "application/json", Schemas.ErrorResponse}
    ]

  operation :delete_device,
    summary: "Quita un dispositivo de las notificaciones push",
    description:
      "Se llama al cerrar sesión o al desactivar el permiso. Es idempotente: si el `id` no existe o es de otro usuario responde igual.",
    parameters: [
      id: [in: :path, description: "Id devuelto al registrar el dispositivo", type: :string]
    ],
    responses: [
      no_content: "Dispositivo quitado",
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo quitar el dispositivo", "application/json", Schemas.ErrorResponse}
    ]

  operation :vapid_public_key,
    summary: "Clave pública VAPID para suscribir un navegador",
    responses: [
      ok: {"Clave pública", "application/json", Schemas.VapidPublicKey},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      not_found: {"El push web no está configurado", "application/json", Schemas.ErrorResponse}
    ]

  def show_settings(conn, _params) do
    case Devices.enabled?(conn.assigns.user_id) do
      {:ok, enabled} -> json(conn, %{enabled: enabled})
      {:error, reason} -> fail(conn, reason)
    end
  end

  def update_settings(conn, %{"enabled" => enabled}) when is_boolean(enabled) do
    case Devices.set_enabled(conn.assigns.user_id, enabled) do
      {:ok, enabled} -> json(conn, %{enabled: enabled})
      {:error, reason} -> fail(conn, reason)
    end
  end

  def update_settings(conn, _params), do: fail(conn, :invalid_payload)

  def register_device(conn, params) do
    case Devices.register(conn.assigns.user_id, params) do
      {:ok, %{id: id, created: true}} -> conn |> put_status(201) |> json(%{id: id})
      {:ok, %{id: id, created: false}} -> json(conn, %{id: id})
      {:error, reason} -> fail(conn, reason)
    end
  end

  def delete_device(conn, %{"id" => id}) do
    case Devices.unregister(conn.assigns.user_id, id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> fail(conn, reason)
    end
  end

  def vapid_public_key(conn, _params) do
    case Devices.vapid_public_key() do
      {:ok, key} -> json(conn, %{public_key: key})
      {:error, reason} -> fail(conn, reason)
    end
  end

  defp fail(conn, reason) when reason in @client_errors do
    conn
    |> put_status(ApiError.http_status(reason))
    |> json(ApiError.payload(reason))
  end

  defp fail(conn, reason) do
    Logger.error("push_request_failed", user_id: conn.assigns.user_id, reason: Log.reason(reason))

    conn
    |> put_status(ApiError.http_status(:push_unavailable))
    |> json(ApiError.payload(:push_unavailable))
  end
end
