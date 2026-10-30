defmodule Notifications.UnreadTest do
  use ExUnit.Case, async: true
  import Mox

  alias Notifications.Unread
  alias Notifications.Unread.RepoMock

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @s1 "s1"
  @m1 "00000000-0000-7000-8000-000000000001"
  @m2 "00000000-0000-7000-8000-000000000002"
  @m3 "00000000-0000-7000-8000-000000000003"

  defp stub_visible(channels \\ ["c1"], opts \\ []) do
    joined = Keyword.get(opts, :joined, ~U[1970-01-01 00:00:00Z])

    stub(RepoMock, :list_memberships, fn @me ->
      {:ok,
       [
         %{
           "server_id" => @s1,
           "user_id" => @me,
           "role_ids" => ["everyone"],
           "joined_at" => joined
         }
       ]}
    end)

    stub(RepoMock, :get_server_owners, fn _ids -> {:ok, %{}} end)

    stub(RepoMock, :list_roles, fn _ids ->
      {:ok,
       [
         %{
           "_id" => "everyone",
           "server_id" => @s1,
           "permissions" => ["VIEW_CHANNELS"],
           "is_everyone" => true
         }
       ]}
    end)

    stub(RepoMock, :list_channels, fn _ids ->
      {:ok, Enum.map(channels, &%{"_id" => &1, "server_id" => @s1, "kind" => "text"})}
    end)

    stub(RepoMock, :list_overrides, fn _ids -> {:ok, []} end)
  end

  describe "snapshot/1" do
    test "CA1/CA2: builds per channel and per server flags from the stored activity" do
      stub_visible(["c1", "c2"])
      expect(RepoMock, :get_activity, fn ["c1", "c2"] -> {:ok, %{"c1" => @m3, "c2" => @m3}} end)
      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{"c2" => @m3}} end)
      expect(RepoMock, :get_mention_markers, fn @me, _ids -> {:ok, %{"c1" => @m3}} end)

      assert {:ok, state} = Unread.snapshot(@me)

      assert Notifications.Unread.State.snapshot(state) == %{
               "servers" => [
                 %{
                   "server_id" => @s1,
                   "unread" => true,
                   "mention" => true,
                   "channels" => [%{"channel_id" => "c1", "unread" => true, "mention" => true}]
                 }
               ]
             }
    end

    test "a user without memberships gets an empty state" do
      stub(RepoMock, :list_memberships, fn @me -> {:ok, []} end)
      stub(RepoMock, :get_server_owners, fn [] -> {:ok, %{}} end)
      stub(RepoMock, :list_roles, fn [] -> {:ok, []} end)
      stub(RepoMock, :list_channels, fn [] -> {:ok, []} end)
      stub(RepoMock, :list_overrides, fn [] -> {:ok, []} end)
      stub(RepoMock, :get_activity, fn [] -> {:ok, %{}} end)
      stub(RepoMock, :get_read_markers, fn @me, [] -> {:ok, %{}} end)
      stub(RepoMock, :get_mention_markers, fn @me, [] -> {:ok, %{}} end)

      assert {:ok, %{}} = Unread.snapshot(@me)
    end

    test "propagates a storage failure" do
      stub_visible()
      expect(RepoMock, :get_activity, fn _ids -> {:error, :timeout} end)

      assert Unread.snapshot(@me) == {:error, :timeout}
    end
  end

  describe "mark_read/3" do
    defp stub_channel(doc \\ %{"_id" => "c1", "server_id" => @s1, "kind" => "text"}),
      do: expect(RepoMock, :get_channel, fn "c1" -> doc end)

    test "without a message id it reads up to the last message of the channel" do
      stub_channel()
      stub_visible()
      expect(RepoMock, :get_activity, fn ["c1"] -> {:ok, %{"c1" => @m2}} end)
      expect(RepoMock, :mark_read, fn @me, "c1", @s1, @m2 -> :ok end)

      assert Unread.mark_read(@me, "c1") == {:ok, @m2}
    end

    test "with a message id it reads up to that message without asking for the activity" do
      stub_channel()
      stub_visible()
      expect(RepoMock, :mark_read, fn @me, "c1", @s1, @m2 -> :ok end)

      assert Unread.mark_read(@me, "c1", @m2) == {:ok, @m2}
    end

    test "a message the client already saw is accepted even if its event has not arrived yet" do
      stub_channel()
      stub_visible()
      expect(RepoMock, :mark_read, fn @me, "c1", @s1, @m3 -> :ok end)

      assert Unread.mark_read(@me, "c1", @m3) == {:ok, @m3}
    end

    test "a malformed message id is invalid" do
      for bad <- ["nope", "00000000-0000-4000-8000-000000000001", 5, %{}] do
        assert Unread.mark_read(@me, "c1", bad) == {:error, :invalid_payload}
      end
    end

    test "a message id from the far future is invalid" do
      future =
        DateTime.utc_now() |> DateTime.add(3_600, :second) |> Notifications.UUID.floor_v7()

      assert Unread.mark_read(@me, "c1", future) == {:error, :invalid_payload}
    end

    test "a blank message id means up to the last message" do
      stub_channel()
      stub_visible()
      expect(RepoMock, :get_activity, fn ["c1"] -> {:ok, %{"c1" => @m1}} end)
      expect(RepoMock, :mark_read, fn @me, "c1", @s1, @m1 -> :ok end)

      assert Unread.mark_read(@me, "c1", "") == {:ok, @m1}
    end

    test "a channel without messages has nothing to mark" do
      stub_channel()
      stub_visible()
      expect(RepoMock, :get_activity, fn ["c1"] -> {:ok, %{}} end)

      assert Unread.mark_read(@me, "c1") == {:ok, nil}
    end

    test "an unknown channel is not found" do
      expect(RepoMock, :get_channel, fn "c1" -> nil end)

      assert Unread.mark_read(@me, "c1") == {:error, :channel_not_found}
    end

    test "a voice channel is not found" do
      stub_channel(%{"_id" => "c1", "server_id" => @s1, "kind" => "voice"})

      assert Unread.mark_read(@me, "c1") == {:error, :channel_not_found}
    end

    test "a channel the user cannot see is forbidden" do
      stub_channel()
      stub_visible(["c2"])

      assert Unread.mark_read(@me, "c1") == {:error, :forbidden}
    end

    test "propagates storage failures" do
      expect(RepoMock, :get_channel, fn "c1" -> {:error, :timeout} end)

      assert Unread.mark_read(@me, "c1") == {:error, :timeout}
    end
  end

  describe "mark_all_read/1" do
    test "CA2: marks every channel with unread content up to its last message" do
      stub_visible(["c1", "c2", "c3"])

      expect(RepoMock, :get_activity, fn ["c1", "c2", "c3"] ->
        {:ok, %{"c1" => @m3, "c2" => @m2, "c3" => @m1}}
      end)

      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{"c2" => @m2, "c3" => @m1}} end)

      expect(RepoMock, :mark_all_read, fn @me, entries ->
        assert entries == [%{channel_id: "c1", server_id: @s1, message_id: @m3}]
        :ok
      end)

      assert Unread.mark_all_read(@me) == {:ok, 1}
    end

    test "covers channels of every server and every kind of unread" do
      stub_visible(["c1", "c2"])
      expect(RepoMock, :get_activity, fn _ids -> {:ok, %{"c1" => @m2, "c2" => @m3}} end)
      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{"c1" => @m1}} end)

      expect(RepoMock, :mark_all_read, fn @me, entries ->
        assert Enum.sort_by(entries, & &1.channel_id) == [
                 %{channel_id: "c1", server_id: @s1, message_id: @m2},
                 %{channel_id: "c2", server_id: @s1, message_id: @m3}
               ]

        :ok
      end)

      assert Unread.mark_all_read(@me) == {:ok, 2}
    end

    test "does not write anything when nothing is unread" do
      stub_visible(["c1"])
      expect(RepoMock, :get_activity, fn _ids -> {:ok, %{"c1" => @m2}} end)
      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{"c1" => @m3}} end)

      assert Unread.mark_all_read(@me) == {:ok, 0}
    end

    test "messages from before the member joined are not touched" do
      stub_visible(["c1"], joined: ~U[2026-10-01 00:00:00Z])
      expect(RepoMock, :get_activity, fn _ids -> {:ok, %{"c1" => @m3}} end)
      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{}} end)

      assert Unread.mark_all_read(@me) == {:ok, 0}
    end

    test "a user without channels has nothing to mark" do
      stub(RepoMock, :list_memberships, fn @me -> {:ok, []} end)
      stub(RepoMock, :get_server_owners, fn [] -> {:ok, %{}} end)
      stub(RepoMock, :list_roles, fn [] -> {:ok, []} end)
      stub(RepoMock, :list_channels, fn [] -> {:ok, []} end)
      stub(RepoMock, :list_overrides, fn [] -> {:ok, []} end)
      stub(RepoMock, :get_activity, fn [] -> {:ok, %{}} end)
      stub(RepoMock, :get_read_markers, fn @me, [] -> {:ok, %{}} end)

      assert Unread.mark_all_read(@me) == {:ok, 0}
    end

    test "propagates a storage failure when reading or writing" do
      stub_visible(["c1"])
      expect(RepoMock, :get_activity, fn _ids -> {:ok, %{"c1" => @m2}} end)
      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{}} end)
      expect(RepoMock, :mark_all_read, fn @me, _entries -> {:error, :timeout} end)

      assert Unread.mark_all_read(@me) == {:error, :timeout}
    end

    test "propagates a failure while reading the replica" do
      expect(RepoMock, :list_memberships, fn @me -> {:error, :timeout} end)

      assert Unread.mark_all_read(@me) == {:error, :timeout}
    end
  end

  test "mongo_ready?/0 reflects the ping" do
    expect(RepoMock, :ping, fn -> :ok end)
    assert Unread.mongo_ready?()

    expect(RepoMock, :ping, fn -> {:error, :timeout} end)
    refute Unread.mongo_ready?()
  end
end
