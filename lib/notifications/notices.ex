defmodule Notifications.Notices do
  @moduledoc """
  Avisos de la plataforma que el usuario tiene que ver una vez, aunque haya
  estado desconectado cuando pasaron. Hoy hay uno solo: el staff eliminó un
  servidor del que era dueño (`admin.server_deletion_notice`).
  """

  alias Notifications.Events.Event
  alias Notifications.Notices.Repo
  alias Notifications.UUID

  @type item :: %{
          id: String.t(),
          kind: String.t(),
          server_id: String.t(),
          server_name: String.t(),
          occurred_at: String.t()
        }

  # El id por dueño y servidor hace que un pedido de borrado repetido no vuelva
  # a mostrar un aviso que el dueño ya vio.
  @spec record(struct()) :: :ok | {:error, term()}
  def record(%Event.ServerDeletionNotice{} = event) do
    doc = %{
      "_id" => event.owner_id <> ":" <> event.server_id,
      "notice_id" => event.event_id,
      "user_id" => event.owner_id,
      "kind" => "server_deleted",
      "server_id" => event.server_id,
      "server_name" => event.server_name,
      "occurred_at" => event.occurred_at,
      "seen_at" => nil
    }

    case Repo.impl().insert_if_absent(doc) do
      {:ok, _inserted_or_exists} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec list_unseen(String.t()) :: {:ok, [item()]} | {:error, term()}
  def list_unseen(user_id) do
    with {:ok, docs} <- Repo.impl().list_unseen(user_id) do
      {:ok, Enum.map(docs, &item/1)}
    end
  end

  @spec mark_seen(String.t(), String.t()) :: :ok | {:error, term()}
  def mark_seen(user_id, notice_id) do
    if UUID.valid?(notice_id),
      do: Repo.impl().mark_seen(user_id, notice_id, DateTime.utc_now()),
      else: {:error, :invalid_payload}
  end

  defp item(doc) do
    %{
      id: doc["notice_id"],
      kind: doc["kind"],
      server_id: doc["server_id"],
      server_name: doc["server_name"],
      occurred_at: iso8601(doc["occurred_at"])
    }
  end

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(at) when is_binary(at), do: at
end
