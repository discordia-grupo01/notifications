defmodule Notifications.Delivery.Config do
  @defaults [
    max_devices: 10,
    presence_ttl_seconds: 6 * 60 * 60,
    claim_ttl_seconds: 24 * 60 * 60,
    max_concurrency: 50,
    max_attempts: 3,
    retry_base_ms: 1_000,
    retry_max_ms: 30_000,
    http_timeout_ms: 10_000,
    expo_url: "https://exp.host/--/api/v2/push/send",
    expo_access_token: nil,
    vapid_private_key: nil,
    vapid_subject: nil,
    allowed_hosts: [
      "fcm.googleapis.com",
      "updates.push.services.mozilla.com",
      "push.services.mozilla.com",
      "web.push.apple.com",
      "notify.windows.com"
    ]
  ]

  @spec get(atom()) :: term()
  def get(key) do
    :notifications
    |> Application.get_env(:push_delivery, [])
    |> Keyword.get_lazy(key, fn -> Keyword.fetch!(@defaults, key) end)
  end
end
