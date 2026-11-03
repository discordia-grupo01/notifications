defmodule NotificationsWeb.NotificationsChannel do
  use Phoenix.Channel
  require Logger

  alias Notifications.{Log, Push, Unread}
  alias Notifications.Unread.State
  alias NotificationsWeb.ApiError
  alias Phoenix.Socket.Broadcast

  @dialyzer {:nowarn_function, handle_info: 2}

  @impl true
  def join("notifications:" <> user_id, _params, %{assigns: %{user_id: user_id}} = socket) do
    send(self(), :after_join)
    {:ok, assign(socket, state: %{}, topics: MapSet.new())}
  end

  def join("notifications:" <> _other, _params, _socket),
    do: {:error, ApiError.payload(:forbidden)}

  @impl true
  def handle_info(:after_join, socket) do
    case load(socket) do
      {:ok, socket} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("snapshot_failed",
          user_id: socket.assigns.user_id,
          reason: Log.reason(reason)
        )

        {:stop, :snapshot_failed, socket}
    end
  end

  def handle_info(%Broadcast{event: "resync"}, socket) do
    case load(socket) do
      {:ok, socket} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("resync_failed",
          user_id: socket.assigns.user_id,
          reason: Log.reason(reason)
        )

        {:noreply, socket}
    end
  end

  def handle_info(%Broadcast{event: "message_created", payload: payload}, socket) do
    event = %{
      channel_id: payload["channel_id"],
      message_id: payload["message_id"],
      author_id: payload["author_id"],
      mentioned_user_ids: payload["mentioned_user_ids"] || []
    }

    {:noreply,
     update_state(
       socket,
       payload["channel_id"],
       &State.message_created(&1, user_id(socket), event)
     )}
  end

  def handle_info(
        %Broadcast{event: "read", payload: %{"channel_id" => id, "message_id" => up_to}},
        socket
      ),
      do: {:noreply, update_state(socket, id, &State.mark_read(&1, id, up_to))}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_in("mark_read", %{"channel_id" => channel_id} = params, socket)
      when is_binary(channel_id) do
    case Unread.mark_read(user_id(socket), channel_id, Map.get(params, "message_id")) do
      {:ok, nil} ->
        {:reply, :ok, socket}

      {:ok, up_to} ->
        publish_read(user_id(socket), channel_id, up_to)
        {:reply, :ok, update_state(socket, channel_id, &State.mark_read(&1, channel_id, up_to))}

      {:error, reason} when reason in [:forbidden, :channel_not_found, :invalid_payload] ->
        {:reply, {:error, ApiError.payload(reason)}, socket}

      {:error, reason} ->
        Logger.error("mark_read_failed",
          user_id: user_id(socket),
          channel_id: channel_id,
          reason: Log.reason(reason)
        )

        {:reply, {:error, ApiError.payload(:unread_unavailable)}, socket}
    end
  end

  def handle_in("mark_all_read", _params, socket) do
    case Unread.mark_all_read(user_id(socket)) do
      {:ok, cleared} ->
        publish_resync(user_id(socket))
        {:reply, {:ok, %{"channels" => cleared}}, socket}

      {:error, reason} ->
        Logger.error("mark_all_read_failed",
          user_id: user_id(socket),
          reason: Log.reason(reason)
        )

        {:reply, {:error, ApiError.payload(:unread_unavailable)}, socket}
    end
  end

  def handle_in("snapshot", _params, socket) do
    case load(socket) do
      {:ok, socket} -> {:reply, :ok, socket}
      {:error, _reason} -> {:reply, {:error, ApiError.payload(:unread_unavailable)}, socket}
    end
  end

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, ApiError.payload(:invalid_payload)}, socket}

  defp load(socket) do
    with {:ok, state} <- Unread.snapshot(user_id(socket)) do
      socket = subscribe(socket, state)
      push(socket, "snapshot", State.snapshot(state))
      {:ok, assign(socket, :state, state)}
    end
  end

  defp subscribe(socket, state) do
    wanted =
      MapSet.new([
        "user:" <> user_id(socket) | Enum.map(State.server_ids(state), &("server:" <> &1))
      ])

    current = socket.assigns.topics

    Enum.each(
      MapSet.difference(wanted, current),
      &Phoenix.PubSub.subscribe(Notifications.PubSub, &1)
    )

    Enum.each(
      MapSet.difference(current, wanted),
      &Phoenix.PubSub.unsubscribe(Notifications.PubSub, &1)
    )

    assign(socket, :topics, wanted)
  end

  defp update_state(socket, channel_id, fun) do
    before_flags = State.channel_flags(socket.assigns.state, channel_id)
    state = fun.(socket.assigns.state)

    if State.channel_flags(state, channel_id) != before_flags,
      do: push(socket, "unread_updated", State.change(state, channel_id))

    assign(socket, :state, state)
  end

  defp publish_resync(user_id) do
    case Push.publish("user:" <> user_id, "resync", %{}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("resync_broadcast_failed", user_id: user_id, reason: Log.reason(reason))
    end
  end

  defp publish_read(user_id, channel_id, up_to) do
    case Push.publish("user:" <> user_id, "read", %{
           "channel_id" => channel_id,
           "message_id" => up_to
         }) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("read_broadcast_failed",
          user_id: user_id,
          channel_id: channel_id,
          reason: Log.reason(reason)
        )
    end
  end

  defp user_id(socket), do: socket.assigns.user_id
end
