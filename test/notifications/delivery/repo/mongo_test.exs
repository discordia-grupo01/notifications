mongo_url = System.get_env("MONGO_URL")

if mongo_url do
  defmodule Notifications.Delivery.Repo.MongoTest do
    use ExUnit.Case, async: false

    alias Notifications.Delivery.Repo.Mongo, as: Repo

    @collections ~w(
      replica_user_names replica_server_names replica_presence push_settings
      push_devices push_deliveries
    )

    @t1 ~U[2026-11-02 12:00:00.000Z]
    @t2 ~U[2026-11-02 12:00:01.000Z]

    setup do
      for collection <- @collections do
        {:ok, _result} = Mongo.delete_many(Notifications.Mongo, collection, %{})
      end

      assert :ok = Repo.ensure_indexes()
      :ok
    end

    defp attrs(token, extra \\ %{}) do
      Map.merge(
        %{
          provider: "expo",
          platform: "android",
          credential: %{"token" => token},
          credential_hash: "hash-" <> token
        },
        extra
      )
    end

    test "ensure_indexes/0 can run more than once" do
      assert Repo.ensure_indexes() == :ok
    end

    describe "names" do
      test "the user name with the highest version wins" do
        assert Repo.apply_user_name("u1", "Ana", 2) == {:ok, :applied}
        assert Repo.apply_user_name("u1", "Vieja", 1) == {:ok, :stale}
        assert Repo.apply_user_name("u1", "Ana M", 3) == {:ok, :applied}
        assert Repo.apply_user_name("u1", "Ana M", 3) == {:ok, :applied}

        assert Repo.get_user_names(["u1", "nobody"]) == {:ok, %{"u1" => "Ana M"}}
      end

      test "the newest snapshot of a server wins" do
        assert Repo.apply_server_name("s1", "Nuevo", @t2) == {:ok, :applied}
        assert Repo.apply_server_name("s1", "Viejo", @t1) == {:ok, :stale}

        assert Repo.get_server_names(["s1"]) == {:ok, %{"s1" => "Nuevo"}}
      end

      test "asking for no names answers an empty map" do
        assert Repo.get_user_names([]) == {:ok, %{}}
        assert Repo.get_server_names([]) == {:ok, %{}}
      end
    end

    describe "presence" do
      test "keeps the latest state by version" do
        expires = DateTime.add(DateTime.utc_now(), 3600)

        assert Repo.apply_presence("u1", "active", false, 2, expires) == {:ok, :applied}
        assert Repo.apply_presence("u1", "none", true, 1, expires) == {:ok, :stale}

        assert {:ok, %{"u1" => state}} = Repo.get_presence(["u1", "u2"])
        assert %{connections: "active", do_not_disturb: false} = state
        assert %DateTime{} = state.expires_at

        assert Repo.apply_presence("u1", "idle", true, 3, expires) == {:ok, :applied}

        assert {:ok, %{"u1" => %{connections: "idle", do_not_disturb: true}}} =
                 Repo.get_presence(["u1"])
      end
    end

    describe "push switch" do
      test "is on by default and can be turned off and on" do
        assert Repo.get_push_enabled("u1") == {:ok, true}
        assert Repo.list_push_disabled(["u1", "u2"]) == {:ok, []}

        assert Repo.put_push_enabled("u1", false) == :ok
        assert Repo.get_push_enabled("u1") == {:ok, false}
        assert Repo.get_push_enabled("u2") == {:ok, true}
        assert Repo.list_push_disabled(["u1", "u2"]) == {:ok, ["u1"]}

        assert Repo.put_push_enabled("u1", true) == :ok
        assert Repo.list_push_disabled(["u1"]) == {:ok, []}
      end

      test "asking about nobody answers an empty list" do
        assert Repo.list_push_disabled([]) == {:ok, []}
      end
    end

    describe "devices" do
      test "registers a device with an opaque id and does not repeat it" do
        assert {:ok, %{id: id, created: true}} = Repo.put_device("u1", attrs("a"), 10)
        assert byte_size(id) >= 20
        refute id =~ "a"

        assert Repo.put_device("u1", attrs("a"), 10) == {:ok, %{id: id, created: false}}

        assert {:ok, [device]} = Repo.list_devices(["u1"])
        assert device["_id"] == id
        assert device["provider"] == "expo"
        assert device["credential"] == %{"token" => "a"}
        assert %DateTime{} = device["created_at"]
      end

      test "the same credential registered by another user moves to that user" do
        {:ok, %{id: id}} = Repo.put_device("u1", attrs("a"), 10)

        assert Repo.put_device("u2", attrs("a"), 10) == {:ok, %{id: id, created: false}}
        assert Repo.list_devices(["u1"]) == {:ok, []}
        assert {:ok, [%{"_id" => ^id, "user_id" => "u2"}]} = Repo.list_devices(["u2"])
      end

      test "a user cannot register more devices than the cap, but can re-register" do
        assert {:ok, _} = Repo.put_device("u1", attrs("a"), 2)
        assert {:ok, _} = Repo.put_device("u1", attrs("b"), 2)

        assert Repo.put_device("u1", attrs("c"), 2) == {:error, :device_limit}
        assert {:ok, %{created: false}} = Repo.put_device("u1", attrs("a"), 2)
        assert {:ok, _} = Repo.put_device("u2", attrs("c"), 2)
      end

      test "deletes only the device of that user" do
        {:ok, %{id: id}} = Repo.put_device("u1", attrs("a"), 10)

        assert Repo.delete_device("u2", id) == :ok
        assert {:ok, [_]} = Repo.list_devices(["u1"])

        assert Repo.delete_device("u1", id) == :ok
        assert Repo.list_devices(["u1"]) == {:ok, []}
        assert Repo.delete_device("u1", id) == :ok
      end

      test "lists the devices of several users and deletes several by id" do
        {:ok, %{id: a}} = Repo.put_device("u1", attrs("a"), 10)
        {:ok, %{id: b}} = Repo.put_device("u2", attrs("b"), 10)
        {:ok, %{id: c}} = Repo.put_device("u3", attrs("c"), 10)

        assert {:ok, devices} = Repo.list_devices(["u1", "u2"])
        assert devices |> Enum.map(& &1["_id"]) |> Enum.sort() == Enum.sort([a, b])
        assert Repo.list_devices([]) == {:ok, []}

        assert Repo.delete_devices([a, b]) == :ok
        assert Repo.delete_devices([]) == :ok
        assert {:ok, [%{"_id" => ^c}]} = Repo.list_devices(["u1", "u2", "u3"])
      end

      test "records the outcome of a delivery" do
        {:ok, %{id: id}} = Repo.put_device("u1", attrs("a"), 10)

        assert Repo.mark_device(id, {:error, "http_403"}) == :ok

        assert {:ok, [%{"last_error" => "http_403", "last_used_at" => nil}]} =
                 Repo.list_devices(["u1"])

        assert Repo.mark_device(id, :ok) == :ok

        assert {:ok, [%{"last_error" => nil, "last_used_at" => %DateTime{}}]} =
                 Repo.list_devices(["u1"])
      end
    end

    describe "claim_delivery/3" do
      test "an event is claimed once per device" do
        expires = DateTime.add(DateTime.utc_now(), 3600)

        assert Repo.claim_delivery("e1", "d1", expires) == :claimed
        assert Repo.claim_delivery("e1", "d1", expires) == :duplicate
        assert Repo.claim_delivery("e1", "d2", expires) == :claimed
        assert Repo.claim_delivery("e2", "d1", expires) == :claimed
      end
    end
  end
else
  IO.puts("Skipping Delivery.Repo.Mongo test: MONGO_URL not set.")
end
