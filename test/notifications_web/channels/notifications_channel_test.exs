defmodule NotificationsWeb.NotificationsChannelTest do
  use NotificationsWeb.ChannelCase, async: false
  import Mox

  alias Notifications.Auth.TicketStoreMock
  alias Notifications.AuthFixtures
  alias Notifications.Unread.RepoMock
  alias NotificationsWeb.{Endpoint, NotificationsChannel, UserSocket}

  setup :set_mox_global
  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"
  @s1 "server-1"
  @c1 "channel-1"
  @c2 "channel-2"
  @m1 "00000000-0000-7000-8000-000000000001"
  @m2 "00000000-0000-7000-8000-000000000002"
  @m3 "00000000-0000-7000-8000-000000000003"

  setup do
    {:ok, world} =
      Agent.start_link(fn ->
        %{channels: [@c1, @c2], activity: %{}, reads: %{}, mutes: []}
      end)

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
      channels = Agent.get(world, & &1.channels)
      {:ok, Enum.map(channels, &%{"_id" => &1, "server_id" => @s1, "kind" => "text"})}
    end)

    stub(RepoMock, :list_overrides, fn _ids -> {:ok, []} end)
    stub(RepoMock, :list_settings, fn @me -> {:ok, Agent.get(world, & &1.mutes)} end)
    stub(RepoMock, :get_activity, fn _ids -> {:ok, Agent.get(world, & &1.activity)} end)
    stub(RepoMock, :get_read_markers, fn @me, _ids -> {:ok, Agent.get(world, & &1.reads)} end)
    stub(RepoMock, :get_mention_markers, fn @me, _ids -> {:ok, %{}} end)

    stub(RepoMock, :get_channel, fn id ->
      if id in Agent.get(world, & &1.channels),
        do: %{"_id" => id, "server_id" => @s1, "kind" => "text"},
        else: nil
    end)

    {:ok, world: world}
  end

  defp put_world(world, key, value), do: Agent.update(world, &Map.put(&1, key, value))

  defp socket_for(user_id) do
    stub(TicketStoreMock, :take, fn _id -> {:ok, AuthFixtures.ticket_doc(user_id)} end)
    {:ok, socket} = connect(UserSocket, %{"ticket" => "a-ticket"})
    socket
  end

  defp join_own(user_id \\ @me) do
    {:ok, _reply, socket} =
      subscribe_and_join(socket_for(user_id), NotificationsChannel, "notifications:" <> user_id)

    socket
  end

  defp message_created(channel_id, message_id, opts \\ []) do
    Endpoint.broadcast("server:" <> @s1, "message_created", %{
      "server_id" => @s1,
      "channel_id" => channel_id,
      "message_id" => message_id,
      "author_id" => Keyword.get(opts, :author, @other),
      "mentioned_user_ids" => Keyword.get(opts, :mentions, [])
    })
  end

  describe "join" do
    test "a user joins their own topic" do
      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket_for(@me), NotificationsChannel, "notifications:" <> @me)
    end

    test "nobody can listen to another user's notifications" do
      assert {:error, %{error: %{code: "FORBIDDEN"}}} =
               subscribe_and_join(
                 socket_for(@me),
                 NotificationsChannel,
                 "notifications:" <> @other
               )
    end

    test "CA1/CA2: pushes the unread snapshot right after joining", %{world: world} do
      put_world(world, :activity, %{@c1 => @m2})
      put_world(world, :reads, %{@c1 => @m1})
      join_own()

      assert_push "snapshot", %{
        "servers" => [
          %{
            "server_id" => @s1,
            "unread" => true,
            "mention" => false,
            "channels" => [%{"channel_id" => @c1, "unread" => true, "mention" => false}]
          }
        ]
      }
    end

    test "the snapshot is empty when everything is read" do
      join_own()

      assert_push "snapshot", %{"servers" => []}
    end
  end

  describe "live updates" do
    test "CA1/CA2: a new message in a channel marks the channel and its server unread" do
      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1)

      assert_push "unread_updated", %{
        "server_id" => @s1,
        "channel_id" => @c1,
        "unread" => true,
        "mention" => false,
        "server" => %{"unread" => true, "mention" => false}
      }
    end

    test "CA3: a message that mentions the user is pushed as a mention" do
      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1, mentions: [@me])

      assert_push "unread_updated", %{
        "channel_id" => @c1,
        "unread" => true,
        "mention" => true,
        "server" => %{"unread" => true, "mention" => true}
      }
    end

    test "a message that mentions someone else is not a mention" do
      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1, mentions: [@other])

      assert_push "unread_updated", %{"mention" => false, "unread" => true}
    end

    test "the user's own message produces no notification" do
      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1, author: @me)

      refute_push "unread_updated", _
    end

    test "a second message in an already unread channel produces no new push" do
      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1)
      assert_push "unread_updated", _
      message_created(@c1, @m2)

      refute_push "unread_updated", _
    end

    test "a later mention in an already unread channel is pushed because the flags changed" do
      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1)
      assert_push "unread_updated", %{"mention" => false}
      message_created(@c1, @m2, mentions: [@me])

      assert_push "unread_updated", %{"mention" => true}
    end

    test "messages from channels the user cannot see are ignored" do
      join_own()
      assert_push "snapshot", _

      message_created("hidden-channel", @m1)

      refute_push "unread_updated", _
    end

    test "the server stays unread while any of its channels is" do
      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1)
      assert_push "unread_updated", _
      message_created(@c2, @m2)
      assert_push "unread_updated", %{"channel_id" => @c2}
    end
  end

  describe "muted" do
    test "CA1: the snapshot keeps a muted channel unread and lists what is muted", %{world: world} do
      put_world(world, :activity, %{@c1 => @m1})

      put_world(world, :mutes, [
        %{"scope" => "channel", "scope_id" => @c1, "server_id" => @s1, "muted" => true}
      ])

      join_own()

      assert_push "snapshot", %{
        "servers" => [
          %{
            "unread" => true,
            "mention" => false,
            "muted" => false,
            "channels" => [%{"channel_id" => @c1, "unread" => true, "muted" => true}]
          }
        ],
        "muted" => %{"servers" => [], "channels" => [@c1]}
      }
    end

    test "CA1: a mention in a muted channel is unread activity without highlight", %{world: world} do
      put_world(world, :mutes, [
        %{"scope" => "channel", "scope_id" => @c1, "server_id" => @s1, "muted" => true}
      ])

      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1, mentions: [@me])

      assert_push "unread_updated", %{
        "channel_id" => @c1,
        "unread" => true,
        "mention" => false,
        "muted" => true,
        "server" => %{"unread" => true, "mention" => false, "muted" => false}
      }
    end

    test "CA2: no channel of a muted server is highlighted", %{world: world} do
      put_world(world, :mutes, [
        %{"scope" => "server", "scope_id" => @s1, "server_id" => @s1, "muted" => true}
      ])

      join_own()
      assert_push "snapshot", %{"muted" => %{"servers" => [@s1], "channels" => []}}

      message_created(@c1, @m1, mentions: [@me])
      assert_push "unread_updated", %{"channel_id" => @c1, "mention" => false, "muted" => true}

      message_created(@c2, @m2, mentions: [@me])

      assert_push "unread_updated", %{
        "channel_id" => @c2,
        "mention" => false,
        "server" => %{"unread" => true, "mention" => false, "muted" => true}
      }
    end

    test "muting from another session reaches this one through a resync", %{world: world} do
      stub(RepoMock, :put_setting, fn @me, :channel, @c1, @s1, %{muted: true} ->
        put_world(world, :mutes, [
          %{"scope" => "channel", "scope_id" => @c1, "server_id" => @s1, "muted" => true}
        ])

        :ok
      end)

      stub(RepoMock, :get_setting, fn @me, @c1 ->
        %{"scope_id" => @c1, "muted" => true, "level" => nil}
      end)

      join_own()
      assert_push "snapshot", %{"muted" => %{"channels" => []}}

      assert {:ok, %{muted: true}} =
               Notifications.Settings.update_channel(@me, @c1, %{muted: true})

      assert_push "snapshot", %{"muted" => %{"channels" => [@c1]}}
    end

    test "CA3: after unmuting, the next mention is highlighted again", %{world: world} do
      put_world(world, :mutes, [
        %{"scope" => "channel", "scope_id" => @c1, "server_id" => @s1, "muted" => true}
      ])

      stub(RepoMock, :put_setting, fn @me, :channel, @c1, nil, %{muted: false} ->
        put_world(world, :mutes, [])
      end)

      stub(RepoMock, :get_setting, fn @me, @c1 -> nil end)
      join_own()
      assert_push "snapshot", %{"muted" => %{"channels" => [@c1]}}

      assert {:ok, %{muted: false}} =
               Notifications.Settings.update_channel(@me, @c1, %{muted: false})

      assert_push "snapshot", %{"muted" => %{"channels" => []}}

      message_created(@c1, @m1, mentions: [@me])

      assert_push "unread_updated", %{"channel_id" => @c1, "mention" => true, "muted" => false}
    end
  end

  describe "preferences" do
    defp level_doc(scope, id, level),
      do: %{"scope" => scope, "scope_id" => id, "server_id" => @s1, "level" => level}

    test "the snapshot lists the stored preferences", %{world: world} do
      put_world(world, :mutes, [
        level_doc("server", @s1, "none"),
        level_doc("channel", @c2, "all")
      ])

      join_own()

      assert_push "snapshot", %{
        "preferences" => %{"servers" => %{@s1 => "none"}, "channels" => %{@c2 => "all"}}
      }
    end

    test "CA1: with the default level only mentions notify" do
      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1)
      assert_push "unread_updated", %{"unread" => true, "mention" => false, "notify" => false}

      message_created(@c1, @m2, mentions: [@me])
      assert_push "unread_updated", %{"mention" => true, "notify" => true}
    end

    test "CA1: level all makes every message notify, still without faking a mention", %{
      world: world
    } do
      put_world(world, :mutes, [level_doc("server", @s1, "all")])
      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1)

      assert_push "unread_updated", %{
        "channel_id" => @c1,
        "unread" => true,
        "mention" => false,
        "notify" => true,
        "muted" => false,
        "server" => %{"notify" => true}
      }
    end

    test "CA1: level none keeps the channel unread but nothing notifies, mentions included", %{
      world: world
    } do
      put_world(world, :mutes, [level_doc("server", @s1, "none")])
      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1, mentions: [@me])

      assert_push "unread_updated", %{
        "unread" => true,
        "mention" => false,
        "notify" => false,
        "muted" => false,
        "server" => %{"unread" => true, "notify" => false}
      }
    end

    test "CA2: the channel preference wins over the server one", %{world: world} do
      put_world(world, :mutes, [
        level_doc("server", @s1, "none"),
        level_doc("channel", @c1, "all")
      ])

      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1)
      assert_push "unread_updated", %{"channel_id" => @c1, "notify" => true}

      message_created(@c2, @m2, mentions: [@me])
      assert_push "unread_updated", %{"channel_id" => @c2, "notify" => false, "mention" => false}
    end

    test "CA2: the other way around, a quiet channel inside a noisy server", %{world: world} do
      put_world(world, :mutes, [
        level_doc("server", @s1, "all"),
        level_doc("channel", @c1, "none")
      ])

      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1, mentions: [@me])
      assert_push "unread_updated", %{"channel_id" => @c1, "notify" => false}

      message_created(@c2, @m2)
      assert_push "unread_updated", %{"channel_id" => @c2, "notify" => true}
    end

    test "a mute always beats a more permissive level", %{world: world} do
      put_world(world, :mutes, [
        %{"scope" => "server", "scope_id" => @s1, "server_id" => @s1, "muted" => true},
        level_doc("channel", @c1, "all")
      ])

      join_own()
      assert_push "snapshot", _

      message_created(@c1, @m1, mentions: [@me])

      assert_push "unread_updated", %{"unread" => true, "notify" => false, "muted" => true}
    end

    test "changing the level from another session reaches this one through a resync", %{
      world: world
    } do
      stub(RepoMock, :put_setting, fn @me, :server, @s1, @s1, %{level: "all"} ->
        put_world(world, :mutes, [level_doc("server", @s1, "all")])
      end)

      stub(RepoMock, :get_setting, fn @me, @s1 ->
        %{"scope_id" => @s1, "muted" => false, "level" => "all"}
      end)

      join_own()
      assert_push "snapshot", %{"preferences" => %{"servers" => servers}}
      assert servers == %{}

      assert {:ok, %{muted: false, level: "all"}} =
               Notifications.Settings.update_server(@me, @s1, %{level: "all"})

      assert_push "snapshot", %{"preferences" => %{"servers" => %{@s1 => "all"}}}
    end
  end

  describe "mark_read" do
    test "CA1/CA2: reading a channel clears it and its server and tells the user's other sessions" do
      expect(RepoMock, :mark_read, fn @me, @c1, @s1, @m1 -> :ok end)
      stub(RepoMock, :get_activity, fn _ids -> {:ok, %{@c1 => @m1}} end)
      Endpoint.subscribe("user:" <> @me)
      socket = join_own()
      assert_push "snapshot", %{"servers" => [%{"unread" => true}]}

      ref = push(socket, "mark_read", %{"channel_id" => @c1})

      assert_reply ref, :ok

      assert_push "unread_updated", %{
        "channel_id" => @c1,
        "unread" => false,
        "mention" => false,
        "server" => %{"unread" => false}
      }

      assert_receive %Phoenix.Socket.Broadcast{
        event: "read",
        payload: %{"channel_id" => @c1, "message_id" => @m1}
      }
    end

    test "reading up to a given message keeps newer messages unread" do
      expect(RepoMock, :mark_read, fn @me, @c1, @s1, @m2 -> :ok end)
      stub(RepoMock, :get_activity, fn _ids -> {:ok, %{@c1 => @m3}} end)
      socket = join_own()
      assert_push "snapshot", _

      ref = push(socket, "mark_read", %{"channel_id" => @c1, "message_id" => @m2})

      assert_reply ref, :ok
      refute_push "unread_updated", _
    end

    test "another session of the same user reading the channel clears it here" do
      stub(RepoMock, :get_activity, fn _ids -> {:ok, %{@c1 => @m1}} end)
      join_own()
      assert_push "snapshot", %{"servers" => [%{"unread" => true}]}

      Endpoint.broadcast("user:" <> @me, "read", %{"channel_id" => @c1, "message_id" => @m1})

      assert_push "unread_updated", %{"channel_id" => @c1, "unread" => false}
    end

    test "a channel the user cannot see is forbidden", %{world: world} do
      put_world(world, :channels, [@c1])

      stub(RepoMock, :get_channel, fn _id ->
        %{"_id" => "x", "server_id" => @s1, "kind" => "text"}
      end)

      socket = join_own()
      assert_push "snapshot", _

      ref = push(socket, "mark_read", %{"channel_id" => "x"})

      assert_reply ref, :error, %{error: %{code: "FORBIDDEN"}}
    end

    test "an unknown channel is not found" do
      stub(RepoMock, :get_channel, fn _id -> nil end)
      socket = join_own()
      assert_push "snapshot", _

      ref = push(socket, "mark_read", %{"channel_id" => "nope"})

      assert_reply ref, :error, %{error: %{code: "CHANNEL_NOT_FOUND"}}
    end

    test "a channel without messages replies ok and writes nothing" do
      socket = join_own()
      assert_push "snapshot", _

      ref = push(socket, "mark_read", %{"channel_id" => @c1})

      assert_reply ref, :ok
    end

    test "a storage failure is reported as unavailable" do
      stub(RepoMock, :get_activity, fn _ids -> {:ok, %{@c1 => @m1}} end)
      stub(RepoMock, :mark_read, fn _u, _c, _s, _m -> {:error, :timeout} end)
      socket = join_own()
      assert_push "snapshot", _

      ref = push(socket, "mark_read", %{"channel_id" => @c1})

      assert_reply ref, :error, %{error: %{code: "UNREAD_UNAVAILABLE"}}
    end

    test "a payload without channel_id is invalid" do
      socket = join_own()
      assert_push "snapshot", _

      ref = push(socket, "mark_read", %{})

      assert_reply ref, :error, %{error: %{code: "INVALID_PAYLOAD"}}
    end
  end

  describe "mark_all_read" do
    setup %{world: world} do
      stub(RepoMock, :mark_all_read, fn @me, entries ->
        Agent.update(world, fn state ->
          reads = Map.new(entries, &{&1.channel_id, &1.message_id})
          %{state | reads: Map.merge(state.reads, reads)}
        end)

        :ok
      end)

      :ok
    end

    test "CA2: clears every unread indicator and replies with how many channels were cleared", %{
      world: world
    } do
      put_world(world, :activity, %{@c1 => @m2, @c2 => @m3})
      socket = join_own()
      assert_push "snapshot", %{"servers" => [%{"channels" => [_a, _b]}]}

      ref = push(socket, "mark_all_read", %{})

      assert_reply ref, :ok, %{"channels" => 2}
      assert_push "snapshot", %{"servers" => []}
    end

    test "CA2: mentions disappear too", %{world: world} do
      put_world(world, :activity, %{@c1 => @m2})
      stub(RepoMock, :get_mention_markers, fn @me, _ids -> {:ok, %{@c1 => @m2}} end)
      socket = join_own()
      assert_push "snapshot", %{"servers" => [%{"mention" => true}]}

      ref = push(socket, "mark_all_read", %{})

      assert_reply ref, :ok, %{"channels" => 1}
      assert_push "snapshot", %{"servers" => []}
    end

    test "the user's other sessions are cleared as well", %{world: world} do
      put_world(world, :activity, %{@c1 => @m2})
      first = join_own()
      assert_push "snapshot", %{"servers" => [_one]}
      other = join_own()
      assert_push "snapshot", %{"servers" => [_one]}

      ref = push(first, "mark_all_read", %{})

      assert_reply ref, :ok
      assert_push "snapshot", %{"servers" => []}
      assert_push "snapshot", %{"servers" => []}
      assert Process.alive?(other.channel_pid)
    end

    test "with nothing unread it replies ok with zero", %{world: _world} do
      socket = join_own()
      assert_push "snapshot", %{"servers" => []}

      ref = push(socket, "mark_all_read", %{})

      assert_reply ref, :ok, %{"channels" => 0}
    end

    test "messages that arrive afterwards are unread again", %{world: world} do
      put_world(world, :activity, %{@c1 => @m1})
      socket = join_own()
      assert_push "snapshot", _

      ref = push(socket, "mark_all_read", %{})
      assert_reply ref, :ok
      assert_push "snapshot", %{"servers" => []}

      message_created(@c1, @m2)

      assert_push "unread_updated", %{"channel_id" => @c1, "unread" => true}
    end

    test "a storage failure is reported as unavailable", %{world: world} do
      put_world(world, :activity, %{@c1 => @m2})
      stub(RepoMock, :mark_all_read, fn _user, _entries -> {:error, :timeout} end)
      socket = join_own()
      assert_push "snapshot", _

      ref = push(socket, "mark_all_read", %{})

      assert_reply ref, :error, %{error: %{code: "UNREAD_UNAVAILABLE"}}
    end
  end

  describe "resync" do
    test "a resync broadcast reloads the snapshot", %{world: world} do
      join_own()
      assert_push "snapshot", %{"servers" => []}

      put_world(world, :activity, %{@c1 => @m1})
      Endpoint.broadcast("user:" <> @me, "resync", %{})

      assert_push "snapshot", %{"servers" => [%{"server_id" => @s1}]}
    end

    test "losing access to a channel drops it from the state", %{world: world} do
      put_world(world, :activity, %{@c1 => @m1})
      join_own()
      assert_push "snapshot", %{"servers" => [%{"channels" => [_one]}]}

      put_world(world, :channels, [@c2])
      Endpoint.broadcast("server:" <> @s1, "resync", %{})

      assert_push "snapshot", %{"servers" => []}
    end

    test "the client can ask for the snapshot again" do
      socket = join_own()
      assert_push "snapshot", _

      ref = push(socket, "snapshot", %{})

      assert_reply ref, :ok
      assert_push "snapshot", _
    end

    test "a failed reload keeps the connection and the previous state" do
      socket = join_own()
      assert_push "snapshot", _

      stub(RepoMock, :list_memberships, fn @me -> {:error, :timeout} end)
      ref = push(socket, "snapshot", %{})

      assert_reply ref, :error, %{error: %{code: "UNREAD_UNAVAILABLE"}}
      Endpoint.broadcast("user:" <> @me, "resync", %{})
      message_created(@c1, @m1)
      assert_push "unread_updated", %{"channel_id" => @c1}
    end
  end

  test "an unknown event is rejected" do
    socket = join_own()
    assert_push "snapshot", _

    ref = push(socket, "nope", %{})

    assert_reply ref, :error, %{error: %{code: "INVALID_PAYLOAD"}}
  end

  test "the channel stops when the first snapshot cannot be built" do
    stub(RepoMock, :list_memberships, fn @me -> {:error, :timeout} end)
    Process.flag(:trap_exit, true)

    try do
      subscribe_and_join(socket_for(@me), NotificationsChannel, "notifications:" <> @me)
    catch
      :exit, _reason -> :ok
    end

    assert_receive {:EXIT, _pid, :snapshot_failed}, 1_000
  end

  test "unrelated broadcasts are ignored" do
    join_own()
    assert_push "snapshot", _

    Endpoint.broadcast("user:" <> @me, "something_else", %{})

    refute_push "unread_updated", _
  end
end
