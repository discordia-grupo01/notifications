defmodule Notifications.Delivery.Repo do
  @type result :: :ok | {:error, term()}
  @type write_result :: {:ok, :applied | :stale} | {:error, term()}
  @type presence :: %{
          connections: String.t(),
          do_not_disturb: boolean(),
          expires_at: DateTime.t() | nil
        }
  @type device_attrs :: %{
          provider: String.t(),
          platform: String.t(),
          credential: map(),
          credential_hash: String.t()
        }

  @callback ensure_indexes() :: result()

  @callback apply_user_name(
              user_id :: String.t(),
              name :: String.t(),
              version :: non_neg_integer()
            ) ::
              write_result()
  @callback apply_server_name(server_id :: String.t(), name :: String.t(), at :: DateTime.t()) ::
              write_result()
  @callback apply_presence(
              user_id :: String.t(),
              connections :: String.t(),
              do_not_disturb :: boolean(),
              version :: non_neg_integer(),
              expires_at :: DateTime.t()
            ) :: write_result()

  @callback get_user_names([String.t()]) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  @callback get_server_names([String.t()]) ::
              {:ok, %{String.t() => String.t()}} | {:error, term()}
  @callback get_presence([String.t()]) :: {:ok, %{String.t() => presence()}} | {:error, term()}

  @callback get_push_enabled(user_id :: String.t()) :: {:ok, boolean()} | {:error, term()}
  @callback put_push_enabled(user_id :: String.t(), enabled :: boolean()) :: result()
  @callback list_push_disabled([String.t()]) :: {:ok, [String.t()]} | {:error, term()}

  @callback put_device(user_id :: String.t(), device_attrs(), max_devices :: pos_integer()) ::
              {:ok, %{id: String.t(), created: boolean()}} | {:error, :device_limit | term()}
  @callback delete_device(user_id :: String.t(), device_id :: String.t()) :: result()
  @callback list_devices([String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback delete_devices([String.t()]) :: result()
  @callback mark_device(device_id :: String.t(), outcome :: :ok | {:error, String.t()}) ::
              result()

  @callback claim_delivery(
              event_id :: String.t(),
              device_id :: String.t(),
              expires_at :: DateTime.t()
            ) :: :claimed | :duplicate | {:error, term()}

  @spec impl() :: module()
  def impl,
    do: Application.get_env(:notifications, :delivery_repo, Notifications.Delivery.Repo.Mongo)
end
