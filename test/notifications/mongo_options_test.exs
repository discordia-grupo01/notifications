defmodule Notifications.MongoOptionsTest do
  use ExUnit.Case, async: true

  alias Notifications.MongoOptions

  test "a plain local URL gets no TLS options" do
    assert MongoOptions.build("mongodb://localhost:27017/notifications_dev") ==
             [
               name: Notifications.Mongo,
               url: "mongodb://localhost:27017/notifications_dev",
               pool_size: 10
             ]
  end

  test "keeps a pool of connections, not the driver's single default one" do
    assert MongoOptions.build("mongodb://localhost:27017/notifications_dev", 25)[:pool_size] == 25
  end

  for url <- [
        "mongodb://u:p@host-00.mongodb.net:27017/db?ssl=true&replicaSet=rs",
        "mongodb://u:p@host-00.mongodb.net:27017/db?authSource=admin&tls=true",
        "mongodb+srv://u:p@cluster.mongodb.net/db"
      ] do
    test "verifies the server certificate against the system CA store for #{url}" do
      opts = MongoOptions.build(unquote(url))

      assert opts[:name] == Notifications.Mongo
      assert opts[:url] == unquote(url)

      ssl_opts = Keyword.fetch!(opts, :ssl_opts)
      assert ssl_opts[:verify] == :verify_peer
      assert [_ | _] = ssl_opts[:cacerts]
      assert [match_fun: match_fun] = ssl_opts[:customize_hostname_check]
      assert is_function(match_fun, 2)
    end
  end

  test "does not mistake a password containing 'ssl=true' for a TLS flag" do
    assert [name: _, url: _, pool_size: _] =
             MongoOptions.build("mongodb://u:ssl=true@localhost:27017/db")
  end
end
