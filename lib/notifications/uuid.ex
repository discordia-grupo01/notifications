defmodule Notifications.UUID do
  @v7 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  @any ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  @spec v7?(term()) :: boolean()
  def v7?(value) when is_binary(value), do: Regex.match?(@v7, value)
  def v7?(_other), do: false

  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value), do: Regex.match?(@any, value)
  def valid?(_other), do: false

  @spec generate() :: String.t()
  def generate do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    format(<<u0::48, 4::4, u1::12, 2::2, u2::62>>)
  end

  @spec floor_v7(DateTime.t()) :: String.t()
  def floor_v7(%DateTime{} = datetime) do
    millis = DateTime.to_unix(datetime, :millisecond)
    format(<<millis::48, 7::4, 0::12, 2::2, 0::62>>)
  end

  defp format(<<a::32, b::16, c::16, d::16, e::48>>) do
    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {part, width} ->
      part |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end
end
