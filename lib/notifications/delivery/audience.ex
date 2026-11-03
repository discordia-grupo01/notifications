defmodule Notifications.Delivery.Audience do
  alias Notifications.Delivery.Repo

  @spec reachable([String.t()], DateTime.t()) :: {:ok, [String.t()]} | {:error, term()}
  def reachable([], _now), do: {:ok, []}

  def reachable(user_ids, now) do
    repo = Repo.impl()

    with {:ok, disabled} <- repo.list_push_disabled(user_ids),
         {:ok, presence} <- repo.get_presence(user_ids) do
      {:ok,
       Enum.reject(user_ids, fn user_id ->
         user_id in disabled or app_open?(Map.get(presence, user_id), now)
       end)}
    end
  end

  defp app_open?(nil, _now), do: false

  defp app_open?(%{expires_at: %DateTime{} = expires_at} = state, now) do
    DateTime.compare(expires_at, now) == :gt and
      (state.do_not_disturb or state.connections == "active")
  end

  defp app_open?(_state, _now), do: false
end
