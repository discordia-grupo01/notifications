defmodule NotificationsWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import NotificationsWeb.ChannelCase

      @endpoint NotificationsWeb.Endpoint
    end
  end

  setup _tags do
    Mox.set_mox_private()
    :ok
  end
end
