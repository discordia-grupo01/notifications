defmodule Notifications.Unread.Repo do
  @type result :: :ok | {:error, term()}
  @type write_result :: {:ok, :applied | :stale} | {:error, term()}
  @type read_entry :: %{channel_id: String.t(), server_id: String.t(), message_id: String.t()}
  @type setting_changes :: %{optional(:muted) => boolean(), optional(:level) => String.t() | nil}
  @type override :: %{role_id: String.t(), allow: [String.t()], deny: [String.t()]}

  @callback ping() :: :ok | {:error, term()}
  @callback ensure_indexes() :: result()

  @callback apply_clock(
              key :: String.t(),
              state :: String.t(),
              at :: DateTime.t(),
              expires_at :: DateTime.t() | nil
            ) :: write_result()
  @callback get_clock(key :: String.t()) :: map() | nil | {:error, term()}

  @callback upsert_channel(doc :: map()) :: result()
  @callback delete_channel(channel_id :: String.t()) :: result()
  @callback delete_server_data(server_id :: String.t(), channel_ids :: [String.t()]) :: result()
  @callback list_channel_ids(server_id :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback get_channel(channel_id :: String.t()) :: map() | nil | {:error, term()}

  @callback apply_server_owner(String.t(), String.t(), DateTime.t()) :: write_result()
  @callback apply_role(String.t(), String.t(), [String.t()], boolean(), DateTime.t()) ::
              write_result()
  @callback delete_role(String.t(), String.t(), DateTime.t()) :: write_result()
  @callback apply_member_roles(String.t(), String.t(), [String.t()], DateTime.t()) ::
              write_result()
  @callback delete_member(String.t(), String.t(), DateTime.t()) :: write_result()
  @callback apply_channel_overrides(String.t(), String.t(), [override()], DateTime.t()) ::
              write_result()
  @callback record_member_joined(String.t(), String.t(), DateTime.t()) :: result()

  @callback list_memberships(user_id :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get_server_owners([String.t()]) ::
              {:ok, %{String.t() => String.t()}} | {:error, term()}
  @callback list_roles([String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback list_channels([String.t()]) :: {:ok, [map()]} | {:error, term()}
  @callback list_overrides([String.t()]) :: {:ok, [map()]} | {:error, term()}

  @callback record_message(%{
              channel_id: String.t(),
              server_id: String.t(),
              message_id: String.t(),
              author_id: String.t(),
              mentioned_user_ids: [String.t()]
            }) :: result()
  @callback get_activity([String.t()]) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  @callback get_read_markers(String.t(), [String.t()]) ::
              {:ok, %{String.t() => String.t()}} | {:error, term()}
  @callback get_mention_markers(String.t(), [String.t()]) ::
              {:ok, %{String.t() => String.t()}} | {:error, term()}
  @callback mark_all_read(user_id :: String.t(), [read_entry()]) :: result()
  @callback mark_read(user_id :: String.t(), String.t(), String.t(), message_id :: String.t()) ::
              result()

  @callback list_settings(user_id :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback get_setting(user_id :: String.t(), scope_id :: String.t()) ::
              map() | nil | {:error, term()}
  @callback put_setting(
              user_id :: String.t(),
              scope :: :server | :channel,
              scope_id :: String.t(),
              server_id :: String.t(),
              changes :: setting_changes()
            ) :: result()

  @callback list_settings_for(user_ids :: [String.t()], scope_ids :: [String.t()]) ::
              {:ok, [map()]} | {:error, term()}
  @callback put_history(items :: [map()]) :: result()
  @callback list_history(
              user_id :: String.t(),
              before :: String.t() | nil,
              limit :: pos_integer()
            ) :: {:ok, [map()]} | {:error, term()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:notifications, :unread_repo, Notifications.Unread.Repo.Mongo)
end
