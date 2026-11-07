defmodule Notifications.Events.Consumer do
  use GenServer
  require Logger

  alias Notifications.Events.{Audit, Backoff, DeadLetter, Event, Lifecycle}
  alias Notifications.Log
  alias Notifications.Tracing

  @exchange "discordia.events"
  @default_queue "notifications.unread_state"
  @unaudited [
    Event.MessageCreated,
    Event.DirectMessageCreated,
    Event.MessageUpdated,
    Event.MessageDeleted,
    Event.UserProfileUpdated,
    Event.UserPresenceChanged
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    url = Keyword.fetch!(opts, :url)
    queue = Keyword.get(opts, :queue, @default_queue)
    send(self(), :connect)

    {:ok,
     %{url: url, queue: queue, backoff: Backoff.initial(), conn: nil, chan: nil, attempts: %{}}}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state.url, state.queue) do
      {:ok, conn, chan} ->
        Process.monitor(conn.pid)
        Logger.info("events_consumer_connected", queue: state.queue)
        {:noreply, %{state | conn: conn, chan: chan, backoff: Backoff.initial()}}

      {:error, reason} ->
        Logger.warning("events_consumer_connect_failed",
          reason: Log.reason(reason),
          retry_in_ms: state.backoff
        )

        Process.send_after(self(), :connect, state.backoff)
        {:noreply, %{state | backoff: Backoff.next(state.backoff)}}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("events_consumer_connection_down", reason: Log.reason(reason))
    send(self(), :connect)
    {:noreply, %{state | conn: nil, chan: nil, backoff: Backoff.initial()}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:basic_consume_ok, _meta}, state), do: {:noreply, state}
  def handle_info({:basic_cancel, _meta}, state), do: {:stop, :normal, state}
  def handle_info({:basic_cancel_ok, _meta}, state), do: {:noreply, state}

  def handle_info({:basic_deliver, payload, meta}, state) do
    attempts = handle_delivery(payload, meta, state)
    {:noreply, %{state | attempts: attempts}}
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    try do
      AMQP.Connection.close(conn)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp handle_delivery(payload, meta, state) do
    Tracing.consumer_span(meta, state.queue, fn ->
      outcome =
        case Jason.decode(payload) do
          {:ok, decoded} -> handle_decoded(decoded, payload, meta)
          {:error, reason} -> handle_malformed(payload, meta, reason)
        end

      Tracing.mark_outcome(outcome)
      DeadLetter.finish(outcome, state, meta, payload)
    end)
  end

  defp handle_decoded(decoded, payload, meta) do
    case Event.parse(meta.routing_key, decoded) do
      {:ok, event} ->
        case Lifecycle.handle(event) do
          :ok -> audit(event, meta, payload, :processed)
          {:ignored, _cause} -> audit(event, meta, payload, :ignored_stale)
          {:error, reason} -> failed(meta, reason)
        end

      {:error, reason} ->
        Logger.warning("events_consumer_bad_message",
          reason: Log.reason(reason),
          routing_key: meta.routing_key
        )

        Audit.record(%{
          event_id: event_id(decoded),
          routing_key: meta.routing_key,
          raw_body: payload,
          status: discard_status(reason),
          error: inspect(reason)
        })

        :ack
    end
  end

  defp audit(%module{}, _meta, _payload, _status) when module in @unaudited, do: :ack

  defp audit(event, meta, payload, status) do
    Audit.record(%{
      event_id: event.event_id,
      routing_key: meta.routing_key,
      raw_body: payload,
      status: status,
      error: nil
    })

    :ack
  end

  defp failed(meta, reason) do
    Logger.error("events_consumer_event_failed",
      reason: Log.reason(reason),
      routing_key: meta.routing_key
    )

    :retry
  end

  defp handle_malformed(payload, meta, reason) do
    Logger.warning("events_consumer_bad_message",
      reason: Log.reason(reason),
      routing_key: meta.routing_key
    )

    Audit.record(%{
      event_id: nil,
      routing_key: meta.routing_key,
      raw_body: payload,
      status: :discarded_malformed_payload,
      error: inspect(reason)
    })

    :ack
  end

  defp event_id(%{"event_id" => id}) when is_binary(id), do: id
  defp event_id(_decoded), do: nil

  defp discard_status(:unknown_routing_key), do: :discarded_unknown_routing_key
  defp discard_status(:invalid_payload), do: :discarded_invalid_payload

  defp connect(url, queue) do
    with {:ok, conn} <- Notifications.Events.Connection.open(url),
         {:ok, chan} <- AMQP.Channel.open(conn),
         :ok <- AMQP.Exchange.declare(chan, @exchange, :topic, durable: true),
         {:ok, _info} <- AMQP.Queue.declare(chan, queue, durable: true),
         :ok <- DeadLetter.declare(chan, queue),
         :ok <- bind_routing_keys(chan, queue),
         {:ok, _consumer_tag} <- AMQP.Basic.consume(chan, queue) do
      {:ok, conn, chan}
    end
  end

  defp bind_routing_keys(chan, queue) do
    Enum.reduce_while(Event.routing_keys(), :ok, fn key, :ok ->
      case AMQP.Queue.bind(chan, queue, @exchange, routing_key: key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
