defmodule Mix.Tasks.Push.GenVapidTest do
  use ExUnit.Case, async: false

  alias Notifications.Delivery.WebPush.Vapid

  test "prints a private key that yields the printed public key" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    Mix.Tasks.Push.GenVapid.run([])

    assert_received {:mix_shell, :info, ["VAPID_PRIVATE_KEY=" <> private]}
    assert_received {:mix_shell, :info, ["# clave publica: " <> public]}

    {:ok, private_key} = Vapid.decode(private)
    assert {:ok, derived} = Vapid.public_key(private_key)
    assert Vapid.encode(derived) == public
  end
end
