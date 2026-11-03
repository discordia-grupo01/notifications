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
        type: :integer,
        required: false,
        description: "Cantidad de entradas, de 1 a 100. Por defecto 50."
      ],
      before: [
        in: :query,
        type: :string,
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
