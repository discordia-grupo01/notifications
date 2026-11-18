defmodule NotificationsWeb.Plugs.Authenticate do
  import Plug.Conn

  alias Notifications.Auth.Token
  alias NotificationsWeb.ApiError

  def init(opts), do: opts

  def call(conn, _opts) do
    with [header] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- header,
         {:ok, user_id} <- Token.user_id(token) do
      assign(conn, :user_id, user_id)
    else
      _other ->
        conn
        |> put_status(ApiError.http_status(:unauthorized))
        |> Phoenix.Controller.json(ApiError.payload(:unauthorized))
        |> halt()
    end
  end
end
