defmodule Notifications.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    mongo_url = Application.fetch_env!(:notifications, :mongo_url)
    Notifications.Log.Telemetry.attach()

    Logger.info("service_started",
      version: to_string(Application.spec(:notifications, :vsn)),
      log_level: Logger.level()
    )

    children =
      [
        {Phoenix.PubSub, name: Notifications.PubSub},
        Notifications.Delivery.Dispatcher,
        {Mongo,
         Notifications.MongoOptions.build(
           mongo_url,
           Application.fetch_env!(:notifications, :mongo_pool_size)
         )}
      ] ++ index_children() ++ amqp_children() ++ [NotificationsWeb.Endpoint]

    opts = [strategy: :one_for_one, name: Notifications.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp index_children do
    if Application.get_env(:notifications, :ensure_indexes, true),
      do: [Notifications.Unread.IndexSetup],
      else: []
  end

  defp amqp_children do
    if Application.get_env(:notifications, :start_amqp_consumers, true) do
      rabbitmq_url = Application.fetch_env!(:notifications, :rabbitmq_url)

      [{Notifications.Events.Consumer, url: rabbitmq_url}]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    NotificationsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
