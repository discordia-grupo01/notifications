defmodule Notifications.Delivery.RecipientsTest do
  use ExUnit.Case, async: true
  import Mox

  alias Notifications.Delivery.Recipients
  alias Notifications.Events.Event
  alias Notifications.Unread.RepoMock

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp event(extra \\ %{}) do
    struct!(
      Event.MessageCreated,
      Map.merge(
        %{
          event_id: "e1",
          occurred_at: ~U[2026-10-23 12:00:00Z],
          server_id: "s1",
          channel_id: "c1",
          message_id: "m1",
          author_id: "author",
          mentioned_user_ids: []
        },
        extra
      )
    )
  end

  defp setting(user_id, scope, scope_id, fields),
    do:
      Map.merge(
        %{
          "user_id" => user_id,
          "scope" => scope,
          "scope_id" => scope_id,
          "server_id" => "s1",
          "muted" => false,
          "level" => nil
        },
        fields
      )

  defp settings(docs),
    do: expect(RepoMock, :list_settings_by_scope, fn ["c1", "s1"] -> {:ok, docs} end)

  defp can_view(user_ids) do
    stub(RepoMock, :list_memberships, fn user_id ->
      {:ok,
       if(user_id in user_ids,
         do: [%{"server_id" => "s1", "user_id" => user_id, "role_ids" => ["everyone"]}],
         else: []
       )}
    end)

    stub(RepoMock, :get_server_owners, fn _ids -> {:ok, %{}} end)

    stub(RepoMock, :list_roles, fn _ids ->
      {:ok,
       [
         %{
           "_id" => "everyone",
           "server_id" => "s1",
           "permissions" => ["VIEW_CHANNELS"],
           "is_everyone" => true
         }
       ]}
    end)

    stub(RepoMock, :list_channels, fn _ids ->
      {:ok, [%{"_id" => "c1", "server_id" => "s1", "kind" => "text"}]}
    end)

    stub(RepoMock, :list_overrides, fn _ids -> {:ok, []} end)
  end

  describe "a message in a channel" do
    test "nobody is notified by default when nobody is mentioned" do
      settings([])

      assert Recipients.for_channel_message(event()) == {:ok, %{}}
    end

    test "a mention notifies the mentioned user by default" do
      settings([])

      assert Recipients.for_channel_message(event(%{mentioned_user_ids: ["u2"]})) ==
               {:ok, %{"u2" => :mention}}
    end

    test "the author is never notified of their own mention" do
      settings([])

      assert Recipients.for_channel_message(event(%{mentioned_user_ids: ["author", "u2"]})) ==
               {:ok, %{"u2" => :mention}}
    end

    test "a muted channel or server and the level none silence a mention" do
      settings([
        setting("u2", "channel", "c1", %{"muted" => true}),
        setting("u3", "server", "s1", %{"muted" => true}),
        setting("u4", "channel", "c1", %{"level" => "none"}),
        setting("u5", "server", "s1", %{"level" => "none"})
      ])

      assert Recipients.for_channel_message(
               event(%{mentioned_user_ids: ["u2", "u3", "u4", "u5", "u6"]})
             ) == {:ok, %{"u6" => :mention}}
    end

    test "a channel preference wins over the server's, and muting always wins" do
      settings([
        setting("u2", "server", "s1", %{"level" => "none"}),
        setting("u2", "channel", "c1", %{"level" => "mentions"}),
        setting("u3", "server", "s1", %{"muted" => true}),
        setting("u3", "channel", "c1", %{"level" => "all"})
      ])

      assert Recipients.for_channel_message(event(%{mentioned_user_ids: ["u2", "u3"]})) ==
               {:ok, %{"u2" => :mention}}
    end

    test "whoever chose all messages is notified of a plain message" do
      settings([
        setting("u2", "channel", "c1", %{"level" => "all"}),
        setting("u3", "server", "s1", %{"level" => "all"}),
        setting("u4", "server", "s1", %{"level" => "mentions"})
      ])

      can_view(["u2", "u3", "u4"])

      assert Recipients.for_channel_message(event()) ==
               {:ok, %{"u2" => :message, "u3" => :message}}
    end

    test "all messages is not applied to the author, nor to a muted scope" do
      settings([
        setting("author", "channel", "c1", %{"level" => "all"}),
        setting("u2", "channel", "c1", %{"level" => "all", "muted" => true}),
        setting("u3", "server", "s1", %{"level" => "all", "muted" => true})
      ])

      can_view(["author", "u2", "u3"])

      assert Recipients.for_channel_message(event()) == {:ok, %{}}
    end

    test "whoever chose all messages but can no longer see the channel is skipped" do
      settings([
        setting("u2", "channel", "c1", %{"level" => "all"}),
        setting("u3", "channel", "c1", %{"level" => "all"})
      ])

      can_view(["u3"])

      assert Recipients.for_channel_message(event()) == {:ok, %{"u3" => :message}}
    end

    test "a user with all messages who is also mentioned is told it is a mention" do
      settings([setting("u2", "channel", "c1", %{"level" => "all"})])
      can_view(["u2"])

      assert Recipients.for_channel_message(event(%{mentioned_user_ids: ["u2"]})) ==
               {:ok, %{"u2" => :mention}}
    end

    test "a storage failure is returned" do
      expect(RepoMock, :list_settings_by_scope, fn _scopes -> {:error, :timeout} end)

      assert Recipients.for_channel_message(event()) == {:error, :timeout}
    end

    test "a failure while checking access is returned" do
      settings([setting("u2", "channel", "c1", %{"level" => "all"})])
      stub(RepoMock, :list_memberships, fn _user_id -> {:error, :timeout} end)

      assert Recipients.for_channel_message(event()) == {:error, :timeout}
    end

    test "a channel that disappeared leaves nobody to notify" do
      settings([setting("u2", "channel", "c1", %{"level" => "all"})])
      can_view(["u2"])
      stub(RepoMock, :list_channels, fn _ids -> {:ok, []} end)

      assert Recipients.for_channel_message(event()) == {:ok, %{}}
    end
  end

  describe "a direct message" do
    test "the recipient is always notified" do
      event = %Event.DirectMessageCreated{
        event_id: "e1",
        occurred_at: DateTime.utc_now(),
        conversation_id: "conv",
        message_id: "m1",
        author_id: "a",
        recipient_id: "b"
      }

      assert Recipients.for_direct_message(event) == {:ok, %{"b" => :direct}}
    end

    test "a message to oneself notifies nobody" do
      event = %Event.DirectMessageCreated{
        event_id: "e1",
        occurred_at: DateTime.utc_now(),
        conversation_id: "conv",
        message_id: "m1",
        author_id: "a",
        recipient_id: "a"
      }

      assert Recipients.for_direct_message(event) == {:ok, %{}}
    end
  end
end
