defmodule Notifications.History do
  alias Notifications.Settings
  alias Notifications.UUID
  alias Notifications.Unread.{Access, Repo}

  @keep_forever 0
  @default_limit 50
  @max_limit 100

  @type item :: %{String.t() => String.t() | nil}
  @type page :: %{items: [item()], next_cursor: String.t() | nil}
  @type position :: {DateTime.t(), String.t()}

  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @spec record_mentions(map()) :: :ok | {:error, term()}
  def record_mentions(%{mentioned_user_ids: mentioned, author_id: author_id} = event) do
    case Enum.reject(mentioned, &(&1 == author_id)) do
      [] -> :ok
      recipients -> record_mentions(recipients, event)
    end
  end

  defp record_mentions(recipients, event) do
    with {:ok, docs} <-
           Repo.impl().list_settings_for(recipients, [event.channel_id, event.server_id]) do
      docs_by_user = Enum.group_by(docs, & &1["user_id"])

      recipients
      |> Enum.filter(&notifies?(Map.get(docs_by_user, &1, []), event))
      |> Enum.map(&mention_item(&1, event))
      |> put()
    end
  end

  @spec record_direct(map()) :: :ok | {:error, term()}
  def record_direct(%{author_id: author_id, recipient_id: author_id}), do: :ok

  def record_direct(%{recipient_id: recipient_id} = event) do
    put([
      base_item(recipient_id, "direct_message", event)
      |> Map.put("conversation_id", event.conversation_id)
    ])
  end

  @spec record_transfer(map()) :: :ok | {:error, term()}
  def record_transfer(event) do
    [receiver_item(event) | sender_items(event)]
    |> Repo.impl().upsert_history()
  end

  @spec sync_mentions(map()) :: {:ok, [String.t()]} | {:error, term()}
  def sync_mentions(%{message_id: message_id, author_id: author_id} = event) do
    mentioned = event.mentioned_user_ids |> Enum.reject(&(&1 == author_id)) |> Enum.uniq()

    with {:ok, existing} <- Repo.impl().list_history_mention_users(message_id),
         :ok <- drop_removed(message_id, existing -- mentioned),
         {:ok, added} <- add_new(mentioned -- existing, event) do
      {:ok, added}
    end
  end

  @spec forget(String.t()) :: :ok | {:error, term()}
  def forget(message_id), do: Repo.impl().delete_history_entries(message_id, :all)

  defp drop_removed(_message_id, []), do: :ok
  defp drop_removed(message_id, users), do: Repo.impl().delete_history_entries(message_id, users)

  defp add_new([], _event), do: {:ok, []}

  defp add_new(candidates, event) do
    with {:ok, docs} <-
           Repo.impl().list_settings_for(candidates, [event.channel_id, event.server_id]) do
      docs_by_user = Enum.group_by(docs, & &1["user_id"])
      added = Enum.filter(candidates, &notifies?(Map.get(docs_by_user, &1, []), event))

      with :ok <- added |> Enum.map(&mention_item(&1, event)) |> put() do
        {:ok, added}
      end
    end
  end

  @spec list(String.t(), keyword()) :: {:ok, page()} | {:error, term()}
  def list(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    with {:ok, docs} <- Repo.impl().list_history(user_id, Keyword.get(opts, :before), limit),
         {:ok, visible} <- visible_channels(user_id, docs) do
      {:ok,
       %{
         items: docs |> Enum.filter(&visible?(&1, visible)) |> Enum.map(&render/1),
         next_cursor: next_cursor(docs, limit)
       }}
    end
  end

  defp notifies?(docs, event),
    do: Settings.effective_level_for(docs, event.channel_id, event.server_id) != "none"

  defp mention_item(user_id, event) do
    user_id
    |> base_item("mention", event)
    |> Map.merge(%{"server_id" => event.server_id, "channel_id" => event.channel_id})
  end

  defp receiver_item(event) do
    transfer_item(event.to_user_id, event, event.created_at)
  end

  defp sender_items(%{status: status} = event) when status in ~w(accepted rejected expired) do
    [transfer_item(event.from_user_id, event, event.resolved_at || event.occurred_at)]
  end

  defp sender_items(_event), do: []

  defp transfer_item(user_id, event, occurred_at) do
    %{
      "_id" => user_id <> ":" <> event.transfer_id,
      "user_id" => user_id,
      "kind" => "ownership_transfer",
      "message_id" => event.transfer_id,
      "author_id" => event.from_user_id,
      "to_user_id" => event.to_user_id,
      "server_id" => event.server_id,
      "transfer_status" => event.status,
      "occurred_at" => occurred_at
    }
    |> put_expiry(occurred_at)
  end

  defp base_item(user_id, kind, event) do
    %{
      "_id" => user_id <> ":" <> event.message_id,
      "user_id" => user_id,
      "kind" => kind,
      "message_id" => event.message_id,
      "author_id" => event.author_id,
      "occurred_at" => event.occurred_at
    }
    |> put_expiry(event.occurred_at)
  end

  defp put_expiry(item, occurred_at) do
    case retention_days() do
      @keep_forever -> item
      days -> Map.put(item, "expires_at", DateTime.add(occurred_at, days * 24 * 60 * 60, :second))
    end
  end

  defp put([]), do: :ok
  defp put(items), do: Repo.impl().put_history(items)

  defp retention_days,
    do: Application.get_env(:notifications, :history_retention_days, @keep_forever)

  defp visible_channels(user_id, docs) do
    if Enum.any?(docs, &(&1["kind"] == "mention")) do
      with {:ok, visible} <- Access.visible_channels(user_id) do
        {:ok, MapSet.new(visible, & &1.channel_id)}
      end
    else
      {:ok, MapSet.new()}
    end
  end

  defp visible?(%{"kind" => "mention", "channel_id" => channel_id}, visible),
    do: MapSet.member?(visible, channel_id)

  defp visible?(_doc, _visible), do: true

  defp next_cursor(docs, limit) when length(docs) == limit, do: encode_cursor(List.last(docs))
  defp next_cursor(_docs, _limit), do: nil

  defp encode_cursor(%{"occurred_at" => %DateTime{} = at, "message_id" => message_id}),
    do: "#{DateTime.to_unix(at, :millisecond)}_#{message_id}"

  @spec decode_cursor(term()) :: {:ok, position()} | :error
  def decode_cursor(raw) when is_binary(raw) do
    with [millis, message_id] <- String.split(raw, "_", parts: 2),
         {millis, ""} <- Integer.parse(millis),
         true <- millis >= 0 and UUID.valid?(message_id),
         {:ok, at} <- DateTime.from_unix(millis, :millisecond) do
      {:ok, {at, message_id}}
    else
      _invalid -> :error
    end
  end

  def decode_cursor(_other), do: :error

  defp render(%{"kind" => "ownership_transfer"} = doc) do
    doc
    |> render_message()
    |> Map.merge(%{
      "to_user_id" => doc["to_user_id"],
      "transfer_status" => doc["transfer_status"]
    })
  end

  defp render(doc), do: render_message(doc)

  defp render_message(doc) do
    %{
      "kind" => doc["kind"],
      "message_id" => doc["message_id"],
      "author_id" => doc["author_id"],
      "occurred_at" => doc["occurred_at"] && DateTime.to_iso8601(doc["occurred_at"]),
      "server_id" => doc["server_id"],
      "channel_id" => doc["channel_id"],
      "conversation_id" => doc["conversation_id"]
    }
  end
end
