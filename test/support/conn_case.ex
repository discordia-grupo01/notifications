defmodule NotificationsWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import NotificationsWeb.ConnCase

      @endpoint NotificationsWeb.Endpoint
    end
  end

  setup _tags do
    Mox.set_mox_private()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
