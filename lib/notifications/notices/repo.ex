defmodule Notifications.Notices.Repo do
  @type result :: :ok | {:error, term()}

  @callback ensure_indexes() :: result()

  @doc "Guarda el aviso solo si no hay uno con el mismo `_id`."
  @callback insert_if_absent(doc :: map()) :: {:ok, :inserted | :exists} | {:error, term()}

  @callback list_unseen(user_id :: String.t()) :: {:ok, [map()]} | {:error, term()}

  @callback mark_seen(user_id :: String.t(), notice_id :: String.t(), at :: DateTime.t()) ::
              result()

  @spec impl() :: module()
  def impl,
    do: Application.get_env(:notifications, :notices_repo, Notifications.Notices.Repo.Mongo)
end
