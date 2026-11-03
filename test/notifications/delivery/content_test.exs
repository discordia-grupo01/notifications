defmodule Notifications.Delivery.ContentTest do
  use ExUnit.Case, async: true
  import Mox

  alias Notifications.Delivery.{Content, RepoMock}
  alias Notifications.Events.Event
  alias Notifications.Unread.RepoMock, as: UnreadRepoMock

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp channel_event(extra \\ %{}) do
    struct!(
      Event.MessageCreated,
      Map.merge(
        %{
          event_id: "e1",
          occurred_at: DateTime.utc_now(),
          server_id: "s1",
          channel_id: "c1",
          message_id: "m1",
          author_id: "u1",
          mentioned_user_ids: [],
          channel_name: "general",
          content_preview: "hola a todos"
        },
        extra
      )
    )
  end

  defp direct_event(extra \\ %{}) do
    struct!(
      Event.DirectMessageCreated,
      Map.merge(
        %{
          event_id: "e1",
          occurred_at: DateTime.utc_now(),
          conversation_id: "conv-1",
          message_id: "m1",
          author_id: "u1",
          recipient_id: "u2",
          content_preview: "hola"
        },
        extra
      )
    )
  end

  test "a channel message reads Server - Channel and Name: text" do
    expect(RepoMock, :get_user_names, fn ["u1"] -> {:ok, %{"u1" => "Ana"}} end)
    expect(RepoMock, :get_server_names, fn ["s1"] -> {:ok, %{"s1" => "Mi server"}} end)

    assert Content.build(channel_event()) ==
             {:ok,
              %{
                title: "Mi server - general",
                body: "Ana: hola a todos",
                data: %{
                  "server_id" => "s1",
                  "channel_id" => "c1",
                  "message_id" => "m1",
                  "author_id" => "u1"
                }
              }}
  end

  test "an edit that added a mention says it was edited" do
    expect(RepoMock, :get_user_names, fn ["u1"] -> {:ok, %{"u1" => "Ana"}} end)
    expect(RepoMock, :get_server_names, fn ["s1"] -> {:ok, %{"s1" => "Mi server"}} end)

    event =
      struct!(Event.MessageUpdated, %{
        event_id: "e2",
        occurred_at: DateTime.utc_now(),
        server_id: "s1",
        channel_id: "c1",
        message_id: "m1",
        author_id: "u1",
        mentioned_user_ids: ["u2"],
        channel_name: "general",
        content_preview: "hola @usuario"
      })

    assert {:ok, content} = Content.build(event)
    assert content.title == "Mi server - general"
    assert content.body == "Ana: hola @usuario (editado)"
    assert content.data["edited"] == true
    assert content.data["message_id"] == "m1"
  end

  test "a direct message reads Mensaje directo and Name: text" do
    expect(RepoMock, :get_user_names, fn ["u1"] -> {:ok, %{"u1" => "Ana"}} end)

    assert Content.build(direct_event()) ==
             {:ok,
              %{
                title: "Mensaje directo",
                body: "Ana: hola",
                data: %{"conversation_id" => "conv-1", "message_id" => "m1", "author_id" => "u1"}
              }}
  end

  test "names that were never received fall back to generic ones" do
    expect(RepoMock, :get_user_names, fn _ids -> {:ok, %{}} end)
    expect(RepoMock, :get_server_names, fn _ids -> {:ok, %{}} end)

    assert {:ok, %{title: "Servidor - general", body: "Usuario: hola a todos"}} =
             Content.build(channel_event())
  end

  test "without a preview the body still says there is a new message" do
    expect(RepoMock, :get_user_names, fn _ids -> {:ok, %{"u1" => "Ana"}} end)

    assert {:ok, %{body: "Ana: Nuevo mensaje"}} =
             Content.build(direct_event(%{content_preview: nil}))
  end

  test "a channel name missing from the event comes from the local replica" do
    expect(RepoMock, :get_user_names, fn _ids -> {:ok, %{"u1" => "Ana"}} end)
    expect(RepoMock, :get_server_names, fn _ids -> {:ok, %{"s1" => "Mi server"}} end)
    expect(UnreadRepoMock, :get_channel, fn "c1" -> %{"name" => "anuncios"} end)

    assert {:ok, %{title: "Mi server - anuncios"}} =
             Content.build(channel_event(%{channel_name: nil}))
  end

  test "a channel known by nobody is just a channel" do
    expect(RepoMock, :get_user_names, fn _ids -> {:ok, %{"u1" => "Ana"}} end)
    expect(RepoMock, :get_server_names, fn _ids -> {:ok, %{"s1" => "Mi server"}} end)
    expect(UnreadRepoMock, :get_channel, fn "c1" -> nil end)

    assert {:ok, %{title: "Mi server - canal"}} =
             Content.build(channel_event(%{channel_name: nil}))
  end

  test "storage failures are returned" do
    expect(RepoMock, :get_user_names, fn _ids -> {:error, :timeout} end)
    assert Content.build(direct_event()) == {:error, :timeout}

    expect(RepoMock, :get_user_names, fn _ids -> {:ok, %{}} end)
    expect(RepoMock, :get_server_names, fn _ids -> {:error, :timeout} end)
    assert Content.build(channel_event()) == {:error, :timeout}

    expect(RepoMock, :get_user_names, fn _ids -> {:ok, %{}} end)
    expect(RepoMock, :get_server_names, fn _ids -> {:ok, %{}} end)
    expect(UnreadRepoMock, :get_channel, fn _id -> {:error, :timeout} end)
    assert Content.build(channel_event(%{channel_name: nil})) == {:error, :timeout}
  end
end
