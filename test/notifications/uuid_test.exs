defmodule Notifications.UUIDTest do
  use ExUnit.Case, async: true

  alias Notifications.UUID

  test "generate/0 returns a well-formed UUIDv4" do
    assert UUID.generate() =~
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  end

  test "generate/0 never repeats across calls" do
    uuids = for _ <- 1..1_000, do: UUID.generate()

    assert length(Enum.uniq(uuids)) == 1_000
  end

  test "floor_v7/1 returns a well-formed UUIDv7 carrying the given instant" do
    at = ~U[2026-10-01 12:00:00.000Z]
    floor = UUID.floor_v7(at)

    assert floor =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

    <<ms::48, _rest::bitstring>> = Base.decode16!(String.replace(floor, "-", ""), case: :lower)
    assert ms == DateTime.to_unix(at, :millisecond)
  end

  test "floor_v7/1 sorts before any id generated at or after that instant" do
    at = DateTime.utc_now()
    floor = UUID.floor_v7(at)

    <<ms::48, rest::80>> = Base.decode16!(String.replace(floor, "-", ""), case: :lower)
    later = <<ms::48, 7::4, 1::12, 2::2, 0::62>>

    assert rest == <<7::4, 0::12, 2::2, 0::62>> |> then(fn <<r::80>> -> r end)
    assert floor < format(later)
  end

  test "floor_v7/1 sorts by time" do
    assert UUID.floor_v7(~U[2026-01-01 00:00:00Z]) < UUID.floor_v7(~U[2026-01-01 00:00:01Z])
    assert UUID.floor_v7(~U[1970-01-01 00:00:00Z]) < UUID.floor_v7(~U[2026-01-01 00:00:00Z])
  end

  defp format(<<a::32, b::16, c::16, d::16, e::48>>) do
    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {part, width} ->
      part |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end

  describe "v7?/1" do
    test "accepts a UUIDv7" do
      assert UUID.v7?("00000000-0000-7000-8000-000000000001")
      assert UUID.v7?(UUID.floor_v7(~U[2026-10-31 12:00:00Z]))
    end

    test "rejects other versions, malformed text and non-strings" do
      refute UUID.v7?(UUID.generate())
      refute UUID.v7?("00000000-0000-7000-8000-00000000000")
      refute UUID.v7?("nope")
      refute UUID.v7?("")
      refute UUID.v7?(nil)
      refute UUID.v7?(7)
    end
  end
end
