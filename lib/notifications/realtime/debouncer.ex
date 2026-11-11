defmodule Notifications.Realtime.Debouncer do
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec run(String.t(), (-> any())) :: :ok
  def run(key, fun) do
    case window_ms() do
      0 ->
        fun.()
        :ok

      window ->
        GenServer.cast(__MODULE__, {:run, key, fun, window})
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:run, key, fun, window}, state) do
    case Map.fetch(state, key) do
      :error ->
        fun.()
        Process.send_after(self(), {:cooldown, key}, window)
        {:noreply, Map.put(state, key, {:cooling, nil})}

      {:ok, {:cooling, _pending}} ->
        {:noreply, Map.put(state, key, {:cooling, {fun, window}})}
    end
  end

  @impl true
  def handle_info({:cooldown, key}, state) do
    case Map.get(state, key) do
      {:cooling, {fun, window}} ->
        fun.()
        Process.send_after(self(), {:cooldown, key}, window)
        {:noreply, Map.put(state, key, {:cooling, nil})}

      _idle ->
        {:noreply, Map.delete(state, key)}
    end
  end

  defp window_ms, do: Application.get_env(:notifications, :realtime_debounce_ms, 3_000)
end
