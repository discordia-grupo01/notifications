defmodule Notifications.MutesTest do
  use ExUnit.Case, async: false
  import Mox

  alias Notifications.Mutes
  alias Notifications.PushMock
  alias Notifications.Unread.RepoMock

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @s1 "s1"
  @c1 "c1"

  setup do
    Application.put_env(:notifications, :push, PushMock)
    on_exit(fn -> Application.delete_env(:notifications, :push) end)
    :ok
  end

  defp stub_visible(channel_ids \\ [@c1]) do
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

  defp expect_resync, do: expect(PushMock, :publish, fn "user:" <> @me, "resync", %{} -> :ok end)

  describe "list/1" do
    test "separates servers from channels and sorts them" do
      expect(RepoMock, :list_mutes, fn @me ->
        {:ok,
         [
           %{"scope" => "channel", "scope_id" => "c2", "server_id" => "s2"},
           %{"scope" => "server", "scope_id" => "s9", "server_id" => "s9"},
           %{"scope" => "channel", "scope_id" => "c1", "server_id" => "s1"},
           %{"scope" => "server", "scope_id" => "s1", "server_id" => "s1"}
         ]}
      end)

      assert Mutes.list(@me) ==
               {:ok,
                %{
                  servers: ["s1", "s9"],
                  channels: [
                    %{channel_id: "c1", server_id: "s1"},
                    %{channel_id: "c2", server_id: "s2"}
                  ]
                }}
    end

    test "is empty when nothing is muted" do
      expect(RepoMock, :list_mutes, fn @me -> {:ok, []} end)

      assert Mutes.list(@me) == {:ok, %{servers: [], channels: []}}
    end

    test "propagates a storage failure" do
      expect(RepoMock, :list_mutes, fn @me -> {:error, :timeout} end)

      assert Mutes.list(@me) == {:error, :timeout}
    end
  end

  describe "scopes/1" do
    test "returns the muted ids as sets" do
      expect(RepoMock, :list_mutes, fn @me ->
        {:ok,
         [
           %{"scope" => "server", "scope_id" => "s1", "server_id" => "s1"},
           %{"scope" => "channel", "scope_id" => "c1", "server_id" => "s2"}
         ]}
      end)

      assert {:ok, %{servers: servers, channels: channels}} = Mutes.scopes(@me)
      assert MapSet.to_list(servers) == ["s1"]
      assert MapSet.to_list(channels) == ["c1"]
    end
  end

  describe "set_server/3" do
    test "CA2: a member mutes the server and their sessions are told to resync" do
      stub_visible()
      expect(RepoMock, :put_mute, fn @me, :server, @s1, @s1 -> :ok end)
      expect_resync()

      assert Mutes.set_server(@me, @s1, true) == {:ok, true}
    end

    test "someone who is not a member cannot mute the server" do
      stub(RepoMock, :list_memberships, fn @me -> {:ok, []} end)

      assert Mutes.set_server(@me, @s1, true) == {:error, :server_not_found}
    end

    test "CA3: unmuting deletes the mute without checking membership" do
      expect(RepoMock, :delete_mute, fn @me, @s1 -> :ok end)
      expect_resync()

      assert Mutes.set_server(@me, @s1, false) == {:ok, false}
    end

    test "a storage failure is returned and nobody is told to resync" do
      stub_visible()
      expect(RepoMock, :put_mute, fn _user, _scope, _id, _server -> {:error, :timeout} end)

      assert Mutes.set_server(@me, @s1, true) == {:error, :timeout}
    end

    test "a failure reading the memberships is returned" do
      stub(RepoMock, :list_memberships, fn @me -> {:error, :timeout} end)

      assert Mutes.set_server(@me, @s1, true) == {:error, :timeout}
    end
  end

  describe "set_channel/3" do
    test "CA1: someone who can see the channel mutes it, keeping its server" do
      stub_visible()

      stub(RepoMock, :get_channel, fn @c1 ->
        %{"_id" => @c1, "server_id" => @s1, "kind" => "text"}
      end)

      expect(RepoMock, :put_mute, fn @me, :channel, @c1, @s1 -> :ok end)
      expect_resync()

      assert Mutes.set_channel(@me, @c1, true) == {:ok, true}
    end

    test "a channel the user cannot see is forbidden" do
      stub_visible([])

      stub(RepoMock, :get_channel, fn @c1 ->
        %{"_id" => @c1, "server_id" => @s1, "kind" => "text"}
      end)

      assert Mutes.set_channel(@me, @c1, true) == {:error, :forbidden}
    end

    test "an unknown channel is not found" do
      stub(RepoMock, :get_channel, fn _id -> nil end)

      assert Mutes.set_channel(@me, "nope", true) == {:error, :channel_not_found}
    end

    test "a voice channel cannot be muted" do
      stub(RepoMock, :get_channel, fn @c1 ->
        %{"_id" => @c1, "server_id" => @s1, "kind" => "voice"}
      end)

      assert Mutes.set_channel(@me, @c1, true) == {:error, :channel_not_found}
    end

    test "CA3: unmuting works even if the channel is gone" do
      expect(RepoMock, :delete_mute, fn @me, @c1 -> :ok end)
      expect_resync()

      assert Mutes.set_channel(@me, @c1, false) == {:ok, false}
    end

    test "a broadcast failure does not undo the change" do
      expect(RepoMock, :delete_mute, fn @me, @c1 -> :ok end)
      expect(PushMock, :publish, fn _topic, "resync", %{} -> {:error, :down} end)

      assert Mutes.set_channel(@me, @c1, false) == {:ok, false}
    end
  end
end
