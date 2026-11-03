defmodule Notifications.HistoryTest do
  use ExUnit.Case, async: false
  import Mox

  alias Notifications.History
  alias Notifications.Unread.RepoMock

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @s1 "s1"
  @c1 "c1"
  @m1 "00000000-0000-7000-8000-000000000001"
  @m2 "00000000-0000-7000-8000-000000000002"
  @m3 "00000000-0000-7000-8000-000000000003"
  @at ~U[2026-10-31 12:00:00.000000Z]
  @at_ms ~U[2026-10-31 12:00:00.000Z]

  defp mention_event(extra \\ %{}) do
    Map.merge(
      %{
        event_id: "e1",
        occurred_at: @at,
        server_id: @s1,
        channel_id: @c1,
        message_id: @m1,
        author_id: "author",
        mentioned_user_ids: ["u2"]
      },
      extra
    )
  end

  defp direct_event(extra \\ %{}) do
    Map.merge(
      %{
        event_id: "e1",
        occurred_at: @at,
        conversation_id: "conv-1",
        message_id: @m1,
        author_id: "author",
        recipient_id: "u2"
      },
      extra
    )
  end

  defp setting(user, scope, id, attrs),
    do:
      Map.merge(
        %{"user_id" => user, "scope" => scope, "scope_id" => id, "server_id" => @s1},
        attrs
      )

  defp expect_settings(users, docs),
    do: expect(RepoMock, :list_settings_for, fn ^users, [@c1, @s1] -> {:ok, docs} end)

  defp capture_history do
    test = self()
    expect(RepoMock, :put_history, fn items -> send(test, {:history, items}) && :ok end)
  end

  describe "sync_mentions/1" do
    defp expect_existing(users),
      do: expect(RepoMock, :list_history_mention_users, fn @m1 -> {:ok, users} end)

    test "adds the entry of whoever the edit mentioned for the first time" do
      expect_existing(["u2"])
      expect_settings(["u3"], [])
      capture_history()

      assert History.sync_mentions(mention_event(%{mentioned_user_ids: ["u2", "u3"]})) ==
               {:ok, ["u3"]}

      assert_received {:history, [item]}
      assert %{"_id" => "u3:" <> @m1, "kind" => "mention", "author_id" => "author"} = item
    end

    test "removes the entry of whoever the edit stopped mentioning, and keeps the rest" do
      expect_existing(["u2", "u3"])
      expect(RepoMock, :delete_history_entries, fn @m1, ["u3"] -> :ok end)

      assert History.sync_mentions(mention_event(%{mentioned_user_ids: ["u2"]})) == {:ok, []}
    end

    test "adds and removes in the same edit" do
      expect_existing(["u2"])
      expect(RepoMock, :delete_history_entries, fn @m1, ["u2"] -> :ok end)
      expect_settings(["u3"], [])
      capture_history()

      assert History.sync_mentions(mention_event(%{mentioned_user_ids: ["u3"]})) == {:ok, ["u3"]}
    end

    test "an edit that changes nothing touches nothing" do
      expect_existing(["u2"])

      assert History.sync_mentions(mention_event(%{mentioned_user_ids: ["u2"]})) == {:ok, []}
    end

    test "the author is never added" do
      expect_existing([])

      assert History.sync_mentions(mention_event(%{mentioned_user_ids: ["author"]})) == {:ok, []}
    end

    test "a muted channel or level none is not added, like when the message was created" do
      expect_existing([])

      expect_settings(["u2", "u3"], [
        %{"user_id" => "u2", "scope_id" => @c1, "muted" => true},
        %{"user_id" => "u3", "scope_id" => @s1, "level" => "none"}
      ])

      assert History.sync_mentions(mention_event(%{mentioned_user_ids: ["u2", "u3"]})) ==
               {:ok, []}
    end

    test "storage failures are returned" do
      expect(RepoMock, :list_history_mention_users, fn _id -> {:error, :timeout} end)
      assert History.sync_mentions(mention_event()) == {:error, :timeout}

      expect_existing(["u2"])
      expect(RepoMock, :delete_history_entries, fn _id, _users -> {:error, :timeout} end)

      assert History.sync_mentions(mention_event(%{mentioned_user_ids: []})) ==
               {:error, :timeout}

      expect_existing([])
      expect(RepoMock, :list_settings_for, fn _users, _scopes -> {:error, :timeout} end)
      assert History.sync_mentions(mention_event()) == {:error, :timeout}
    end
  end

  describe "forget/1" do
    test "removes every entry that points at the message" do
      expect(RepoMock, :delete_history_entries, fn @m1, :all -> :ok end)

      assert History.forget(@m1) == :ok
    end
  end

  describe "record_mentions/1" do
    test "CA1: stores one entry per mentioned user, with ids only and never the text" do
      expect_settings(["u2", "u3"], [])
      capture_history()

      assert History.record_mentions(mention_event(%{mentioned_user_ids: ["u2", "u3"]})) == :ok

      assert_received {:history, [first, second]}

      assert first == %{
               "_id" => "u2:" <> @m1,
               "user_id" => "u2",
               "kind" => "mention",
               "message_id" => @m1,
               "author_id" => "author",
               "server_id" => @s1,
               "channel_id" => @c1,
               "occurred_at" => @at
             }

      assert second["_id"] == "u3:" <> @m1
    end

    test "without a configured retention the entry never expires" do
      expect_settings(["u2"], [])
      capture_history()

      assert History.record_mentions(mention_event()) == :ok

      assert_received {:history, [item]}
      refute Map.has_key?(item, "expires_at")
    end

    test "a retention of zero days keeps the entry forever" do
      Application.put_env(:notifications, :history_retention_days, 0)
      on_exit(fn -> Application.delete_env(:notifications, :history_retention_days) end)
      expect_settings(["u2"], [])
      capture_history()

      assert History.record_mentions(mention_event()) == :ok

      assert_received {:history, [item]}
      refute Map.has_key?(item, "expires_at")
    end

    test "the retention comes from the configuration" do
      Application.put_env(:notifications, :history_retention_days, 2)
      on_exit(fn -> Application.delete_env(:notifications, :history_retention_days) end)
      expect_settings(["u2"], [])
      capture_history()

      assert History.record_mentions(mention_event()) == :ok

      assert_received {:history, [%{"expires_at" => expires_at}]}
      assert expires_at == DateTime.add(@at, 2 * 24 * 60 * 60, :second)
    end

    test "the author never gets an entry for their own message" do
      expect_settings(["u2"], [])
      capture_history()

      assert History.record_mentions(mention_event(%{mentioned_user_ids: ["author", "u2"]})) ==
               :ok

      assert_received {:history, [%{"user_id" => "u2"}]}
    end

    test "a message that mentions nobody, or only its author, touches nothing" do
      assert History.record_mentions(mention_event(%{mentioned_user_ids: []})) == :ok
      assert History.record_mentions(mention_event(%{mentioned_user_ids: ["author"]})) == :ok
    end

    test "CA1 (preferences): a muted channel leaves no entry" do
      expect_settings(["u2", "u3"], [
        setting("u2", "channel", @c1, %{"muted" => true})
      ])

      capture_history()

      assert History.record_mentions(mention_event(%{mentioned_user_ids: ["u2", "u3"]})) == :ok

      assert_received {:history, [%{"user_id" => "u3"}]}
    end

    test "a muted server leaves no entry" do
      expect_settings(["u2"], [setting("u2", "server", @s1, %{"muted" => true})])

      assert History.record_mentions(mention_event()) == :ok
    end

    test "level none on the server or on the channel leaves no entry" do
      expect_settings(["u2", "u3"], [
        setting("u2", "server", @s1, %{"level" => "none"}),
        setting("u3", "channel", @c1, %{"level" => "none"})
      ])

      assert History.record_mentions(mention_event(%{mentioned_user_ids: ["u2", "u3"]})) == :ok
    end

    test "the channel level wins over the server level" do
      expect_settings(["u2", "u3"], [
        setting("u2", "server", @s1, %{"level" => "none"}),
        setting("u2", "channel", @c1, %{"level" => "all"}),
        setting("u3", "server", @s1, %{"level" => "all"}),
        setting("u3", "channel", @c1, %{"level" => "none"})
      ])

      capture_history()

      assert History.record_mentions(mention_event(%{mentioned_user_ids: ["u2", "u3"]})) == :ok

      assert_received {:history, [%{"user_id" => "u2"}]}
    end

    test "levels all and mentions both keep the entry" do
      expect_settings(["u2", "u3"], [
        setting("u2", "server", @s1, %{"level" => "all"}),
        setting("u3", "server", @s1, %{"level" => "mentions"})
      ])

      capture_history()

      assert History.record_mentions(mention_event(%{mentioned_user_ids: ["u2", "u3"]})) == :ok

      assert_received {:history, [_one, _two]}
    end

    test "a mute still beats a more permissive level" do
      expect_settings(["u2"], [
        setting("u2", "server", @s1, %{"muted" => true}),
        setting("u2", "channel", @c1, %{"level" => "all"})
      ])

      assert History.record_mentions(mention_event()) == :ok
    end

    test "a failure reading the settings is returned" do
      expect(RepoMock, :list_settings_for, fn _users, _scopes -> {:error, :timeout} end)

      assert History.record_mentions(mention_event()) == {:error, :timeout}
    end

    test "a failure writing the history is returned" do
      expect_settings(["u2"], [])
      expect(RepoMock, :put_history, fn _items -> {:error, :timeout} end)

      assert History.record_mentions(mention_event()) == {:error, :timeout}
    end
  end

  describe "record_direct/1" do
    test "CA1: stores an entry for the recipient with the conversation" do
      capture_history()

      assert History.record_direct(direct_event()) == :ok

      assert_received {:history, [item]}

      assert item == %{
               "_id" => "u2:" <> @m1,
               "user_id" => "u2",
               "kind" => "direct_message",
               "message_id" => @m1,
               "author_id" => "author",
               "conversation_id" => "conv-1",
               "occurred_at" => @at
             }
    end

    test "a message to oneself leaves nothing" do
      assert History.record_direct(direct_event(%{recipient_id: "author"})) == :ok
    end

    test "a failure is returned" do
      expect(RepoMock, :put_history, fn _items -> {:error, :timeout} end)

      assert History.record_direct(direct_event()) == {:error, :timeout}
    end
  end

  describe "list/2" do
    defp doc(kind, message_id, attrs \\ %{}) do
      Map.merge(
        %{
          "user_id" => @me,
          "kind" => kind,
          "message_id" => message_id,
          "author_id" => "author",
          "occurred_at" => @at
        },
        attrs
      )
    end

    defp mention_doc(message_id, channel_id \\ @c1),
      do: doc("mention", message_id, %{"server_id" => @s1, "channel_id" => channel_id})

    defp dm_doc(message_id),
      do: doc("direct_message", message_id, %{"conversation_id" => "conv-1"})

    defp stub_visible(channel_ids) do
      stub(RepoMock, :list_memberships, fn @me ->
        {:ok,
         [
           %{
             "server_id" => @s1,
             "user_id" => @me,
             "role_ids" => ["everyone"],
             "joined_at" => ~U[1970-01-01 00:00:00Z]
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
        {:ok, Enum.map(channel_ids, &%{"_id" => &1, "server_id" => @s1, "kind" => "text"})}
      end)

      stub(RepoMock, :list_overrides, fn _ids -> {:ok, []} end)
    end

    test "CA2: with no activity the page is empty" do
      expect(RepoMock, :list_history, fn @me, nil, 50 -> {:ok, []} end)

      assert History.list(@me) == {:ok, %{items: [], next_cursor: nil}}
    end

    test "CA1: lists mentions and direct messages as the repository ordered them, with ids to open each conversation" do
      stub_visible([@c1])

      expect(RepoMock, :list_history, fn @me, nil, 50 ->
        {:ok, [mention_doc(@m3), dm_doc(@m2)]}
      end)

      assert {:ok, %{items: [mention, direct], next_cursor: nil}} = History.list(@me)

      assert mention == %{
               "kind" => "mention",
               "message_id" => @m3,
               "author_id" => "author",
               "occurred_at" => "2026-10-31T12:00:00.000000Z",
               "server_id" => @s1,
               "channel_id" => @c1,
               "conversation_id" => nil
             }

      assert direct == %{
               "kind" => "direct_message",
               "message_id" => @m2,
               "author_id" => "author",
               "occurred_at" => "2026-10-31T12:00:00.000000Z",
               "server_id" => nil,
               "channel_id" => nil,
               "conversation_id" => "conv-1"
             }
    end

    test "only direct messages: permissions are not even consulted" do
      expect(RepoMock, :list_history, fn @me, nil, 50 -> {:ok, [dm_doc(@m2)]} end)

      assert {:ok, %{items: [%{"kind" => "direct_message"}]}} = History.list(@me)
    end

    test "mentions of channels the user can no longer see are hidden" do
      stub_visible([@c1])

      expect(RepoMock, :list_history, fn @me, nil, 50 ->
        {:ok, [mention_doc(@m3, "hidden"), mention_doc(@m2), dm_doc(@m1)]}
      end)

      assert {:ok, %{items: items}} = History.list(@me)
      assert Enum.map(items, & &1["message_id"]) == [@m2, @m1]
    end

    test "passes the position and the limit to the repository" do
      expect(RepoMock, :list_history, fn @me, {@at, @m3}, 2 -> {:ok, []} end)

      assert History.list(@me, before: {@at, @m3}, limit: 2) ==
               {:ok, %{items: [], next_cursor: nil}}
    end

    test "a full page offers the next cursor, even if some entries were hidden" do
      stub_visible([@c1])

      expect(RepoMock, :list_history, fn @me, nil, 2 ->
        {:ok, [mention_doc(@m3, "hidden"), dm_doc(@m2)]}
      end)

      assert {:ok, %{items: [_one], next_cursor: cursor}} = History.list(@me, limit: 2)
      assert cursor == "#{DateTime.to_unix(@at, :millisecond)}_#{@m2}"
    end

    test "the cursor works for ids that are not time ordered" do
      stub_visible([@c1])
      hashed = "e0e2b4f0-3518-5818-8e3b-09c951ebb2bd"

      expect(RepoMock, :list_history, fn @me, nil, 1 -> {:ok, [dm_doc(hashed)]} end)

      assert {:ok, %{next_cursor: cursor}} = History.list(@me, limit: 1)
      assert History.decode_cursor(cursor) == {:ok, {@at_ms, hashed}}
    end

    test "a page shorter than the limit has no next cursor" do
      expect(RepoMock, :list_history, fn @me, nil, 5 -> {:ok, [dm_doc(@m2)]} end)

      assert {:ok, %{next_cursor: nil}} = History.list(@me, limit: 5)
    end

    test "a failure reading the history is returned" do
      expect(RepoMock, :list_history, fn _user, _before, _limit -> {:error, :timeout} end)

      assert History.list(@me) == {:error, :timeout}
    end

    test "a failure reading the permissions is returned" do
      expect(RepoMock, :list_history, fn _user, _before, _limit -> {:ok, [mention_doc(@m1)]} end)
      stub(RepoMock, :list_memberships, fn @me -> {:error, :timeout} end)

      assert History.list(@me) == {:error, :timeout}
    end
  end

  describe "decode_cursor/1" do
    @hashed "e0e2b4f0-3518-5818-8e3b-09c951ebb2bd"

    test "reads the date and the id back" do
      millis = DateTime.to_unix(@at, :millisecond)

      assert History.decode_cursor("#{millis}_#{@m1}") ==
               {:ok, {~U[2026-10-31 12:00:00.000Z], @m1}}
    end

    test "accepts ids of any version" do
      assert {:ok, {_at, @hashed}} = History.decode_cursor("1761912000000_#{@hashed}")
    end

    test "accepts the start of the epoch" do
      assert {:ok, {~U[1970-01-01 00:00:00.000Z], @m1}} = History.decode_cursor("0_#{@m1}")
    end

    for bad <- [
          "",
          "nope",
          "1761912000000",
          "1761912000000_",
          "1761912000000_nope",
          "abc_00000000-0000-7000-8000-000000000001",
          "-5_00000000-0000-7000-8000-000000000001",
          "12.5_00000000-0000-7000-8000-000000000001",
          "00000000-0000-7000-8000-000000000001",
          "99999999999999999999_00000000-0000-7000-8000-000000000001"
        ] do
      test "rejects #{inspect(bad)}" do
        assert History.decode_cursor(unquote(bad)) == :error
      end
    end

    test "rejects anything that is not a string" do
      for bad <- [nil, 123, %{}, ["1_x"]], do: assert(History.decode_cursor(bad) == :error)
    end
  end
end
