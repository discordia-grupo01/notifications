defmodule Mix.Tasks.Push.GenVapid do
  use Mix.Task

  alias Notifications.Delivery.WebPush.{Encryption, Vapid}

  @shortdoc "Genera un par de claves VAPID para las notificaciones push web"

  @moduledoc """
  Imprime una clave privada VAPID lista para `VAPID_PRIVATE_KEY` y la pública
  correspondiente, que es la que usa el navegador al suscribirse.
  """

  @impl Mix.Task
  def run(_args) do
    {public, private} = Encryption.generate_keypair()

    Mix.shell().info("VAPID_PRIVATE_KEY=" <> Vapid.encode(private))
    Mix.shell().info("# clave publica: " <> Vapid.encode(public))
  end
end
