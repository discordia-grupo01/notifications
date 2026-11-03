defmodule Notifications.Delivery.Content do
  alias Notifications.Delivery.Repo
  alias Notifications.Events.Event
  alias Notifications.Unread.Repo, as: UnreadRepo

  @default_user "Usuario"
  @default_server "Servidor"
  @default_channel "canal"
  @default_text "Nuevo mensaje"
  @direct_title "Mensaje directo"

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

  defp call_body(caller, "ringing"), do: "#{caller} te está llamando"
  defp call_body(_caller, "missed"), do: "La llamada de voz no fue respondida"
  defp call_body(_caller, "rejected"), do: "La llamada de voz fue rechazada"
  defp call_body(_caller, "ended"), do: "La llamada de voz finalizó"
  defp call_body(_caller, _status), do: "Actualización de llamada de voz"

  def build(%{conversation_id: conversation_id} = event) do
    with {:ok, author} <- user_name(event.author_id) do
      {:ok,
       %{
         title: @direct_title,
         body: body(author, event.content_preview),
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

  defp build_channel(%{server_id: server_id, channel_id: channel_id} = event) do
    with {:ok, author} <- user_name(event.author_id),
         {:ok, server} <- server_name(server_id),
         {:ok, channel} <- channel_name(event) do
      {:ok,
       %{
         title: "#{server} - #{channel}",
         body: body(author, event.content_preview),
         data: %{
           "server_id" => server_id,
           "channel_id" => channel_id,
           "message_id" => event.message_id,
           "author_id" => event.author_id
         }
       }}
    end
  end

  defp body(author, nil), do: "#{author}: #{@default_text}"
  defp body(author, preview), do: "#{author}: #{preview}"

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
