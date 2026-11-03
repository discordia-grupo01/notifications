defmodule Notifications.Delivery.AudienceTest do
  use ExUnit.Case, async: true
  import Mox

  alias Notifications.Delivery.Audience
  alias Notifications.Delivery.RepoMock

  setup :set_mox_from_context
  setup :verify_on_exit!

  @now ~U[2026-11-02 12:00:00Z]
  @later ~U[2026-11-02 18:00:00Z]
  @earlier ~U[2026-11-02 06:00:00Z]

  defp state(connections, dnd \\ false, expires_at \\ @later),
    do: %{connections: connections, do_not_disturb: dnd, expires_at: expires_at}

  defp stub_audience(disabled, presence) do
    expect(RepoMock, :list_push_disabled, fn _ids -> {:ok, disabled} end)
    expect(RepoMock, :get_presence, fn _ids -> {:ok, presence} end)
  end

  test "nobody asked, nothing queried" do
    assert Audience.reachable([], @now) == {:ok, []}
  end

  test "whoever has no presence information is assumed to have the app closed" do
    stub_audience([], %{})

    assert Audience.reachable(["u1"], @now) == {:ok, ["u1"]}
  end

  test "an active connection means the app is open and there is no push" do
    stub_audience([], %{"u1" => state("active"), "u2" => state("none")})

    assert Audience.reachable(["u1", "u2"], @now) == {:ok, ["u2"]}
  end

  test "an idle connection still gets the push" do
    stub_audience([], %{"u1" => state("idle")})

    assert Audience.reachable(["u1"], @now) == {:ok, ["u1"]}
  end

  test "do not disturb gets no push, whatever the connections" do
    stub_audience([], %{
      "u1" => state("none", true),
      "u2" => state("idle", true),
      "u3" => state("active", true)
    })

    assert Audience.reachable(["u1", "u2", "u3"], @now) == {:ok, []}
  end

  test "whoever turned push off gets none" do
    stub_audience(["u1"], %{})

    assert Audience.reachable(["u1", "u2"], @now) == {:ok, ["u2"]}
  end

  test "an expired state is ignored, so a stale active connection cannot silence the push" do
    stub_audience([], %{
      "u1" => state("active", false, @earlier),
      "u2" => state("none", true, @now)
    })

    assert Audience.reachable(["u1", "u2"], @now) == {:ok, ["u1", "u2"]}
  end

  test "a state without expiry is ignored" do
    stub_audience([], %{"u1" => %{connections: "active", do_not_disturb: false, expires_at: nil}})

    assert Audience.reachable(["u1"], @now) == {:ok, ["u1"]}
  end

  test "a storage failure is returned" do
    expect(RepoMock, :list_push_disabled, fn _ids -> {:error, :timeout} end)

    assert Audience.reachable(["u1"], @now) == {:error, :timeout}
  end

  test "a failure reading presence is returned" do
    expect(RepoMock, :list_push_disabled, fn _ids -> {:ok, []} end)
    expect(RepoMock, :get_presence, fn _ids -> {:error, :timeout} end)

    assert Audience.reachable(["u1"], @now) == {:error, :timeout}
  end
end
