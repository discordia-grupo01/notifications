defmodule Notifications.Unread.AccessTest do
  use ExUnit.Case, async: true
  import Mox

  alias Notifications.Unread.Access
  alias Notifications.Unread.RepoMock

  setup :verify_on_exit!

  @me "11111111-1111-4111-8111-111111111111"
  @owner "22222222-2222-4222-8222-222222222222"
  @s1 "server-1"
  @joined ~U[2026-10-01 12:00:00.000Z]

  defp roles do
    [
      %{
        "_id" => "everyone",
        "server_id" => @s1,
        "permissions" => ["VIEW_CHANNELS"],
        "is_everyone" => true
      },
      %{
        "_id" => "mod",
        "server_id" => @s1,
        "permissions" => [],
        "is_everyone" => false
      }
    ]
  end

  defp member(role_ids \\ ["everyone"]),
    do: %{"server_id" => @s1, "user_id" => @me, "role_ids" => role_ids, "joined_at" => @joined}

  defp text(id), do: %{"_id" => id, "server_id" => @s1, "kind" => "text"}

  defp compute(memberships, channels, overrides \\ [], owners \\ %{@s1 => @owner}) do
    Access.compute(@me, memberships, owners, roles(), channels, overrides)
  end

  describe "compute/6" do
    test "lists the text channels the member can view" do
      assert [%{channel_id: "c1", server_id: @s1}, %{channel_id: "c2"}] =
               compute([member()], [text("c1"), text("c2")])
    end

    test "voice channels never carry unread state" do
      voice = %{"_id" => "v1", "server_id" => @s1, "kind" => "voice"}

      assert [%{channel_id: "c1"}] = compute([member()], [text("c1"), voice])
    end

    test "a channel with a deny override for the member's role is hidden" do
      overrides = [
        %{
          "_id" => "c2",
          "overrides" => [%{"role_id" => "everyone", "allow" => [], "deny" => ["VIEW_CHANNELS"]}]
        }
      ]

      assert [%{channel_id: "c1"}] = compute([member()], [text("c1"), text("c2")], overrides)
    end

    test "an allow override reveals a channel that the base roles do not" do
      overrides = [
        %{
          "_id" => "c2",
          "overrides" => [%{"role_id" => "mod", "allow" => ["VIEW_CHANNELS"], "deny" => []}]
        },
        %{
          "_id" => "c2",
          "overrides" => [%{"role_id" => "everyone", "allow" => [], "deny" => ["VIEW_CHANNELS"]}]
        }
      ]

      assert [%{channel_id: "c1"}] =
               compute([member()], [text("c1"), text("c2")], [Enum.at(overrides, 1)])

      assert [%{channel_id: "c1"}, %{channel_id: "c2"}] =
               compute([member(["everyone", "mod"])], [text("c1"), text("c2")], [
                 Enum.at(overrides, 0)
               ])
    end

    test "a member without roles sees nothing" do
      assert compute([member([])], [text("c1")]) == []
    end

    test "the owner sees every channel regardless of roles" do
      assert [%{channel_id: "c1"}] =
               Access.compute(
                 @owner,
                 [%{member() | "user_id" => @owner, "role_ids" => []}],
                 %{@s1 => @owner},
                 roles(),
                 [text("c1")],
                 []
               )
    end

    test "channels of servers the user does not belong to are never listed" do
      other = %{"_id" => "c9", "server_id" => "other", "kind" => "text"}

      assert [%{channel_id: "c1"}] = compute([member()], [text("c1"), other])
    end

    test "the floor is the UUIDv7 of the moment the user joined" do
      [%{floor: floor}] = compute([member()], [text("c1")])

      assert floor == Notifications.Unread.Position.floor(@joined)
    end

    test "a membership without joined_at falls back to inserted_at and then to the epoch" do
      inserted = ~U[2026-09-01 00:00:00.000Z]

      [%{floor: from_inserted}] =
        compute(
          [member() |> Map.delete("joined_at") |> Map.put("inserted_at", inserted)],
          [text("c1")]
        )

      [%{floor: from_epoch}] = compute([Map.delete(member(), "joined_at")], [text("c1")])

      assert from_inserted == Notifications.Unread.Position.floor(inserted)
      assert from_epoch == Notifications.Unread.Position.floor(~U[1970-01-01 00:00:00Z])
    end
  end

  describe "visible_channels/1" do
    test "reads the replica and returns the visible channels" do
      expect(RepoMock, :list_memberships, fn @me -> {:ok, [member()]} end)
      expect(RepoMock, :get_server_owners, fn [@s1] -> {:ok, %{@s1 => @owner}} end)
      expect(RepoMock, :list_roles, fn [@s1] -> {:ok, roles()} end)
      expect(RepoMock, :list_channels, fn [@s1] -> {:ok, [text("c1")]} end)
      expect(RepoMock, :list_overrides, fn [@s1] -> {:ok, []} end)

      assert {:ok, [%{channel_id: "c1", server_id: @s1}]} = Access.visible_channels(@me)
    end

    test "propagates a replica failure" do
      expect(RepoMock, :list_memberships, fn @me -> {:error, :timeout} end)

      assert Access.visible_channels(@me) == {:error, :timeout}
    end
  end
end
