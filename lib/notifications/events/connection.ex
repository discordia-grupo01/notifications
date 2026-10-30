defmodule Notifications.Events.Connection do
  @spec open(String.t()) :: {:ok, AMQP.Connection.t()} | {:error, term()}
  def open(url), do: AMQP.Connection.open(url, options(url))

  @spec options(String.t()) :: keyword()
  def options("amqps://" <> _ = url) do
    host = url |> URI.parse() |> Map.fetch!(:host) |> String.to_charlist()

    [
      ssl_options: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: host,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  def options(_url), do: []
end
