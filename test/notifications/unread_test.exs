defmodule Notifications.UnreadTest do
  use ExUnit.Case, async: true
  import Mox

  alias Notifications.Unread
  alias Notifications.Unread.{Position, RepoMock}

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @s1 "s1"
  @id1 "9f0c1a52-5b1e-5c3a-9d2e-000000000001"
  @id2 "1a2b3c4d-5b1e-5c3a-9d2e-000000000002"
  @id3 "05e6f7a8-5b1e-5c3a-9d2e-000000000003"

  @p1 Position.of(~U[2026-09-30 00:00:01.000Z], @id1)
  @p2 Position.of(~U[2026-09-30 00:00:02.000Z], @id2)
  @p3 Position.of(~U[2026-09-30 00:00:03.000Z], @id3)

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
    stub(RepoMock, :list_settings, fn @me -> {:ok, []} end)
  end

  describe "snapshot/1" do
    test "CA1/CA2: builds per channel and per server flags from the stored activity" do
      stub_visible(["c1", "c2"])
      expect(RepoMock, :get_activity, fn ["c1", "c2"] -> {:ok, %{"c1" => @p3, "c2" => @p3}} end)
      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{"c2" => @p3}} end)
      expect(RepoMock, :get_unread_mentions, fn @me, _ids -> {:ok, %{"c1" => [@p3]}} end)

      assert {:ok, state} = Unread.snapshot(@me)

      assert Notifications.Unread.State.snapshot(state) == %{
               "servers" => [
                 %{
                   "server_id" => @s1,
                   "unread" => true,
                   "mention" => true,
                   "mention_count" => 1,
                   "notify" => true,
                   "muted" => false,
                   "channels" => [
                     %{
                       "channel_id" => "c1",
                       "unread" => true,
                       "mention" => true,
                       "mention_count" => 1,
                       "notify" => true,
                       "muted" => false
                     }
                   ]
                 }
               ],
               "muted" => %{"servers" => [], "channels" => []},
               "preferences" => %{"servers" => %{}, "channels" => %{}}
             }
    end

    test "CA1: a muted channel stays unread but its mention is not highlighted" do
      stub_visible(["c1", "c2"])

      stub(RepoMock, :list_settings, fn @me ->
        {:ok, [%{"scope" => "channel", "scope_id" => "c1", "server_id" => @s1, "muted" => true}]}
      end)

      expect(RepoMock, :get_activity, fn _ids -> {:ok, %{"c1" => @p3, "c2" => @p3}} end)
      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{}} end)

      expect(RepoMock, :get_unread_mentions, fn @me, _ids ->
        {:ok, %{"c1" => [@p3], "c2" => [@p3]}}
      end)

      assert {:ok, state} = Unread.snapshot(@me)

      assert Notifications.Unread.State.channel_flags(state, "c1") ==
               %{unread: true, mention: false, mention_count: 0, notify: false, muted: true}

      assert Notifications.Unread.State.channel_flags(state, "c2") ==
               %{unread: true, mention: true, mention_count: 1, notify: true, muted: false}
    end

    test "CA2: a muted server mutes all of its channels" do
      stub_visible(["c1", "c2"])

      stub(RepoMock, :list_settings, fn @me ->
        {:ok, [%{"scope" => "server", "scope_id" => @s1, "server_id" => @s1, "muted" => true}]}
      end)

      expect(RepoMock, :get_activity, fn _ids -> {:ok, %{"c1" => @p3, "c2" => @p3}} end)
      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{}} end)
      expect(RepoMock, :get_unread_mentions, fn @me, _ids -> {:ok, %{"c1" => [@p3]}} end)

      assert {:ok, state} = Unread.snapshot(@me)

      assert Notifications.Unread.State.server_flags(state, @s1) ==
               %{unread: true, mention: false, mention_count: 0, notify: false, muted: true}
    end

    test "CA2: the snapshot applies the channel level over the server level" do
      stub_visible(["c1", "c2"])

      stub(RepoMock, :list_settings, fn @me ->
        {:ok,
         [
           %{"scope" => "server", "scope_id" => @s1, "server_id" => @s1, "level" => "none"},
           %{"scope" => "channel", "scope_id" => "c1", "server_id" => @s1, "level" => "all"}
         ]}
      end)

      expect(RepoMock, :get_activity, fn _ids -> {:ok, %{"c1" => @p3, "c2" => @p3}} end)
      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{}} end)
      expect(RepoMock, :get_unread_mentions, fn @me, _ids -> {:ok, %{"c2" => [@p3]}} end)

      assert {:ok, state} = Unread.snapshot(@me)

      assert Notifications.Unread.State.channel_flags(state, "c1") ==
               %{unread: true, mention: false, mention_count: 0, notify: true, muted: false}

      assert Notifications.Unread.State.channel_flags(state, "c2") ==
               %{unread: true, mention: false, mention_count: 0, notify: false, muted: false}
    end

    test "propagates a failure reading the mutes" do
      stub_visible()
      expect(RepoMock, :get_activity, fn _ids -> {:ok, %{}} end)
      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{}} end)
      expect(RepoMock, :get_unread_mentions, fn @me, _ids -> {:ok, %{}} end)
      stub(RepoMock, :list_settings, fn @me -> {:error, :timeout} end)

      assert Unread.snapshot(@me) == {:error, :timeout}
    end

    test "a user without memberships gets an empty state" do
      stub(RepoMock, :list_memberships, fn @me -> {:ok, []} end)
      stub(RepoMock, :get_server_owners, fn [] -> {:ok, %{}} end)
      stub(RepoMock, :list_roles, fn [] -> {:ok, []} end)
      stub(RepoMock, :list_channels, fn [] -> {:ok, []} end)
      stub(RepoMock, :list_overrides, fn [] -> {:ok, []} end)
      stub(RepoMock, :get_activity, fn [] -> {:ok, %{}} end)
      stub(RepoMock, :get_read_markers, fn @me, [] -> {:ok, %{}} end)
      stub(RepoMock, :get_unread_mentions, fn @me, [] -> {:ok, %{}} end)
      stub(RepoMock, :list_settings, fn @me -> {:ok, []} end)

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
      expect(RepoMock, :get_activity, fn ["c1"] -> {:ok, %{"c1" => @p2}} end)
      expect(RepoMock, :mark_read, fn @me, "c1", @s1, @p2 -> :ok end)

      assert Unread.mark_read(@me, "c1") == {:ok, @p2}
    end

    test "with a message id it reads up to exactly that message" do
      stub_channel()
      stub_visible()
      expect(RepoMock, :find_position, fn "c1", @id2 -> {:ok, @p2} end)
      expect(RepoMock, :mark_read, fn @me, "c1", @s1, @p2 -> :ok end)

      assert Unread.mark_read(@me, "c1", @id2) == {:ok, @p2}
    end

    test "a message whose event has not arrived yet reads up to now" do
      stub_channel()
      stub_visible()
      expect(RepoMock, :find_position, fn "c1", @id3 -> {:ok, nil} end)
      expect(RepoMock, :get_activity, fn ["c1"] -> {:ok, %{"c1" => @p1}} end)
      expect(RepoMock, :mark_read, fn @me, "c1", @s1, _position -> :ok end)
      before = Position.floor(DateTime.utc_now())

      assert {:ok, up_to} = Unread.mark_read(@me, "c1", @id3)
      assert up_to >= before
      assert up_to <= Position.floor(DateTime.utc_now())
    end

    test "an unknown message never reads less than the last known message" do
      future = Position.of(DateTime.add(DateTime.utc_now(), 3_600, :second), @id2)
      stub_channel()
      stub_visible()
      expect(RepoMock, :find_position, fn "c1", @id3 -> {:ok, nil} end)
      expect(RepoMock, :get_activity, fn ["c1"] -> {:ok, %{"c1" => future}} end)
      expect(RepoMock, :mark_read, fn @me, "c1", @s1, ^future -> :ok end)

      assert Unread.mark_read(@me, "c1", @id3) == {:ok, future}
    end

    test "accepts any well formed id, such as the hashed ones sent with a client_id" do
      stub_channel()
      stub_visible()

      expect(RepoMock, :find_position, fn "c1", "00000000-0000-4000-8000-000000000001" ->
        {:ok, @p3}
      end)

      expect(RepoMock, :mark_read, fn @me, "c1", @s1, @p3 -> :ok end)

      assert Unread.mark_read(@me, "c1", "00000000-0000-4000-8000-000000000001") == {:ok, @p3}
    end

    test "a malformed message id is invalid" do
      for bad <- ["nope", "00000000-0000-4000-8000-00000000001", 5, %{}] do
        assert Unread.mark_read(@me, "c1", bad) == {:error, :invalid_payload}
      end
    end

    test "a blank message id means up to the last message" do
      stub_channel()
      stub_visible()
      expect(RepoMock, :get_activity, fn ["c1"] -> {:ok, %{"c1" => @p1}} end)
      expect(RepoMock, :mark_read, fn @me, "c1", @s1, @p1 -> :ok end)

      assert Unread.mark_read(@me, "c1", "") == {:ok, @p1}
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

    test "propagates a failure looking up the message" do
      stub_channel()
      stub_visible()
      expect(RepoMock, :find_position, fn "c1", @id1 -> {:error, :timeout} end)

      assert Unread.mark_read(@me, "c1", @id1) == {:error, :timeout}
    end
  end

  describe "mark_all_read/1" do
    test "CA2: marks every channel with unread content up to its last message" do
      stub_visible(["c1", "c2", "c3"])

      expect(RepoMock, :get_activity, fn ["c1", "c2", "c3"] ->
        {:ok, %{"c1" => @p3, "c2" => @p2, "c3" => @p1}}
      end)

      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{"c2" => @p2, "c3" => @p1}} end)

      expect(RepoMock, :mark_all_read, fn @me, entries ->
        assert entries == [%{channel_id: "c1", server_id: @s1, position: @p3}]
        :ok
      end)

      assert Unread.mark_all_read(@me) == {:ok, 1}
    end

    test "covers channels of every server and every kind of unread" do
      stub_visible(["c1", "c2"])
      expect(RepoMock, :get_activity, fn _ids -> {:ok, %{"c1" => @p2, "c2" => @p3}} end)
      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{"c1" => @p1}} end)

      expect(RepoMock, :mark_all_read, fn @me, entries ->
        assert Enum.sort_by(entries, & &1.channel_id) == [
                 %{channel_id: "c1", server_id: @s1, position: @p2},
                 %{channel_id: "c2", server_id: @s1, position: @p3}
               ]

        :ok
      end)

      assert Unread.mark_all_read(@me) == {:ok, 2}
    end

    test "does not write anything when nothing is unread" do
      stub_visible(["c1"])
      expect(RepoMock, :get_activity, fn _ids -> {:ok, %{"c1" => @p2}} end)
      expect(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, %{"c1" => @p3}} end)

      assert Unread.mark_all_read(@me) == {:ok, 0}
    end

    test "messages from before the member joined are not touched" do
      stub_visible(["c1"], joined: ~U[2026-10-01 00:00:00Z])
      expect(RepoMock, :get_activity, fn _ids -> {:ok, %{"c1" => @p3}} end)
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
      expect(RepoMock, :get_activity, fn _ids -> {:ok, %{"c1" => @p2}} end)
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
