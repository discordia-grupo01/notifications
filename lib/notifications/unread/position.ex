defmodule Notifications.Unread.Position do
  @moduledoc """
  Where a message sits in its channel's timeline, as a string that sorts by time:
  `"<unix milliseconds, zero padded>_<message_id>"`.

  The unread state compares positions, never message ids: `messaging` only issues
  time-ordered ids (UUIDv7) when the client sends no `client_id`, and both apps
  always send one, so most ids are hashes (UUIDv5) with no order at all. The
  millisecond part comes from the event's `occurred_at` (the message's
  `inserted_at`); the id only breaks ties inside the same millisecond.
  """

  import Kernel, except: [floor: 1, max: 2]

  @width 15

  @type t :: String.t()

  @spec of(DateTime.t(), String.t()) :: t()
  def of(%DateTime{} = at, message_id) when is_binary(message_id),
    do: floor(at) <> message_id

  @doc "Sorts before every message at or after `at`, so they all count as unread."
  @spec floor(DateTime.t()) :: t()
  def floor(%DateTime{} = at) do
    millis = at |> DateTime.to_unix(:millisecond) |> Kernel.max(0)
    (millis |> Integer.to_string() |> String.pad_leading(@width, "0")) <> "_"
  end

  @spec max(t() | nil, t() | nil) :: t() | nil
  def max(nil, other), do: other
  def max(current, nil), do: current
  def max(current, other), do: Kernel.max(current, other)

  @spec after?(t() | nil, t() | nil) :: boolean()
  def after?(position, baseline) when is_binary(position),
    do: is_nil(baseline) or position > baseline

  def after?(_position, _baseline), do: false
end
