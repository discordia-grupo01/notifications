defmodule NotificationsWeb.HistoryController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Notifications.{History, Log}
  alias NotificationsWeb.{ApiError, Schemas}

  @max_limit History.max_limit()

  tags ["history"]

  operation :index,
    summary: "Historial de notificaciones del usuario",
    description:
      "Menciones y mensajes directos recientes, ordenados por fecha, del más nuevo al más viejo, con los ids para ir directo a cada conversación. Solo incluye lo que avisó según las preferencias del momento (un canal silenciado o en `none` no deja entradas) y se conserva para siempre, salvo que `HISTORY_RETENTION_DAYS` fije un plazo en días. Las menciones de canales que el usuario ya no puede ver no se listan. Si no hay nada, `items` viene vacío.",
    parameters: [
      limit: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: @max_limit},
        required: false,
        description: "Cantidad de entradas, de 1 a 100. Por defecto 50."
      ],
      before: [
        in: :query,
        schema: %OpenApiSpex.Schema{
          type: :string,
          pattern: "^[0-9]{1,13}_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
        },
        required: false,
        description:
          "`next_cursor` de la página anterior (texto opaco, se reenvía tal cual): trae las entradas más viejas."
      ]
    ],
    responses: [
      ok: {"Página del historial", "application/json", Schemas.HistoryPage},
      bad_request: {"`limit` o `before` inválido", "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo leer el historial", "application/json", Schemas.ErrorResponse}
    ]

  operation :read_transfers,
    summary: "Marca como leídas las notificaciones de transferencia de propiedad",
    description:
      "Marca como leídas, para todos los dispositivos del usuario, las notificaciones de `ownership_transfer` con esos ids de transferencia. Solo afecta a las entradas del usuario que consulta; un id que no tiene entrada se ignora. Es idempotente. Avisa a los demás dispositivos conectados para que vuelvan a pedir el historial.",
    request_body:
      {"Ids de las transferencias", "application/json", Schemas.MarkTransfersReadRequest,
       required: true},
    responses: [
      no_content: "Marcadas como leídas",
      bad_request:
        {"`transfer_ids` falta, está vacío, tiene más de 100 ids o algún id no es un UUID",
         "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo guardar el estado de lectura", "application/json", Schemas.ErrorResponse}
    ]

  def index(conn, params) do
    user_id = conn.assigns.user_id

    with {:ok, limit} <- parse_limit(params),
         {:ok, before} <- parse_before(params),
         {:ok, page} <- History.list(user_id, limit: limit, before: before) do
      json(conn, page)
    else
      {:error, :invalid_payload} ->
        conn
        |> put_status(ApiError.http_status(:invalid_payload))
        |> json(ApiError.payload(:invalid_payload))

      {:error, reason} ->
        Logger.error("history_failed", user_id: user_id, reason: Log.reason(reason))

        conn
        |> put_status(ApiError.http_status(:history_unavailable))
        |> json(ApiError.payload(:history_unavailable))
    end
  end

  def read_transfers(conn, %{"transfer_ids" => transfer_ids}) do
    user_id = conn.assigns.user_id

    case History.mark_transfers_read(user_id, transfer_ids) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, :invalid_payload} ->
        conn
        |> put_status(ApiError.http_status(:invalid_payload))
        |> json(ApiError.payload(:invalid_payload))

      {:error, reason} ->
        Logger.error("history_read_failed", user_id: user_id, reason: Log.reason(reason))

        conn
        |> put_status(ApiError.http_status(:history_unavailable))
        |> json(ApiError.payload(:history_unavailable))
    end
  end

  def read_transfers(conn, _params) do
    conn
    |> put_status(ApiError.http_status(:invalid_payload))
    |> json(ApiError.payload(:invalid_payload))
  end

  defp parse_limit(%{"limit" => raw}) when is_binary(raw) do
    case Integer.parse(raw) do
      {limit, ""} when limit >= 1 and limit <= @max_limit -> {:ok, limit}
      _invalid -> {:error, :invalid_payload}
    end
  end

  defp parse_limit(%{"limit" => _other}), do: {:error, :invalid_payload}
  defp parse_limit(_params), do: {:ok, History.default_limit()}

  defp parse_before(%{"before" => before}) do
    case History.decode_cursor(before) do
      {:ok, position} -> {:ok, position}
      :error -> {:error, :invalid_payload}
    end
  end

  defp parse_before(_params), do: {:ok, nil}
end
