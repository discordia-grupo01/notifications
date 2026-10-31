defmodule Notifications.Unread.StateTest do
  use ExUnit.Case, async: true

  alias Notifications.Unread.State

  @me "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"

  @s1 "s1"
  @s2 "s2"
  @c1 "c1"
  @c2 "c2"
  @c3 "c3"

  @m1 "00000000-0000-7000-8000-000000000001"
  @m2 "00000000-0000-7000-8000-000000000002"
  @m3 "00000000-0000-7000-8000-000000000003"

  defp visible do
    [
      %{channel_id: @c1, server_id: @s1, floor: "00000000-0000-7000-8000-000000000000"},
      %{channel_id: @c2, server_id: @s1, floor: "00000000-0000-7000-8000-000000000000"},
      %{channel_id: @c3, server_id: @s2, floor: "00000000-0000-7000-8000-000000000000"}
    ]
  end

  defp event(channel_id, message_id, opts \\ []) do
    %{
      channel_id: channel_id,
      message_id: message_id,
      author_id: Keyword.get(opts, :author, @other),
      mentioned_user_ids: Keyword.get(opts, :mentions, [])
    }
  end

  describe "build/4" do
    test "a channel without messages is read" do
      state = State.build(visible(), %{}, %{}, %{})

      assert State.channel_flags(state, @c1) == %{unread: false, mention: false, muted: false}
    end

    test "CA1: a channel with a message newer than the last read is unread" do
      state = State.build(visible(), %{@c1 => @m2}, %{@c1 => @m1}, %{})

      assert State.channel_flags(state, @c1) == %{unread: true, mention: false, muted: false}
      assert State.channel_flags(state, @c2) == %{unread: false, mention: false, muted: false}
    end

    test "a channel read up to its last message is read" do
      state = State.build(visible(), %{@c1 => @m2}, %{@c1 => @m2}, %{})

      assert State.channel_flags(state, @c1).unread == false
    end

    test "messages older than the point where the user joined never count as unread" do
      floor = "00000000-0000-7000-8000-000000000002"
      visible = [%{channel_id: @c1, server_id: @s1, floor: floor}]

      assert State.build(visible, %{@c1 => @m1}, %{}, %{}) |> State.channel_flags(@c1) ==
               %{unread: false, mention: false, muted: false}

      assert State.build(visible, %{@c1 => @m3}, %{}, %{}) |> State.channel_flags(@c1) ==
               %{unread: true, mention: false, muted: false}
    end

    test "CA3: a mention newer than the baseline marks the channel as mention and unread" do
      state = State.build(visible(), %{@c1 => @m2}, %{@c1 => @m1}, %{@c1 => @m2})

      assert State.channel_flags(state, @c1) == %{unread: true, mention: true, muted: false}
    end

    test "CA3: a mention that was already read is only a plain read channel" do
      state = State.build(visible(), %{@c1 => @m2}, %{@c1 => @m2}, %{@c1 => @m2})

      assert State.channel_flags(state, @c1) == %{unread: false, mention: false, muted: false}
    end

    test "a mention older than the last read does not stay highlighted when newer plain messages arrive" do
      state = State.build(visible(), %{@c1 => @m3}, %{@c1 => @m2}, %{@c1 => @m1})

      assert State.channel_flags(state, @c1) == %{unread: true, mention: false, muted: false}
    end
  end

  describe "message_created/3" do
    test "marks the channel unread" do
      state =
        visible()
        |> State.build(%{}, %{}, %{})
        |> State.message_created(@me, event(@c1, @m1))

      assert State.channel_flags(state, @c1) == %{unread: true, mention: false, muted: false}
    end

    test "the author's own message never makes the channel unread for them" do
      state =
        visible()
        |> State.build(%{}, %{}, %{})
        |> State.message_created(@me, event(@c1, @m1, author: @me))

      assert State.channel_flags(state, @c1) == %{unread: false, mention: false, muted: false}
    end

    test "the author's message also clears older unread messages" do
      state =
        visible()
        |> State.build(%{@c1 => @m1}, %{}, %{})
        |> State.message_created(@me, event(@c1, @m2, author: @me))

      assert State.channel_flags(state, @c1).unread == false
    end

    test "CA3: a message that mentions the user is a mention" do
      state =
        visible()
        |> State.build(%{}, %{}, %{})
        |> State.message_created(@me, event(@c1, @m1, mentions: [@me]))

      assert State.channel_flags(state, @c1) == %{unread: true, mention: true, muted: false}
    end

    test "CA3: a message that mentions someone else is not a mention for the user" do
      state =
        visible()
        |> State.build(%{}, %{}, %{})
        |> State.message_created(@me, event(@c1, @m1, mentions: [@other]))

      assert State.channel_flags(state, @c1) == %{unread: true, mention: false, muted: false}
    end

    test "an event for a channel the user cannot see is ignored" do
      state = State.build(visible(), %{}, %{}, %{})

      assert State.message_created(state, @me, event("hidden", @m1)) == state
    end

    test "is idempotent and tolerates out of order delivery" do
      base = State.build(visible(), %{}, %{}, %{})

      once = State.message_created(base, @me, event(@c1, @m2))
      twice = State.message_created(once, @me, event(@c1, @m2))
      older_after = State.message_created(twice, @me, event(@c1, @m1))

      assert twice == once
      assert older_after == once
    end
  end

  describe "mark_read/3" do
    test "clears unread and mention up to that message" do
      state =
        visible()
        |> State.build(%{@c1 => @m2}, %{}, %{@c1 => @m2})
        |> State.mark_read(@c1, @m2)

      assert State.channel_flags(state, @c1) == %{unread: false, mention: false, muted: false}
    end

    test "a read marker never goes backwards" do
      state =
        visible()
        |> State.build(%{@c1 => @m3}, %{@c1 => @m2}, %{})
        |> State.mark_read(@c1, @m1)

      assert State.channel_flags(state, @c1).unread == true
      assert state[@c1].baseline == @m2
    end

    test "a message that arrives after the read keeps the channel unread" do
      state =
        visible()
        |> State.build(%{@c1 => @m1}, %{}, %{})
        |> State.mark_read(@c1, @m1)
        |> State.message_created(@me, event(@c1, @m2))

      assert State.channel_flags(state, @c1).unread == true
    end

    test "an unknown channel is ignored" do
      state = State.build(visible(), %{}, %{}, %{})

      assert State.mark_read(state, "hidden", @m1) == state
    end
  end

  describe "server_flags/2" do
    test "CA2: a server is unread when at least one of its channels is" do
      state = State.build(visible(), %{@c2 => @m1}, %{}, %{})

      assert State.server_flags(state, @s1) == %{unread: true, mention: false, muted: false}
      assert State.server_flags(state, @s2) == %{unread: false, mention: false, muted: false}
    end

    test "CA2: a server with every channel read is read" do
      state = State.build(visible(), %{@c1 => @m1, @c2 => @m1}, %{@c1 => @m1, @c2 => @m1}, %{})

      assert State.server_flags(state, @s1) == %{unread: false, mention: false, muted: false}
    end

    test "CA3: a mention in any channel highlights the whole server" do
      state = State.build(visible(), %{@c1 => @m1, @c2 => @m2}, %{}, %{@c2 => @m2})

      assert State.server_flags(state, @s1) == %{unread: true, mention: true, muted: false}
    end

    test "an unknown server is read" do
      state = State.build(visible(), %{@c1 => @m1}, %{}, %{})

      assert State.server_flags(state, "nope") == %{unread: false, mention: false, muted: false}
    end
  end

  describe "snapshot/1" do
    test "lists only the servers with something unread and, inside them, the unread channels" do
      state =
        State.build(visible(), %{@c1 => @m1, @c2 => @m1, @c3 => @m1}, %{@c2 => @m1}, %{@c3 => @m1})

      assert State.snapshot(state) == %{
               "servers" => [
                 %{
                   "server_id" => @s1,
                   "unread" => true,
                   "mention" => false,
                   "muted" => false,
                   "channels" => [
                     %{
                       "channel_id" => @c1,
                       "unread" => true,
                       "mention" => false,
                       "muted" => false
                     }
                   ]
                 },
                 %{
                   "server_id" => @s2,
                   "unread" => true,
                   "mention" => true,
                   "muted" => false,
                   "channels" => [
                     %{"channel_id" => @c3, "unread" => true, "mention" => true, "muted" => false}
                   ]
                 }
               ],
               "muted" => %{"servers" => [], "channels" => []}
             }
    end

    test "is empty when everything is read" do
      assert State.snapshot(State.build(visible(), %{}, %{}, %{})) == %{
               "servers" => [],
               "muted" => %{"servers" => [], "channels" => []}
             }
    end
  end

  describe "change/2" do
    test "describes the channel and its server after a change" do
      state =
        visible()
        |> State.build(%{@c1 => @m1}, %{}, %{@c1 => @m1})

      assert State.change(state, @c1) == %{
               "server_id" => @s1,
               "channel_id" => @c1,
               "unread" => true,
               "mention" => true,
               "muted" => false,
               "server" => %{"unread" => true, "mention" => true, "muted" => false}
             }
    end

    test "the server flag reflects the other channels too" do
      state =
        visible()
        |> State.build(%{@c1 => @m1, @c2 => @m1}, %{@c1 => @m1}, %{})

      assert %{"unread" => false, "server" => %{"unread" => true}} = State.change(state, @c1)
    end
  end

  describe "apply_mutes/2" do
    defp muted(servers, channels),
      do: %{servers: MapSet.new(servers), channels: MapSet.new(channels)}

    defp with_mutes(servers, channels, activity, mentions) do
      visible()
      |> State.build(activity, %{}, mentions)
      |> State.apply_mutes(muted(servers, channels))
    end

    test "CA1: a muted channel stays unread but loses the highlighted mention" do
      state = with_mutes([], [@c1], %{@c1 => @m1}, %{@c1 => @m1})

      assert State.channel_flags(state, @c1) == %{unread: true, mention: false, muted: true}
    end

    test "CA1: new messages in a muted channel keep counting as unread activity" do
      state =
        with_mutes([], [@c1], %{}, %{})
        |> State.message_created(@me, event(@c1, @m2, mentions: [@me]))

      assert State.channel_flags(state, @c1) == %{unread: true, mention: false, muted: true}
    end

    test "muting one channel does not touch its siblings" do
      state = with_mutes([], [@c1], %{@c1 => @m1, @c2 => @m1}, %{@c1 => @m1, @c2 => @m1})

      assert State.channel_flags(state, @c2) == %{unread: true, mention: true, muted: false}
      assert State.server_flags(state, @s1) == %{unread: true, mention: true, muted: false}
    end

    test "CA2: a muted server mutes every one of its channels and only its own" do
      state =
        with_mutes([@s1], [], %{@c1 => @m1, @c2 => @m1, @c3 => @m1}, %{
          @c1 => @m1,
          @c3 => @m1
        })

      assert State.channel_flags(state, @c1) == %{unread: true, mention: false, muted: true}
      assert State.channel_flags(state, @c2) == %{unread: true, mention: false, muted: true}
      assert State.channel_flags(state, @c3) == %{unread: true, mention: true, muted: false}
      assert State.server_flags(state, @s1) == %{unread: true, mention: false, muted: true}
      assert State.server_flags(state, @s2) == %{unread: true, mention: true, muted: false}
    end

    test "CA3: removing the mute brings the highlight back" do
      muted_state = with_mutes([@s1], [@c1], %{@c1 => @m1}, %{@c1 => @m1})
      state = State.apply_mutes(muted_state, muted([], []))

      assert State.channel_flags(state, @c1) == %{unread: true, mention: true, muted: false}
      assert State.server_flags(state, @s1).muted == false
    end

    test "reading a muted channel clears its unread indicator" do
      state =
        with_mutes([], [@c1], %{@c1 => @m1}, %{@c1 => @m1})
        |> State.mark_read(@c1, @m1)

      assert State.channel_flags(state, @c1) == %{unread: false, mention: false, muted: true}
    end

    test "the snapshot lists what is muted even when nothing is unread" do
      state = with_mutes([@s2], [@c2, @c1], %{}, %{})

      assert State.snapshot(state) == %{
               "servers" => [],
               "muted" => %{"servers" => [@s2], "channels" => [@c1, @c2]}
             }
    end

    test "the snapshot flags muted channels and servers that have unread activity" do
      state = with_mutes([@s1], [], %{@c1 => @m1}, %{@c1 => @m1})

      assert %{
               "servers" => [
                 %{
                   "server_id" => @s1,
                   "unread" => true,
                   "mention" => false,
                   "muted" => true,
                   "channels" => [%{"channel_id" => @c1, "mention" => false, "muted" => true}]
                 }
               ]
             } = State.snapshot(state)
    end

    test "change/2 reports the muted flag of the channel and of its server" do
      state = with_mutes([@s1], [], %{@c1 => @m1}, %{@c1 => @m1})

      assert %{
               "unread" => true,
               "mention" => false,
               "muted" => true,
               "server" => %{"unread" => true, "mention" => false, "muted" => true}
             } = State.change(state, @c1)
    end
  end

  test "server_ids/1 lists each server once" do
    assert visible() |> State.build(%{}, %{}, %{}) |> State.server_ids() |> Enum.sort() == [
             @s1,
             @s2
           ]
  end
end
