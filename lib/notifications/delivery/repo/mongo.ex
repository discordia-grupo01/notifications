defmodule Notifications.Delivery.Repo.Mongo do
  @behaviour Notifications.Delivery.Repo

  @conn Notifications.Mongo
  @user_names "replica_user_names"
  @server_names "replica_server_names"
  @presence "replica_presence"
  @push_settings "push_settings"
  @devices "push_devices"
  @deliveries "push_deliveries"

  @impl true
  def ensure_indexes do
    ttl = [[name: "expires_at_ttl", key: [expires_at: 1], expireAfterSeconds: 0]]

    device_indexes = [
      [name: "by_user", key: [user_id: 1]],
      [name: "by_credential", key: [credential_hash: 1], unique: true]
    ]

    with :ok <- Mongo.create_indexes(@conn, @presence, ttl),
         :ok <- Mongo.create_indexes(@conn, @deliveries, ttl) do
      Mongo.create_indexes(@conn, @devices, device_indexes)
    end
  end

  @impl true
  def apply_user_name(user_id, name, version),
    do: write_if_newer(@user_names, user_id, "version", version, %{"name" => name})

  @impl true
  def apply_server_name(server_id, name, %DateTime{} = at),
    do: write_if_newer(@server_names, server_id, "at", at, %{"name" => name})

  @impl true
  def apply_presence(user_id, connections, do_not_disturb, version, %DateTime{} = expires_at) do
    fields = %{
      "connections" => connections,
      "do_not_disturb" => do_not_disturb,
      "expires_at" => expires_at
    }

    write_if_newer(@presence, user_id, "version", version, fields)
  end

  @impl true
  def get_user_names(user_ids), do: names(@user_names, user_ids)

  @impl true
  def get_server_names(server_ids), do: names(@server_names, server_ids)

  @impl true
  def get_presence(user_ids) do
    with {:ok, docs} <- list(@presence, %{"_id" => %{"$in" => user_ids}}) do
      {:ok,
       Map.new(docs, fn doc ->
         {doc["_id"],
          %{
            connections: doc["connections"],
            do_not_disturb: doc["do_not_disturb"] == true,
            expires_at: doc["expires_at"]
          }}
       end)}
    end
  end

  @impl true
  def get_push_enabled(user_id) do
    case Mongo.find_one(@conn, @push_settings, %{"_id" => user_id}) do
      {:error, reason} -> {:error, reason}
      %{"enabled" => false} -> {:ok, false}
      _enabled -> {:ok, true}
    end
  end

  @impl true
  def put_push_enabled(user_id, enabled) do
    case Mongo.update_one(
           @conn,
           @push_settings,
           %{"_id" => user_id},
           %{"$set" => %{"enabled" => enabled}},
           upsert: true
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_push_disabled(user_ids) do
    with {:ok, docs} <- list(@push_settings, %{"_id" => %{"$in" => user_ids}, "enabled" => false}) do
      {:ok, Enum.map(docs, & &1["_id"])}
    end
  end

  @impl true
  def put_device(user_id, attrs, max_devices) do
    case Mongo.find_one(@conn, @devices, %{"credential_hash" => attrs.credential_hash}) do
      {:error, reason} -> {:error, reason}
      nil -> insert_device(user_id, attrs, max_devices)
      existing -> reassign_device(existing, user_id, attrs)
    end
  end

  @impl true
  def delete_device(user_id, device_id) do
    case Mongo.delete_one(@conn, @devices, %{"_id" => device_id, "user_id" => user_id}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_devices(user_ids), do: list(@devices, %{"user_id" => %{"$in" => user_ids}})

  @impl true
  def delete_devices([]), do: :ok

  def delete_devices(device_ids) do
    case Mongo.delete_many(@conn, @devices, %{"_id" => %{"$in" => device_ids}}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def mark_device(device_id, outcome) do
    set =
      case outcome do
        :ok -> %{"last_used_at" => DateTime.utc_now(), "last_error" => nil}
        {:error, reason} -> %{"last_error" => reason}
      end

    case Mongo.update_one(@conn, @devices, %{"_id" => device_id}, %{"$set" => set}) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def claim_delivery(event_id, device_id, %DateTime{} = expires_at) do
    doc = %{"_id" => "#{event_id}:#{device_id}", "expires_at" => expires_at}

    case Mongo.insert_one(@conn, @deliveries, doc) do
      {:ok, _result} -> :claimed
      {:error, error} -> if duplicate_key?(error), do: :duplicate, else: {:error, error}
    end
  end

  defp insert_device(user_id, attrs, max_devices) do
    with {:ok, count} <- count_devices(user_id),
         true <- count < max_devices || {:error, :device_limit} do
      id = new_id()
      now = DateTime.utc_now()

      doc = %{
        "_id" => id,
        "user_id" => user_id,
        "provider" => attrs.provider,
        "platform" => attrs.platform,
        "credential" => attrs.credential,
        "credential_hash" => attrs.credential_hash,
        "created_at" => now,
        "last_used_at" => nil,
        "last_error" => nil
      }

      case Mongo.insert_one(@conn, @devices, doc) do
        {:ok, _result} -> {:ok, %{id: id, created: true}}
        {:error, error} -> insert_failed(error, user_id, attrs)
      end
    end
  end

  defp insert_failed(error, user_id, attrs) do
    if duplicate_key?(error) do
      case Mongo.find_one(@conn, @devices, %{"credential_hash" => attrs.credential_hash}) do
        %{} = existing -> reassign_device(existing, user_id, attrs)
        _other -> {:error, error}
      end
    else
      {:error, error}
    end
  end

  defp reassign_device(existing, user_id, attrs) do
    set = %{
      "user_id" => user_id,
      "provider" => attrs.provider,
      "platform" => attrs.platform,
      "credential" => attrs.credential,
      "last_error" => nil
    }

    case Mongo.update_one(@conn, @devices, %{"_id" => existing["_id"]}, %{"$set" => set}) do
      {:ok, _result} -> {:ok, %{id: existing["_id"], created: false}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp count_devices(user_id) do
    case Mongo.count_documents(@conn, @devices, %{"user_id" => user_id}) do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp names(_collection, []), do: {:ok, %{}}

  defp names(collection, ids) do
    with {:ok, docs} <- list(collection, %{"_id" => %{"$in" => ids}}) do
      {:ok, Map.new(docs, &{&1["_id"], &1["name"]})}
    end
  end

  defp write_if_newer(collection, id, field, value, fields) do
    filter = %{"_id" => id, field => %{"$lte" => value}}
    update = %{"$set" => Map.put(fields, field, value)}

    case Mongo.update_one(@conn, collection, filter, update, upsert: true) do
      {:ok, _result} -> {:ok, :applied}
      {:error, error} -> if duplicate_key?(error), do: {:ok, :stale}, else: {:error, error}
    end
  end

  defp list(_collection, %{"_id" => %{"$in" => []}}), do: {:ok, []}
  defp list(_collection, %{"user_id" => %{"$in" => []}}), do: {:ok, []}

  defp list(collection, filter) do
    case Mongo.find(@conn, collection, filter) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  defp new_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp duplicate_key?(%Mongo.WriteError{write_errors: [%{"code" => 11_000} | _]}), do: true
  defp duplicate_key?(%{code: 11_000}), do: true
  defp duplicate_key?(_other), do: false
end
