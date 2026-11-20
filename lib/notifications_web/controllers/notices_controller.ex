defmodule NotificationsWeb.NoticesController do
  use Phoenix.Controller, formats: [:json]
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Notifications.{Log, Notices, Realtime}
  alias NotificationsWeb.{ApiError, Schemas}

  tags ["notices"]

  operation :index,
    summary: "Avisos de la plataforma que el usuario todavía no vio",
    description:
      "Hoy hay un solo tipo, `server_deleted`: el staff eliminó un servidor del que el usuario era dueño. Vienen del más viejo al más nuevo. Un aviso deja de aparecer cuando se marca como visto. Si no hay ninguno, `items` viene vacío.",
    responses: [
      ok: {"Avisos sin ver", "application/json", Schemas.NoticeList},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo leer los avisos", "application/json", Schemas.ErrorResponse}
    ]

  operation :seen,
    summary: "Marca un aviso como visto",
    description:
      "Marca como visto, para todos los dispositivos del usuario, el aviso con ese `id`. Solo afecta a los avisos del usuario que consulta; un id que no existe o que ya estaba visto se ignora. Avisa a los demás dispositivos conectados para que vuelvan a pedir los avisos.",
    parameters: [
      id: [
        in: :path,
        schema: %OpenApiSpex.Schema{type: :string, format: :uuid},
        required: true,
        description: "`id` del aviso, como lo devuelve el listado."
      ]
    ],
    responses: [
      no_content: "Marcado como visto",
      bad_request: {"El id no es un UUID", "application/json", Schemas.ErrorResponse},
      unauthorized:
        {"Falta o es inválido el Authorization: Bearer <jwt>", "application/json",
         Schemas.ErrorResponse},
      service_unavailable:
        {"No se pudo guardar que se vio", "application/json", Schemas.ErrorResponse}
    ]

  def index(conn, _params) do
    user_id = conn.assigns.user_id

    case Notices.list_unseen(user_id) do
      {:ok, items} ->
        json(conn, %{items: items})

      {:error, reason} ->
        Logger.error("notices_failed", user_id: user_id, reason: Log.reason(reason))
        unavailable(conn)
    end
  end

  def seen(conn, %{"id" => notice_id}) do
    user_id = conn.assigns.user_id

    case Notices.mark_seen(user_id, notice_id) do
      :ok ->
        Realtime.notices_changed(user_id)
        send_resp(conn, 204, "")

      {:error, :invalid_payload} ->
        conn
        |> put_status(ApiError.http_status(:invalid_payload))
        |> json(ApiError.payload(:invalid_payload))

      {:error, reason} ->
        Logger.error("notices_seen_failed", user_id: user_id, reason: Log.reason(reason))
        unavailable(conn)
    end
  end

  defp unavailable(conn) do
    conn
    |> put_status(ApiError.http_status(:notices_unavailable))
    |> json(ApiError.payload(:notices_unavailable))
  end
end
