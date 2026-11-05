defmodule Notifications.Unread.State do
  alias Notifications.Settings
  alias Notifications.Unread.Position

  @type channel :: %{
          server_id: String.t(),
          baseline: Position.t(),
          last_position: Position.t() | nil,
          mentions: [Position.t()],
          channel_muted: boolean(),
          server_muted: boolean(),
          channel_level: String.t() | nil,
          server_level: String.t() | nil
        }
  @type t :: %{String.t() => channel()}
  @type flags :: %{
          unread: boolean(),
          mention: boolean(),
          mention_count: non_neg_integer(),
          notify: boolean(),
          muted: boolean()
        }
  @type settings :: Notifications.Settings.scopes()

  @spec build(
          [map()],
          %{String.t() => Position.t()},
          %{String.t() => Position.t()},
          %{String.t() => [Position.t()]}
        ) :: t()
  def build(visible, activity, reads, mentions) do
    Map.new(visible, fn %{channel_id: id, server_id: server_id, floor: floor} ->
      baseline = Position.max(floor, Map.get(reads, id))

      {id,
       %{
         server_id: server_id,
         baseline: baseline,
         last_position: Map.get(activity, id),
         mentions: mentions |> Map.get(id, []) |> unread_after(baseline),
         channel_muted: false,
         server_muted: false,
         channel_level: nil,
         server_level: nil
       }}
    end)
  end

  @spec apply_settings(t(), settings()) :: t()
  def apply_settings(state, settings) do
    Map.new(state, fn {id, channel} ->
      {id,
       %{
         channel
         | channel_muted: MapSet.member?(settings.muted_channels, id),
           server_muted: MapSet.member?(settings.muted_servers, channel.server_id),
           channel_level: Map.get(settings.channel_levels, id),
           server_level: Map.get(settings.server_levels, channel.server_id)
       }}
    end)
  end

  @spec message_created(t(), String.t(), map()) :: t()
  def message_created(state, user_id, %{channel_id: channel_id} = event) do
    case Map.fetch(state, channel_id) do
      {:ok, channel} -> Map.put(state, channel_id, apply_message(channel, user_id, event))
      :error -> state
    end
  end

  @spec mark_read(t(), String.t(), Position.t()) :: t()
  def mark_read(state, channel_id, up_to) do
    case Map.fetch(state, channel_id) do
      {:ok, channel} ->
        Map.put(state, channel_id, read_up_to(channel, up_to))

      :error ->
        state
    end
  end

  @spec channel_flags(t(), String.t()) :: flags()
  def channel_flags(state, channel_id) do
    case Map.fetch(state, channel_id) do
      {:ok, channel} -> flags(channel)
      :error -> %{unread: false, mention: false, mention_count: 0, notify: false, muted: false}
    end
  end

  @spec server_flags(t(), String.t()) :: flags()
  def server_flags(state, server_id) do
    channels = for {_id, channel} <- state, channel.server_id == server_id, do: channel

    channels
    |> Enum.map(&flags/1)
    |> Enum.reduce(
      %{unread: false, mention: false, mention_count: 0, notify: false},
      fn flags, acc ->
        %{
          unread: acc.unread or flags.unread,
          mention: acc.mention or flags.mention,
          mention_count: acc.mention_count + flags.mention_count,
          notify: acc.notify or flags.notify
        }
      end
    )
    |> Map.put(:muted, Enum.any?(channels, & &1.server_muted))
  end

  @spec snapshot(t()) :: map()
  def snapshot(state) do
    servers =
      state
      |> Enum.map(fn {id, channel} -> {id, channel.server_id, flags(channel)} end)
      |> Enum.filter(fn {_id, _server_id, flags} -> flags.unread end)
      |> Enum.group_by(fn {_id, server_id, _flags} -> server_id end)
      |> Enum.map(fn {server_id, channels} -> server_entry(state, server_id, channels) end)
      |> Enum.sort_by(& &1["server_id"])

    %{
      "servers" => servers,
      "muted" => muted_scopes(state),
      "preferences" => preferences(state)
    }
  end

  @spec change(t(), String.t()) :: map()
  def change(state, channel_id) do
    channel_flags = channel_flags(state, channel_id)
    server_id = state |> Map.get(channel_id, %{}) |> Map.get(:server_id)
    server_flags = if server_id, do: server_flags(state, server_id), else: channel_flags

    %{
      "server_id" => server_id,
      "channel_id" => channel_id,
      "unread" => channel_flags.unread,
      "mention" => channel_flags.mention,
      "mention_count" => channel_flags.mention_count,
      "notify" => channel_flags.notify,
      "muted" => channel_flags.muted,
      "server" => %{
        "unread" => server_flags.unread,
        "mention" => server_flags.mention,
        "mention_count" => server_flags.mention_count,
        "notify" => server_flags.notify,
        "muted" => server_flags.muted
      }
    }
  end

  @spec server_ids(t()) :: [String.t()]
  def server_ids(state), do: state |> Map.values() |> Enum.map(& &1.server_id) |> Enum.uniq()

  defp apply_message(channel, user_id, %{position: position} = event) do
    channel
    |> Map.update!(:last_position, &Position.max(&1, position))
    |> track_mention(user_id, event)
    |> track_author(user_id, event)
  end

  defp track_mention(channel, user_id, %{position: position, mentioned_user_ids: mentioned}) do
    if user_id in mentioned and Position.after?(position, channel.baseline) and
         position not in channel.mentions,
       do: %{channel | mentions: [position | channel.mentions]},
       else: channel
  end

  defp track_author(channel, user_id, %{author_id: user_id, position: position}),
    do: read_up_to(channel, position)

  defp track_author(channel, _user_id, _event), do: channel

  defp read_up_to(channel, up_to) do
    baseline = Position.max(channel.baseline, up_to)
    %{channel | baseline: baseline, mentions: unread_after(channel.mentions, baseline)}
  end

  defp unread_after(positions, baseline),
    do: Enum.filter(positions, &Position.after?(&1, baseline))

  defp flags(%{baseline: baseline, last_position: last, mentions: mentions} = channel) do
    muted? = channel.channel_muted or channel.server_muted
    level = Settings.effective_level(channel)
    mention_count = Enum.count(mentions, &Position.after?(&1, baseline))
    mentioned? = mention_count > 0
    unread? = mentioned? or Position.after?(last, baseline)
    mention? = mentioned? and level != "none"

    %{
      unread: unread?,
      mention: mention?,
      mention_count: if(mention?, do: mention_count, else: 0),
      notify: mention? or (level == "all" and unread?),
      muted: muted?
    }
  end

  defp muted_scopes(state) do
    channels = Map.values(state)

    %{
      "servers" =>
        for(channel <- channels, channel.server_muted, do: channel.server_id)
        |> Enum.uniq()
        |> Enum.sort(),
      "channels" =>
        for({id, channel} <- state, channel.channel_muted, do: id)
        |> Enum.sort()
    }
  end

  defp preferences(state) do
    %{
      "servers" =>
        for(channel <- Map.values(state), channel.server_level, into: %{}) do
          {channel.server_id, channel.server_level}
        end,
      "channels" =>
        for({id, channel} <- state, channel.channel_level, into: %{}) do
          {id, channel.channel_level}
        end
    }
  end

  defp server_entry(state, server_id, channels) do
    server = server_flags(state, server_id)

    %{
      "server_id" => server_id,
      "unread" => server.unread,
      "mention" => server.mention,
      "mention_count" => server.mention_count,
      "notify" => server.notify,
      "muted" => server.muted,
      "channels" =>
        channels
        |> Enum.map(fn {id, _server_id, flags} ->
          %{
            "channel_id" => id,
            "unread" => flags.unread,
            "mention" => flags.mention,
            "mention_count" => flags.mention_count,
            "notify" => flags.notify,
            "muted" => flags.muted
          }
        end)
        |> Enum.sort_by(& &1["channel_id"])
    }
  end
end
