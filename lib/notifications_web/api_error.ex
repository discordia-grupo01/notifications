defmodule NotificationsWeb.ApiError do
  @type reason ::
          :forbidden
          | :channel_not_found
          | :server_not_found
          | :invalid_payload
          | :unauthorized
          | :not_found
          | :method_not_allowed
          | :not_acceptable
          | :payload_too_large
          | :unsupported_media_type
          | :internal_error
          | :ticket_unavailable
          | :unread_unavailable
          | :settings_unavailable
          | :history_unavailable
          | :device_limit
          | :push_unavailable
          | :push_not_configured

  @spec describe(reason()) :: {String.t(), String.t()}
  def describe(:forbidden),
    do: {"FORBIDDEN", "No tenés acceso a este canal."}

  def describe(:channel_not_found), do: {"CHANNEL_NOT_FOUND", "El canal no existe."}
  def describe(:server_not_found), do: {"SERVER_NOT_FOUND", "El servidor no existe."}

  def describe(:invalid_payload),
    do: {"INVALID_BODY", "El pedido no tiene el formato esperado."}

  def describe(:unauthorized), do: {"UNAUTHORIZED", "Token inválido o ausente."}
  def describe(:not_found), do: {"NOT_FOUND", "El recurso no existe."}

  def describe(:method_not_allowed),
    do: {"METHOD_NOT_ALLOWED", "El método no está permitido para este recurso."}

  def describe(:not_acceptable),
    do: {"NOT_ACCEPTABLE", "El formato de respuesta pedido no está soportado."}

  def describe(:payload_too_large), do: {"PAYLOAD_TOO_LARGE", "El pedido es demasiado grande."}

  def describe(:unsupported_media_type),
    do: {"UNSUPPORTED_MEDIA_TYPE", "El tipo de contenido no está soportado."}

  def describe(:ticket_unavailable),
    do: {"TICKET_UNAVAILABLE", "No se pudo emitir el ticket, intentá de nuevo."}

  def describe(:unread_unavailable),
    do:
      {"UNREAD_UNAVAILABLE",
       "No se pudo consultar el estado de lectura, intentá de nuevo en un momento."}

  def describe(:settings_unavailable),
    do:
      {"SETTINGS_UNAVAILABLE",
       "No se pudo acceder a la configuración de notificaciones, intentá de nuevo en un momento."}

  def describe(:history_unavailable),
    do:
      {"HISTORY_UNAVAILABLE",
       "No se pudo consultar el historial de notificaciones, intentá de nuevo en un momento."}

  def describe(:device_limit),
    do:
      {"DEVICE_LIMIT",
       "Alcanzaste el máximo de dispositivos con notificaciones push, quitá alguno e intentá de nuevo."}

  def describe(:push_unavailable),
    do:
      {"PUSH_UNAVAILABLE",
       "No se pudo acceder a la configuración de notificaciones push, intentá de nuevo en un momento."}

  def describe(:push_not_configured),
    do: {"PUSH_NOT_CONFIGURED", "Las notificaciones push web no están configuradas."}

  def describe(_other), do: {"INTERNAL_ERROR", "Ocurrió un error inesperado."}

  @spec payload(reason(), map()) :: map()
  def payload(reason, details \\ %{}) do
    {code, message} = describe(reason)
    %{error: %{code: code, message: message, details: details}}
  end

  @spec http_status(reason()) :: 400 | 401 | 403 | 404 | 405 | 406 | 409 | 413 | 415 | 500 | 503
  def http_status(:invalid_payload), do: 400
  def http_status(:unauthorized), do: 401
  def http_status(:forbidden), do: 403
  def http_status(:not_found), do: 404
  def http_status(:method_not_allowed), do: 405
  def http_status(:not_acceptable), do: 406
  def http_status(:payload_too_large), do: 413
  def http_status(:unsupported_media_type), do: 415
  def http_status(:channel_not_found), do: 404
  def http_status(:server_not_found), do: 404
  def http_status(:device_limit), do: 409
  def http_status(:push_unavailable), do: 503
  def http_status(:push_not_configured), do: 404
  def http_status(:settings_unavailable), do: 503
  def http_status(:history_unavailable), do: 503
  def http_status(:ticket_unavailable), do: 503
  def http_status(:unread_unavailable), do: 503
  def http_status(_other), do: 500
end
