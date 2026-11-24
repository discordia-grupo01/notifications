defmodule Notifications.Delivery.Content do
  alias Notifications.Delivery.Repo
  alias Notifications.Events.Event
  alias Notifications.Unread.Repo, as: UnreadRepo

  @default_user "Usuario"
  @default_mention "@usuario"
  @default_role_mention "@rol"
  @mention ~r/<@(&?)([A-Za-z0-9_-]{1,64})>/
  @default_server "Servidor"
  @default_channel "canal"
  @default_text "Nuevo mensaje"

  @type t :: %{title: String.t(), body: String.t(), data: map()}

  @spec build(struct()) :: {:ok, t()} | {:error, term()}
  def build(%Event.PrivateCall{} = event) do
    with {:ok, caller} <- user_name(event.caller_id) do
      {:ok,
       %{
         title: "Llamada de voz",
         body: call_body(caller, event.status),
         data: %{
           "call_id" => event.call_id,
           "conversation_id" => event.conversation_id,
           "caller_id" => event.caller_id,
           "recipient_id" => event.recipient_id,
           "status" => event.status
         }
       }}
    end
  end

  def build(%Event.OwnershipTransferUpdated{} = event) do
    with {:ok, server} <- server_name(event.server_id),
         {:ok, owner} <- user_name(event.from_user_id),
         {:ok, receiver} <- user_name(event.to_user_id) do
      {:ok,
       %{
         title: "Transferencia de propiedad",
         body: transfer_body(event.status, server, owner, receiver),
         data: %{
           "transfer_id" => event.transfer_id,
           "server_id" => event.server_id,
           "status" => event.status
         }
       }}
    end
  end

  def build(%{conversation_id: conversation_id} = event) do
    with {:ok, author, preview} <- author_and_preview(event) do
      {:ok,
       %{
         title: author,
         body: preview || @default_text,
         data: %{
           "conversation_id" => conversation_id,
           "message_id" => event.message_id,
           "author_id" => event.author_id
         }
       }}
    end
  end

  def build(%Event.MessageUpdated{} = event) do
    with {:ok, content} <- build_channel(event) do
      {:ok,
       %{
         content
         | body: content.body <> " (editado)",
           data: Map.put(content.data, "edited", true)
       }}
    end
  end

  def build(%{server_id: _server_id, channel_id: _channel_id} = event), do: build_channel(event)

  defp transfer_body("pending", server, owner, _receiver),
    do: "#{owner} quiere transferirte la propiedad de #{server}"

  defp transfer_body("accepted", server, _owner, receiver),
    do: "#{receiver} aceptó ser el nuevo dueño de #{server}"

  defp transfer_body("rejected", server, _owner, receiver),
    do: "#{receiver} rechazó ser el nuevo dueño de #{server}"

  defp transfer_body("expired", server, _owner, _receiver),
    do: "La transferencia de #{server} venció sin respuesta"

  defp transfer_body(_status, server, _owner, _receiver),
    do: "Actualización de la transferencia de #{server}"

  defp call_body(caller, "ringing"), do: "#{caller} te está llamando"
  defp call_body(_caller, "missed"), do: "La llamada de voz no fue respondida"
  defp call_body(_caller, "rejected"), do: "La llamada de voz fue rechazada"
  defp call_body(_caller, "ended"), do: "La llamada de voz finalizó"
  defp call_body(_caller, _status), do: "Actualización de llamada de voz"

  defp build_channel(%{server_id: server_id, channel_id: channel_id} = event) do
    with {:ok, author, preview} <- author_and_preview(event),
         {:ok, server} <- server_name(server_id),
         {:ok, channel} <- channel_name(event) do
      {:ok,
       %{
         title: "#{author} en ##{channel}",
         body: "#{server} · #{preview || @default_text}",
         data: %{
           "server_id" => server_id,
           "channel_id" => channel_id,
           "message_id" => event.message_id,
           "author_id" => event.author_id
         }
       }}
    end
  end

  defp author_and_preview(%{author_id: author_id, content_preview: preview}) do
    {user_ids, role_ids} = mention_ids(preview)
    ids = Enum.uniq([author_id | user_ids])

    with {:ok, names} <- Repo.impl().get_user_names(ids),
         {:ok, role_names} <- get_role_names(role_ids) do
      {:ok, Map.get(names, author_id) || @default_user,
       resolve_mentions(preview, names, role_names)}
    end
  end

  defp mention_ids(nil), do: {[], []}

  defp mention_ids(preview) do
    tokens = Regex.scan(@mention, preview, capture: :all_but_first)

    users = for ["", id] <- tokens, do: id
    roles = for ["&", id] <- tokens, do: String.downcase(id)

    {Enum.uniq(users), Enum.uniq(roles)}
  end

  defp get_role_names([]), do: {:ok, %{}}
  defp get_role_names(role_ids), do: UnreadRepo.impl().get_role_names(role_ids)

  defp resolve_mentions(nil, _names, _role_names), do: nil

  defp resolve_mentions(preview, names, role_names) do
    Regex.replace(@mention, preview, fn
      _token, "&", id -> mention(Map.get(role_names, String.downcase(id)), @default_role_mention)
      _token, _kind, id -> mention(Map.get(names, id), @default_mention)
    end)
  end

  defp mention(nil, default), do: default
  defp mention(name, _default), do: "@" <> name

  defp user_name(user_id) do
    with {:ok, names} <- Repo.impl().get_user_names([user_id]) do
      {:ok, Map.get(names, user_id) || @default_user}
    end
  end

  defp server_name(server_id) do
    with {:ok, names} <- Repo.impl().get_server_names([server_id]) do
      {:ok, Map.get(names, server_id) || @default_server}
    end
  end

  defp channel_name(%{channel_name: name}) when is_binary(name), do: {:ok, name}

  defp channel_name(%{channel_id: channel_id}) do
    case UnreadRepo.impl().get_channel(channel_id) do
      %{"name" => name} when is_binary(name) -> {:ok, name}
      {:error, _reason} = error -> error
      _missing -> {:ok, @default_channel}
    end
  end
end
