defmodule Notifications.Events.ConnectionTest do
  use ExUnit.Case, async: true

  alias Notifications.Events.Connection

  test "a plain amqp url adds no TLS options" do
    assert Connection.options("amqp://guest:guest@localhost:5672") == []
  end

  test "an amqps url verifies the broker certificate against the system roots and its hostname" do
    [ssl_options: ssl] = Connection.options("amqps://user:pass@bunny.cloudamqp.com/vhost")

    assert ssl[:verify] == :verify_peer
    assert is_list(ssl[:cacerts]) and ssl[:cacerts] != []
    assert ssl[:server_name_indication] == ~c"bunny.cloudamqp.com"
    assert Keyword.has_key?(ssl[:customize_hostname_check], :match_fun)
  end

  test "an unreachable broker returns an error instead of crashing" do
    assert {:error, _reason} = Connection.open("amqp://guest:guest@localhost:1")
  end
end
