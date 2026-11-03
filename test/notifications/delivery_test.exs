defmodule Notifications.DeliveryTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import Mox
  import Notifications.DeliveryHelpers

  alias Notifications.Delivery
  alias Notifications.Delivery.{RepoMock, SenderMock}
  alias Notifications.Events.Event
  alias Notifications.Unread.RepoMock, as: UnreadRepoMock

  setup :set_mox_global
  setup :verify_on_exit!

  defp direct(extra \\ %{}) do
    struct!(
      Event.DirectMessageCreated,
      Map.merge(
        %{
          event_id: "e1",
          occurred_at: DateTime.utc_now(),
          conversation_id: "conv-1",
          message_id: "m1",
          author_id: "ana",
          recipient_id: "beto",
          content_preview: "hola"
        },
        extra
      )
    )
  end

  defp channel(extra \\ %{}) do
    struct!(
      Event.MessageCreated,
      Map.merge(
        %{
          event_id: "e2",
          occurred_at: DateTime.utc_now(),
          server_id: "s1",
          channel_id: "c1",
          message_id: "m2",
          author_id: "ana",
          mentioned_user_ids: ["beto"],
          channel_name: "general",
          content_preview: "@usuario mirá esto"
        },
        extra
      )
    )
  end

  defp device(user_id, id \\ "d1"),
    do: %{"_id" => id, "user_id" => user_id, "provider" => "expo"}

  defp reachable(user_id) do
    expect(RepoMock, :list_push_disabled, fn _ids -> {:ok, []} end)
    expect(RepoMock, :get_presence, fn _ids -> {:ok, %{}} end)
    expect(RepoMock, :list_devices, fn [^user_id] -> {:ok, [device(user_id)]} end)
  end

  test "a direct message becomes a push to the recipient's device" do
    test_pid = self()
    reachable("beto")
    stub(RepoMock, :get_user_names, fn ["ana"] -> {:ok, %{"ana" => "Ana"}} end)
    stub(RepoMock, :claim_delivery, fn "e1", "d1", _at -> :claimed end)
    stub(RepoMock, :mark_device, fn _id, _outcome -> :ok end)

    stub(SenderMock, :send, fn device, payload ->
      send(test_pid, {:push, device["user_id"], payload})
      :ok
    end)

    assert Delivery.notify(direct()) == :ok
    await_deliveries()

    assert_received {:push, "beto", payload}
    assert payload.title == "Mensaje directo"
    assert payload.body == "Ana: hola"

    assert payload.data == %{
             "kind" => "direct_message",
             "conversation_id" => "conv-1",
             "message_id" => "m1",
             "author_id" => "ana"
           }
  end

  test "a mention in a channel becomes a push titled Server - Channel" do
    test_pid = self()
    expect(UnreadRepoMock, :list_settings_by_scope, fn ["c1", "s1"] -> {:ok, []} end)
    reachable("beto")
    stub(RepoMock, :get_user_names, fn _ids -> {:ok, %{"ana" => "Ana"}} end)
    stub(RepoMock, :get_server_names, fn _ids -> {:ok, %{"s1" => "Mi server"}} end)
    stub(RepoMock, :claim_delivery, fn _e, _d, _at -> :claimed end)
    stub(RepoMock, :mark_device, fn _id, _outcome -> :ok end)

    stub(SenderMock, :send, fn _device, payload ->
      send(test_pid, {:push, payload})
      :ok
    end)

    assert Delivery.notify(channel()) == :ok
    await_deliveries()

    assert_received {:push, payload}
    assert payload.title == "Mi server - general"
    assert payload.body == "Ana: @usuario mirá esto"
    assert payload.data["kind"] == "mention"
    assert payload.data["channel_id"] == "c1"
  end

  test "nobody to notify means nothing is queried and nothing is sent" do
    expect(UnreadRepoMock, :list_settings_by_scope, fn _scopes -> {:ok, []} end)

    assert Delivery.notify(channel(%{mentioned_user_ids: []})) == :ok
    assert Delivery.notify(direct(%{recipient_id: "ana"})) == :ok
  end

  test "whoever has the app open, do not disturb or push off is not reached" do
    expect(RepoMock, :list_push_disabled, fn _ids -> {:ok, []} end)

    expect(RepoMock, :get_presence, fn _ids ->
      {:ok,
       %{
         "beto" => %{
           connections: "active",
           do_not_disturb: false,
           expires_at: DateTime.add(DateTime.utc_now(), 3600)
         }
       }}
    end)

    assert Delivery.notify(direct()) == :ok

    expect(RepoMock, :list_push_disabled, fn _ids -> {:ok, ["beto"]} end)
    expect(RepoMock, :get_presence, fn _ids -> {:ok, %{}} end)

    assert Delivery.notify(direct(%{event_id: "e9"})) == :ok
  end

  test "a user without devices costs no lookup of names" do
    expect(RepoMock, :list_push_disabled, fn _ids -> {:ok, []} end)
    expect(RepoMock, :get_presence, fn _ids -> {:ok, %{}} end)
    expect(RepoMock, :list_devices, fn _ids -> {:ok, []} end)

    assert Delivery.notify(direct()) == :ok
  end

  test "each device of the user gets its own push, and kinds are kept per user" do
    test_pid = self()
    expect(UnreadRepoMock, :list_settings_by_scope, fn _scopes -> {:ok, []} end)
    expect(RepoMock, :list_push_disabled, fn _ids -> {:ok, []} end)
    expect(RepoMock, :get_presence, fn _ids -> {:ok, %{}} end)

    expect(RepoMock, :list_devices, fn ["beto", "carla"] ->
      {:ok, [device("beto", "d1"), device("beto", "d2"), device("carla", "d3")]}
    end)

    stub(RepoMock, :get_user_names, fn _ids -> {:ok, %{}} end)
    stub(RepoMock, :get_server_names, fn _ids -> {:ok, %{}} end)
    stub(RepoMock, :claim_delivery, fn _e, _d, _at -> :claimed end)
    stub(RepoMock, :mark_device, fn _id, _outcome -> :ok end)

    stub(SenderMock, :send, fn device, _payload ->
      send(test_pid, {:sent, device["_id"]})
      :ok
    end)

    assert Delivery.notify(channel(%{mentioned_user_ids: ["beto", "carla"]})) == :ok
    await_deliveries()

    for id <- ["d1", "d2", "d3"], do: assert_received({:sent, ^id})
  end

  test "a failure while preparing the push is logged and never raised" do
    expect(RepoMock, :list_push_disabled, fn _ids -> {:error, :timeout} end)

    log = capture_log(fn -> assert Delivery.notify(direct()) == :ok end)
    assert log =~ "push_skipped"
    refute log =~ "hola"
  end

  test "an unexpected exception is logged and never raised" do
    expect(RepoMock, :list_push_disabled, fn _ids -> raise "boom" end)

    log = capture_log(fn -> assert Delivery.notify(direct()) == :ok end)
    assert log =~ "push_skipped"
  end

  describe "notify_edit/2" do
    defp edit_event do
      struct!(Event.MessageUpdated, %{
        event_id: "e3",
        occurred_at: DateTime.utc_now(),
        server_id: "s1",
        channel_id: "c1",
        message_id: "m2",
        author_id: "ana",
        mentioned_user_ids: ["beto"],
        channel_name: "general",
        content_preview: "ahora con mención"
      })
    end

    test "pushes only the newly mentioned user, marked as edited" do
      test_pid = self()
      reachable("beto")
      stub(RepoMock, :get_user_names, fn _ids -> {:ok, %{"ana" => "Ana"}} end)
      stub(RepoMock, :get_server_names, fn _ids -> {:ok, %{"s1" => "Mi server"}} end)
      stub(RepoMock, :claim_delivery, fn "e3", "d1", _at -> :claimed end)
      stub(RepoMock, :mark_device, fn _id, _outcome -> :ok end)

      stub(SenderMock, :send, fn _device, payload ->
        send(test_pid, {:push, payload})
        :ok
      end)

      assert Delivery.notify_edit(edit_event(), ["beto"]) == :ok
      await_deliveries()

      assert_received {:push, payload}
      assert payload.body == "Ana: ahora con mención (editado)"
      assert payload.data["kind"] == "mention"
      assert payload.data["edited"] == true
    end

    test "nobody newly mentioned means nothing is queried" do
      assert Delivery.notify_edit(edit_event(), []) == :ok
    end

    test "a failure is logged and never raised" do
      expect(RepoMock, :list_push_disabled, fn _ids -> {:error, :timeout} end)

      log = capture_log(fn -> assert Delivery.notify_edit(edit_event(), ["beto"]) == :ok end)
      assert log =~ "push_skipped"

      expect(RepoMock, :list_push_disabled, fn _ids -> raise "boom" end)

      log = capture_log(fn -> assert Delivery.notify_edit(edit_event(), ["beto"]) == :ok end)
      assert log =~ "push_skipped"
    end
  end
end
