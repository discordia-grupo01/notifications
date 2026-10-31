defmodule NotificationsWeb.ApiError do
  @type reason ::
          :forbidden
          | :channel_not_found
          | :server_not_found
          | :invalid_payload
          | :ticket_unavailable
          | :unread_unavailable
          | :settings_unavailable

  @spec describe(reason()) :: {String.t(), String.t()}
  def describe(:forbidden),
    do: {"FORBIDDEN", "No tenés acceso a este canal."}

  def describe(:channel_not_found), do: {"CHANNEL_NOT_FOUND", "El canal no existe."}
  def describe(:server_not_found), do: {"SERVER_NOT_FOUND", "El servidor no existe."}

  def describe(:invalid_payload),
    do: {"INVALID_PAYLOAD", "El pedido no tiene el formato esperado."}

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

  @spec payload(reason(), map()) :: map()
  def payload(reason, details \\ %{}) do
    {code, message} = describe(reason)
    %{error: %{code: code, message: message, details: details}}
  end

  @spec http_status(reason()) :: 400 | 403 | 404 | 503
  def http_status(:forbidden), do: 403
  def http_status(:channel_not_found), do: 404
  def http_status(:server_not_found), do: 404
  def http_status(:settings_unavailable), do: 503
  def http_status(:ticket_unavailable), do: 503
  def http_status(:unread_unavailable), do: 503
  def http_status(_other), do: 400
end
