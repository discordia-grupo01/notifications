defmodule Notifications.DeliveryHelpers do
  @supervisor Notifications.Delivery.TaskSupervisor

  def await_deliveries(attempts \\ 200) do
    cond do
      Task.Supervisor.children(@supervisor) == [] ->
        :ok

      attempts == 0 ->
        raise "deliveries did not finish"

      true ->
        Process.sleep(5)
        await_deliveries(attempts - 1)
    end
  end
end
