defmodule Notifications.SettingsTest do
  use ExUnit.Case, async: false
  import Mox

  alias Notifications.PushMock
  alias Notifications.Settings
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

    stub(RepoMock, :get_channel, fn id ->
      %{"_id" => id, "server_id" => @s1, "kind" => "text"}
    end)
  end

  defp expect_resync, do: expect(PushMock, :publish, fn "user:" <> @me, "resync", %{} -> :ok end)

  defp doc(scope, id, server_id, attrs),
    do: Map.merge(%{"scope" => scope, "scope_id" => id, "server_id" => server_id}, attrs)

  describe "list/1" do
    test "separates the muted scopes from the level preferences and sorts them" do
      expect(RepoMock, :list_settings, fn @me ->
        {:ok,
         [
           doc("channel", "c2", "s2", %{"muted" => true}),
           doc("server", "s9", "s9", %{"muted" => true, "level" => "none"}),
           doc("channel", "c1", "s1", %{"level" => "all"}),
           doc("server", "s1", "s1", %{"muted" => false, "level" => "mentions"})
         ]}
      end)

      assert Settings.list(@me) ==
               {:ok,
                %{
                  servers: ["s9"],
                  channels: [%{channel_id: "c2", server_id: "s2"}],
                  preferences: %{
                    servers: [
                      %{server_id: "s1", level: "mentions"},
                      %{server_id: "s9", level: "none"}
                    ],
                    channels: [%{channel_id: "c1", server_id: "s1", level: "all"}]
                  }
                }}
    end

    test "is empty when nothing is configured" do
      expect(RepoMock, :list_settings, fn @me -> {:ok, []} end)

      assert Settings.list(@me) ==
               {:ok, %{servers: [], channels: [], preferences: %{servers: [], channels: []}}}
    end

    test "propagates a storage failure" do
      expect(RepoMock, :list_settings, fn @me -> {:error, :timeout} end)

      assert Settings.list(@me) == {:error, :timeout}
    end
  end

  describe "scopes/1" do
    test "returns the muted ids as sets and the levels as maps" do
      expect(RepoMock, :list_settings, fn @me ->
        {:ok,
         [
           doc("server", "s1", "s1", %{"muted" => true}),
           doc("channel", "c1", "s2", %{"muted" => true, "level" => "all"}),
           doc("server", "s3", "s3", %{"level" => "none"})
         ]}
      end)

      assert {:ok, scopes} = Settings.scopes(@me)
      assert MapSet.to_list(scopes.muted_servers) == ["s1"]
      assert MapSet.to_list(scopes.muted_channels) == ["c1"]
      assert scopes.server_levels == %{"s3" => "none"}
      assert scopes.channel_levels == %{"c1" => "all"}
    end

    test "ignores levels it does not know" do
      expect(RepoMock, :list_settings, fn @me ->
        {:ok, [doc("server", "s1", "s1", %{"level" => "shouting"})]}
      end)

      assert {:ok, %{server_levels: levels}} = Settings.scopes(@me)
      assert levels == %{}
    end
  end

  describe "update_server/3" do
    test "CA2: a member mutes the server and their sessions are told to resync" do
      stub_visible()
      expect(RepoMock, :put_setting, fn @me, :server, @s1, @s1, %{muted: true} -> :ok end)

      expect(RepoMock, :get_setting, fn @me, @s1 ->
        %{"scope_id" => @s1, "muted" => true, "level" => nil}
      end)

      expect_resync()

      assert Settings.update_server(@me, @s1, %{muted: true}) ==
               {:ok, %{muted: true, level: nil}}
    end

    test "CA1: a member sets a level and the muted flag is left alone" do
      stub_visible()
      expect(RepoMock, :put_setting, fn @me, :server, @s1, @s1, %{level: "all"} -> :ok end)

      expect(RepoMock, :get_setting, fn @me, @s1 ->
        %{"scope_id" => @s1, "muted" => true, "level" => "all"}
      end)

      expect_resync()

      assert Settings.update_server(@me, @s1, %{level: "all"}) ==
               {:ok, %{muted: true, level: "all"}}
    end

    test "someone who is not a member cannot store anything for the server" do
      stub(RepoMock, :list_memberships, fn @me -> {:ok, []} end)

      assert Settings.update_server(@me, @s1, %{muted: true}) == {:error, :server_not_found}
      assert Settings.update_server(@me, @s1, %{level: "none"}) == {:error, :server_not_found}
    end

    test "CA3: clearing needs no membership and an emptied setting comes back as the default" do
      expect(RepoMock, :put_setting, fn @me, :server, @s1, @s1, %{muted: false, level: nil} ->
        :ok
      end)

      expect(RepoMock, :get_setting, fn @me, @s1 -> nil end)
      expect_resync()

      assert Settings.update_server(@me, @s1, %{muted: false, level: nil}) ==
               {:ok, %{muted: false, level: nil}}
    end

    test "a storage failure on write is returned and nobody is told to resync" do
      stub_visible()

      expect(RepoMock, :put_setting, fn _user, _scope, _id, _server, _changes ->
        {:error, :down}
      end)

      assert Settings.update_server(@me, @s1, %{muted: true}) == {:error, :down}
    end

    test "a failure reading the result back is returned and nobody is told to resync" do
      stub_visible()
      expect(RepoMock, :put_setting, fn _user, _scope, _id, _server, _changes -> :ok end)
      expect(RepoMock, :get_setting, fn @me, @s1 -> {:error, :timeout} end)

      assert Settings.update_server(@me, @s1, %{muted: true}) == {:error, :timeout}
    end

    test "a failure reading the memberships is returned" do
      stub(RepoMock, :list_memberships, fn @me -> {:error, :timeout} end)

      assert Settings.update_server(@me, @s1, %{muted: true}) == {:error, :timeout}
    end
  end

  describe "update_channel/3" do
    test "CA1: someone who can see the channel configures it, keeping its server" do
      stub_visible()
      expect(RepoMock, :put_setting, fn @me, :channel, @c1, @s1, %{level: "none"} -> :ok end)

      expect(RepoMock, :get_setting, fn @me, @c1 ->
        %{"scope_id" => @c1, "muted" => false, "level" => "none"}
      end)

      expect_resync()

      assert Settings.update_channel(@me, @c1, %{level: "none"}) ==
               {:ok, %{muted: false, level: "none"}}
    end

    test "a channel the user cannot see is forbidden" do
      stub_visible([])

      assert Settings.update_channel(@me, @c1, %{muted: true}) == {:error, :forbidden}
    end

    test "an unknown channel is not found" do
      stub(RepoMock, :get_channel, fn _id -> nil end)

      assert Settings.update_channel(@me, "nope", %{level: "all"}) ==
               {:error, :channel_not_found}
    end

    test "a voice channel cannot be configured" do
      stub(RepoMock, :get_channel, fn @c1 ->
        %{"_id" => @c1, "server_id" => @s1, "kind" => "voice"}
      end)

      assert Settings.update_channel(@me, @c1, %{muted: true}) == {:error, :channel_not_found}
    end

    test "clearing works even if the channel is gone, and the server is not needed" do
      expect(RepoMock, :put_setting, fn @me, :channel, @c1, nil, %{level: nil} -> :ok end)
      expect(RepoMock, :get_setting, fn @me, @c1 -> nil end)
      expect_resync()

      assert Settings.update_channel(@me, @c1, %{level: nil}) ==
               {:ok, %{muted: false, level: nil}}
    end

    test "a broadcast failure does not undo the change" do
      expect(RepoMock, :put_setting, fn _user, _scope, _id, _server, _changes -> :ok end)
      expect(RepoMock, :get_setting, fn @me, @c1 -> nil end)
      expect(PushMock, :publish, fn _topic, "resync", %{} -> {:error, :down} end)

      assert Settings.update_channel(@me, @c1, %{muted: false}) ==
               {:ok, %{muted: false, level: nil}}
    end
  end

  describe "effective_level/1" do
    defp scope(attrs),
      do:
        Map.merge(
          %{channel_muted: false, server_muted: false, channel_level: nil, server_level: nil},
          attrs
        )

    test "falls back to the default when nothing is configured" do
      assert Settings.effective_level(scope(%{})) == "mentions"
    end

    test "the channel level wins over the server level" do
      assert Settings.effective_level(scope(%{channel_level: "all", server_level: "none"})) ==
               "all"

      assert Settings.effective_level(scope(%{channel_level: "none", server_level: "all"})) ==
               "none"
    end

    test "the server level applies when the channel has none" do
      assert Settings.effective_level(scope(%{server_level: "all"})) == "all"
    end

    test "a mute of the channel or of the server always means none" do
      assert Settings.effective_level(scope(%{channel_muted: true, channel_level: "all"})) ==
               "none"

      assert Settings.effective_level(scope(%{server_muted: true, channel_level: "all"})) ==
               "none"
    end
  end

  describe "effective_level_for/3" do
    test "reads the channel and server documents out of a user's settings" do
      docs = [
        doc("server", @s1, @s1, %{"level" => "none"}),
        doc("channel", @c1, @s1, %{"level" => "all"}),
        doc("channel", "other", @s1, %{"muted" => true})
      ]

      assert Settings.effective_level_for(docs, @c1, @s1) == "all"
      assert Settings.effective_level_for(docs, "other", @s1) == "none"
      assert Settings.effective_level_for(docs, "untouched", @s1) == "none"
      assert Settings.effective_level_for([], @c1, @s1) == "mentions"
    end

    test "ignores levels it does not know" do
      docs = [doc("server", @s1, @s1, %{"level" => "shouting"})]

      assert Settings.effective_level_for(docs, @c1, @s1) == "mentions"
    end
  end
end
