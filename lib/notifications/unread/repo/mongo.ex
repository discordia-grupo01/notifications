defmodule Notifications.Unread.Repo.Mongo do
  @behaviour Notifications.Unread.Repo

  @conn Notifications.Mongo
  @channels "channels"
  @clocks "event_clocks"
  @activity "channel_activity"
  @read_markers "read_markers"
  @unread_mentions "unread_mentions"
  @settings "notification_settings"
  @history "notification_history"
  @replica_servers "replica_servers"
  @replica_roles "replica_roles"
  @replica_members "replica_members"
  @replica_overrides "replica_overrides"
  @tombstone_ttl_seconds 7 * 24 * 60 * 60
  @recent_positions 50
  @epoch ~U[1970-01-01 00:00:00Z]

  @impl true
  def ping do
    case Mongo.ping(@conn) do
      {:ok, _doc} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def ensure_indexes do
    replica_ttl = [[name: "replica_expires_at_ttl", key: [expires_at: 1], expireAfterSeconds: 0]]
    by_server = [[name: "by_server", key: [server_id: 1]]]
    by_user = [[name: "by_user_channel", key: [user_id: 1, channel_id: 1]]]
    by_user_server = [[name: "by_user_server", key: [user_id: 1, server_id: 1]]]

    settings_indexes = [
      [name: "by_user", key: [user_id: 1]],
      [name: "by_server", key: [server_id: 1]],
      [name: "by_scope", key: [scope_id: 1]]
    ]

    clock_ttl = [
      [name: "event_clocks_expires_at_ttl", key: [expires_at: 1], expireAfterSeconds: 0]
    ]

    history_indexes = [
      [name: "by_user_timeline", key: [user_id: 1, occurred_at: -1, message_id: -1]],
      [name: "by_message", key: [message_id: 1]],
      [name: "history_expires_at_ttl", key: [expires_at: 1], expireAfterSeconds: 0],
      [name: "by_channel", key: [channel_id: 1]],
      [name: "by_server", key: [server_id: 1]]
    ]

    with :ok <- Mongo.create_indexes(@conn, @channels, by_server),
         :ok <- Mongo.create_indexes(@conn, @activity, by_server),
         :ok <- Mongo.create_indexes(@conn, @read_markers, by_user ++ by_user_server),
         :ok <- Mongo.create_indexes(@conn, @unread_mentions, by_user ++ by_user_server),
         :ok <- Mongo.create_indexes(@conn, @replica_roles, replica_ttl ++ by_server),
         :ok <-
           Mongo.create_indexes(
             @conn,
             @replica_members,
             replica_ttl ++ by_server ++ [[name: "by_user", key: [user_id: 1]]]
           ),
         :ok <- Mongo.create_indexes(@conn, @settings, settings_indexes),
         :ok <- Mongo.create_indexes(@conn, @history, history_indexes),
         :ok <- Mongo.create_indexes(@conn, @replica_overrides, by_server) do
      Mongo.create_indexes(@conn, @clocks, clock_ttl)
    end
  end

  @impl true
  def apply_clock(key, state, %DateTime{} = at, expires_at) do
    set = %{"state" => state, "at" => at}
    set = if expires_at, do: Map.put(set, "expires_at", expires_at), else: set
    filter = %{"_id" => key, "at" => %{"$lte" => at}}

    case Mongo.update_one(@conn, @clocks, filter, %{"$set" => set}, upsert: true) do
      {:ok, _result} -> {:ok, :applied}
      {:error, error} -> if duplicate_key?(error), do: {:ok, :stale}, else: {:error, error}
    end
  end

  @impl true
  def get_clock(key), do: Mongo.find_one(@conn, @clocks, %{"_id" => key})

  @impl true
  def upsert_channel(%{"_id" => id} = doc) do
    case Mongo.update_one(@conn, @channels, %{"_id" => id}, %{"$set" => doc}, upsert: true) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_channel(channel_id), do: Mongo.find_one(@conn, @channels, %{"_id" => channel_id})

  @impl true
  def list_channel_ids(server_id) do
    {:ok, cached_channel_ids(server_id)}
  rescue
    error -> {:error, error}
  end

  @impl true
  def delete_channel(channel_id) do
    with {:ok, _result} <- Mongo.delete_one(@conn, @activity, %{"_id" => channel_id}),
         {:ok, _result} <- Mongo.delete_many(@conn, @read_markers, %{"channel_id" => channel_id}),
         {:ok, _result} <-
           Mongo.delete_many(@conn, @unread_mentions, %{"channel_id" => channel_id}),
         {:ok, _result} <- Mongo.delete_many(@conn, @settings, %{"scope_id" => channel_id}),
         {:ok, _result} <- Mongo.delete_many(@conn, @history, %{"channel_id" => channel_id}),
         {:ok, _result} <- Mongo.delete_one(@conn, @replica_overrides, %{"_id" => channel_id}),
         {:ok, _result} <- Mongo.delete_one(@conn, @channels, %{"_id" => channel_id}) do
      :ok
    end
  end

  @impl true
  def delete_server_data(server_id, channel_ids) do
    all_ids = Enum.uniq(channel_ids ++ cached_channel_ids(server_id))
    by_server = %{"server_id" => server_id}
    by_channels = %{"channel_id" => %{"$in" => all_ids}}

    with {:ok, _result} <-
           Mongo.delete_many(@conn, @activity, %{"_id" => %{"$in" => all_ids}}),
         {:ok, _result} <- Mongo.delete_many(@conn, @read_markers, by_channels),
         {:ok, _result} <- Mongo.delete_many(@conn, @unread_mentions, by_channels),
         {:ok, _result} <- Mongo.delete_many(@conn, @read_markers, by_server),
         {:ok, _result} <- Mongo.delete_many(@conn, @unread_mentions, by_server),
         {:ok, _result} <- Mongo.delete_many(@conn, @settings, by_server),
         {:ok, _result} <- Mongo.delete_many(@conn, @history, by_server),
         {:ok, _result} <- Mongo.delete_many(@conn, @replica_overrides, by_server),
         {:ok, _result} <- Mongo.delete_many(@conn, @replica_members, by_server),
         {:ok, _result} <- Mongo.delete_many(@conn, @replica_roles, by_server),
         {:ok, _result} <- Mongo.delete_many(@conn, @channels, by_server),
         {:ok, _result} <- Mongo.delete_one(@conn, @replica_servers, %{"_id" => server_id}) do
      :ok
    end
  end

  @impl true
  def apply_server_owner(server_id, owner_id, %DateTime{} = at),
    do: apply_snapshot(@replica_servers, server_id, %{"owner_id" => owner_id}, at)

  @impl true
  def apply_role(server_id, role_id, permissions, is_everyone, %DateTime{} = at) do
    fields = %{
      "server_id" => server_id,
      "permissions" => permissions,
      "is_everyone" => is_everyone
    }

    apply_snapshot(@replica_roles, role_id, fields, at)
  end

  @impl true
  def delete_role(server_id, role_id, %DateTime{} = at) do
    with {:ok, :applied} <-
           apply_tombstone(@replica_roles, role_id, %{"server_id" => server_id}, at),
         {:ok, _result} <-
           Mongo.update_many(
             @conn,
             @replica_members,
             %{"server_id" => server_id},
             %{"$pull" => %{"role_ids" => role_id}}
           ),
         {:ok, _result} <-
           Mongo.update_many(
             @conn,
             @replica_overrides,
             %{"server_id" => server_id},
             %{"$pull" => %{"overrides" => %{"role_id" => role_id}}}
           ) do
      {:ok, :applied}
    end
  end

  @impl true
  def apply_member_roles(server_id, user_id, role_ids, %DateTime{} = at) do
    fields = %{"server_id" => server_id, "user_id" => user_id, "role_ids" => role_ids}

    update = %{
      "$set" => Map.merge(fields, %{"at" => at, "deleted" => false}),
      "$unset" => %{"expires_at" => ""},
      "$setOnInsert" => %{"inserted_at" => DateTime.utc_now()}
    }

    write_if_newer(@replica_members, member_key(server_id, user_id), at, update)
  end

  @impl true
  def delete_member(server_id, user_id, %DateTime{} = at) do
    fields = %{"server_id" => server_id, "user_id" => user_id, "role_ids" => []}

    with {:ok, :applied} <-
           apply_tombstone(@replica_members, member_key(server_id, user_id), fields, at),
         {:ok, _result} <-
           Mongo.delete_many(@conn, @read_markers, %{
             "user_id" => user_id,
             "server_id" => server_id
           }),
         {:ok, _result} <-
           Mongo.delete_many(@conn, @unread_mentions, %{
             "user_id" => user_id,
             "server_id" => server_id
           }),
         {:ok, _result} <-
           Mongo.delete_many(@conn, @settings, %{"user_id" => user_id, "server_id" => server_id}),
         {:ok, _result} <-
           Mongo.delete_many(@conn, @history, %{"user_id" => user_id, "server_id" => server_id}) do
      {:ok, :applied}
    end
  end

  @impl true
  def apply_channel_overrides(server_id, channel_id, overrides, %DateTime{} = at) do
    fields = %{
      "server_id" => server_id,
      "overrides" =>
        Enum.map(overrides, fn o ->
          %{"role_id" => o.role_id, "allow" => o.allow, "deny" => o.deny}
        end)
    }

    apply_snapshot(@replica_overrides, channel_id, fields, at)
  end

  @impl true
  def record_member_joined(server_id, user_id, %DateTime{} = at) do
    update = %{
      "$max" => %{"joined_at" => at},
      "$setOnInsert" => %{
        "server_id" => server_id,
        "user_id" => user_id,
        "role_ids" => [],
        "deleted" => false,
        "at" => @epoch,
        "inserted_at" => DateTime.utc_now()
      }
    }

    key = member_key(server_id, user_id)

    with :ok <- upsert(@replica_members, key, update) do
      revive_member(key)
    end
  end

  @impl true
  def list_memberships(user_id),
    do: list(@replica_members, %{"user_id" => user_id, "deleted" => %{"$ne" => true}})

  @impl true
  def get_server_owners(server_ids) do
    with {:ok, docs} <- list(@replica_servers, %{"_id" => %{"$in" => server_ids}}) do
      {:ok, Map.new(docs, fn doc -> {doc["_id"], doc["owner_id"]} end)}
    end
  end

  @impl true
  def list_roles(server_ids),
    do:
      list(@replica_roles, %{"server_id" => %{"$in" => server_ids}, "deleted" => %{"$ne" => true}})

  @impl true
  def list_channels(server_ids), do: list(@channels, %{"server_id" => %{"$in" => server_ids}})

  @impl true
  def list_overrides(server_ids),
    do: list(@replica_overrides, %{"server_id" => %{"$in" => server_ids}})

  @impl true
  def record_message(%{
        channel_id: channel_id,
        server_id: server_id,
        message_id: message_id,
        author_id: author_id,
        mentioned_user_ids: mentioned_user_ids,
        position: position
      }) do
    with :ok <- ensure_channel(channel_id, server_id),
         :ok <- record_activity(channel_id, server_id, message_id, position),
         :ok <- mark_read(author_id, channel_id, server_id, position) do
      record_mentions(mentioned_user_ids, channel_id, server_id, message_id, position)
    end
  end

  @impl true
  def get_activity(channel_ids) do
    with {:ok, docs} <- list(@activity, %{"_id" => %{"$in" => channel_ids}}) do
      {:ok,
       for doc <- docs, is_binary(doc["last_position"]), into: %{} do
         {doc["_id"], doc["last_position"]}
       end}
    end
  end

  @impl true
  def find_position(channel_id, message_id) do
    filter = %{"_id" => channel_id, "recent.message_id" => message_id}

    case Mongo.find_one(@conn, @activity, filter, projection: %{"recent.$" => 1}) do
      %{"recent" => [%{"position" => position} | _rest]} -> {:ok, position}
      {:error, reason} -> {:error, reason}
      _none -> {:ok, nil}
    end
  end

  @impl true
  def get_read_markers(_user_id, []), do: {:ok, %{}}

  def get_read_markers(user_id, channel_ids) do
    with {:ok, docs} <- list(@read_markers, by_user_channels(user_id, channel_ids)) do
      {:ok,
       for doc <- docs, is_binary(doc["last_read_position"]), into: %{} do
         {doc["channel_id"], doc["last_read_position"]}
       end}
    end
  end

  @impl true
  def get_unread_mentions(_user_id, []), do: {:ok, %{}}

  def get_unread_mentions(user_id, channel_ids) do
    with {:ok, docs} <- list(@unread_mentions, by_user_channels(user_id, channel_ids)) do
      {:ok, docs |> Enum.group_by(& &1["channel_id"], & &1["position"])}
    end
  end

  @impl true
  def mark_all_read(_user_id, []), do: :ok

  def mark_all_read(user_id, entries) do
    operations =
      Enum.map(entries, fn %{channel_id: channel_id, server_id: server_id, position: position} ->
        {marker_key(user_id, channel_id), read_update(user_id, channel_id, server_id, position)}
      end)

    read_mentions =
      Enum.map(entries, fn %{channel_id: channel_id, position: position} ->
        %{"channel_id" => channel_id, "position" => %{"$lte" => position}}
      end)

    with :ok <- upsert_many(@read_markers, operations) do
      delete_many(@unread_mentions, %{"user_id" => user_id, "$or" => read_mentions})
    end
  end

  @impl true
  def mark_read(user_id, channel_id, server_id, position) do
    with :ok <-
           upsert(
             @read_markers,
             marker_key(user_id, channel_id),
             read_update(user_id, channel_id, server_id, position)
           ) do
      delete_many(@unread_mentions, %{
        "user_id" => user_id,
        "channel_id" => channel_id,
        "position" => %{"$lte" => position}
      })
    end
  end

  defp read_update(user_id, channel_id, server_id, position) do
    %{
      "$max" => %{"last_read_position" => position},
      "$set" => %{"user_id" => user_id, "channel_id" => channel_id, "server_id" => server_id}
    }
  end

  # `recent` keeps the position of the last messages so that `mark_read` can read
  # up to exactly the message the client shows. A replayed event matches no
  # document, the upsert tries to insert a second one and Mongo reports a duplicate.
  defp record_activity(channel_id, server_id, message_id, position) do
    filter = %{"_id" => channel_id, "recent.message_id" => %{"$ne" => message_id}}

    update = %{
      "$max" => %{"last_position" => position},
      "$set" => %{"server_id" => server_id},
      "$push" => %{
        "recent" => %{
          "$each" => [%{"message_id" => message_id, "position" => position}],
          "$sort" => %{"position" => 1},
          "$slice" => -@recent_positions
        }
      }
    }

    case Mongo.update_one(@conn, @activity, filter, update, upsert: true) do
      {:ok, _result} -> :ok
      {:error, error} -> if duplicate_key?(error), do: :ok, else: {:error, error}
    end
  end

  @impl true
  def list_settings(user_id), do: list(@settings, %{"user_id" => user_id})

  @impl true
  def get_setting(user_id, scope_id),
    do: Mongo.find_one(@conn, @settings, %{"_id" => setting_key(user_id, scope_id)})

  @impl true
  def put_setting(user_id, scope, scope_id, server_id, changes) do
    key = setting_key(user_id, scope_id)
    fields = Map.new(changes, fn {field, value} -> {Atom.to_string(field), value} end)

    identity = %{
      "user_id" => user_id,
      "scope" => Atom.to_string(scope),
      "scope_id" => scope_id,
      "server_id" => server_id
    }

    defaults = Map.drop(%{"muted" => false, "level" => nil}, Map.keys(fields))
    update = %{"$set" => fields, "$setOnInsert" => Map.merge(identity, defaults)}

    with :ok <- upsert(@settings, key, update),
         {:ok, _result} <-
           Mongo.delete_one(@conn, @settings, %{
             "_id" => key,
             "muted" => %{"$ne" => true},
             "level" => nil
           }) do
      :ok
    end
  end

  @impl true
  def list_settings_for(user_ids, scope_ids),
    do:
      list(@settings, %{
        "user_id" => %{"$in" => user_ids},
        "scope_id" => %{"$in" => scope_ids}
      })

  @impl true
  def list_settings_by_scope(scope_ids),
    do: list(@settings, %{"scope_id" => %{"$in" => scope_ids}})

  @impl true
  def list_history_mention_users(message_id) do
    with {:ok, docs} <- list(@history, %{"message_id" => message_id, "kind" => "mention"}) do
      {:ok, Enum.map(docs, & &1["user_id"])}
    end
  end

  @impl true
  def delete_history_entries(_message_id, []), do: :ok

  def delete_history_entries(message_id, user_ids) do
    filter = %{"message_id" => message_id}

    filter =
      if user_ids == :all, do: filter, else: Map.put(filter, "user_id", %{"$in" => user_ids})

    case Mongo.delete_many(@conn, @history, filter) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put_history(items) do
    operations =
      Enum.map(items, fn %{"_id" => id} = item ->
        {id, %{"$setOnInsert" => Map.delete(item, "_id")}}
      end)

    upsert_many(@history, operations)
  end

  @impl true
  def upsert_history(items) do
    operations =
      Enum.map(items, fn %{"_id" => id} = item ->
        {id, %{"$set" => Map.delete(item, "_id")}}
      end)

    upsert_many(@history, operations)
  end

  @impl true
  def list_history(user_id, before, limit) do
    sort = [occurred_at: -1, message_id: -1]

    case Mongo.find(@conn, @history, history_filter(user_id, before), sort: sort, limit: limit) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  defp history_filter(user_id, nil), do: %{"user_id" => user_id}

  defp history_filter(user_id, {at, message_id}) do
    %{
      "user_id" => user_id,
      "$or" => [
        %{"occurred_at" => %{"$lt" => at}},
        %{"occurred_at" => at, "message_id" => %{"$lt" => message_id}}
      ]
    }
  end

  defp ensure_channel(channel_id, server_id) do
    update = %{"$setOnInsert" => %{"server_id" => server_id, "kind" => "text"}}

    case Mongo.update_one(@conn, @channels, %{"_id" => channel_id}, update, upsert: true) do
      {:ok, _result} -> :ok
      {:error, error} -> if duplicate_key?(error), do: :ok, else: {:error, error}
    end
  end

  defp revive_member(key) do
    revive = %{
      "$set" => %{"deleted" => false, "role_ids" => []},
      "$unset" => %{"expires_at" => ""}
    }

    case Mongo.update_one(@conn, @replica_members, %{"_id" => key, "deleted" => true}, revive) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_mentions([], _channel_id, _server_id, _message_id, _position), do: :ok

  defp record_mentions(user_ids, channel_id, server_id, message_id, position) do
    operations =
      Enum.map(user_ids, fn user_id ->
        {"#{user_id}:#{message_id}",
         %{
           "$setOnInsert" => %{
             "user_id" => user_id,
             "channel_id" => channel_id,
             "server_id" => server_id,
             "message_id" => message_id,
             "position" => position
           }
         }}
      end)

    upsert_many(@unread_mentions, operations)
  end

  defp upsert_many(_collection, []), do: :ok

  defp upsert_many(collection, operations) do
    bulk =
      Enum.reduce(operations, Mongo.UnorderedBulk.new(collection), fn {id, update}, bulk ->
        Mongo.UnorderedBulk.update_one(bulk, %{"_id" => id}, update, upsert: true)
      end)

    case Mongo.BulkWrite.write(@conn, bulk) do
      %Mongo.BulkWriteResult{errors: []} -> :ok
      %Mongo.BulkWriteResult{errors: errors} -> {:error, {:bulk_write, errors}}
    end
  end

  defp by_user_channels(user_id, channel_ids),
    do: %{"user_id" => user_id, "channel_id" => %{"$in" => channel_ids}}

  defp delete_many(collection, filter) do
    case Mongo.delete_many(@conn, collection, filter) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp list(_collection, %{"_id" => %{"$in" => []}}), do: {:ok, []}
  defp list(_collection, %{"server_id" => %{"$in" => []}}), do: {:ok, []}

  defp list(collection, filter) do
    case Mongo.find(@conn, collection, filter) do
      {:error, reason} -> {:error, reason}
      cursor -> {:ok, Enum.to_list(cursor)}
    end
  rescue
    error -> {:error, error}
  end

  defp upsert(collection, id, update) do
    case Mongo.update_one(@conn, collection, %{"_id" => id}, update, upsert: true) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp member_key(server_id, user_id), do: "#{server_id}:#{user_id}"
  defp marker_key(user_id, channel_id), do: "#{user_id}:#{channel_id}"
  defp setting_key(user_id, scope_id), do: "#{user_id}:#{scope_id}"

  defp cached_channel_ids(server_id) do
    @conn
    |> Mongo.find(@channels, %{"server_id" => server_id}, projection: %{"_id" => 1})
    |> Enum.map(& &1["_id"])
  end

  defp apply_snapshot(collection, id, fields, at) do
    update = %{
      "$set" => Map.merge(fields, %{"at" => at, "deleted" => false}),
      "$unset" => %{"expires_at" => ""}
    }

    write_if_newer(collection, id, at, update)
  end

  defp apply_tombstone(collection, id, fields, at) do
    expires_at = DateTime.add(DateTime.utc_now(), @tombstone_ttl_seconds, :second)

    update = %{
      "$set" => Map.merge(fields, %{"at" => at, "deleted" => true, "expires_at" => expires_at})
    }

    write_if_newer(collection, id, at, update)
  end

  defp write_if_newer(collection, id, at, update) do
    filter = %{"_id" => id, "at" => %{"$lte" => at}}

    case Mongo.update_one(@conn, collection, filter, update, upsert: true) do
      {:ok, _result} -> {:ok, :applied}
      {:error, error} -> if duplicate_key?(error), do: {:ok, :stale}, else: {:error, error}
    end
  end

  defp duplicate_key?(%Mongo.WriteError{write_errors: [%{"code" => 11_000} | _]}), do: true
  defp duplicate_key?(%{code: 11_000}), do: true
  defp duplicate_key?(_other), do: false
end
