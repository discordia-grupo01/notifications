defmodule Notifications.Notices.Repo.Mongo do
  @behaviour Notifications.Notices.Repo

  @conn Notifications.Mongo
  @notices "staff_notices"

  @impl true
  def ensure_indexes do
    Mongo.create_indexes(@conn, @notices, [
      [name: "by_user_unseen", key: [user_id: 1, seen_at: 1, occurred_at: 1]]
    ])
  end

  @impl true
  def insert_if_absent(%{"_id" => id} = doc) do
    case Mongo.update_one(@conn, @notices, %{"_id" => id}, %{"$setOnInsert" => doc}, upsert: true) do
      {:ok, %{matched_count: 0}} -> {:ok, :inserted}
      {:ok, _result} -> {:ok, :exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_unseen(user_id) do
    filter = %{"user_id" => user_id, "seen_at" => nil}

    case Mongo.find(@conn, @notices, filter, sort: %{"occurred_at" => 1}) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  end

  @impl true
  def mark_seen(user_id, notice_id, %DateTime{} = at) do
    filter = %{"user_id" => user_id, "notice_id" => notice_id, "seen_at" => nil}

    case Mongo.update_many(@conn, @notices, filter, %{"$set" => %{"seen_at" => at}}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
