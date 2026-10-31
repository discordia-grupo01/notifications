defmodule NotificationsWeb.Schemas do
  alias OpenApiSpex.Schema

  defmodule ErrorResponse do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            code: %Schema{type: :string},
            message: %Schema{type: :string},
            details: %Schema{type: :object}
          },
          required: [:code, :message, :details]
        }
      },
      required: [:error]
    })
  end

  defmodule SocketTicket do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SocketTicket",
      type: :object,
      properties: %{
        ticket: %Schema{
          type: :string,
          description:
            "Ticket de un solo uso. Se manda como `?ticket=<ticket>` al conectar el WebSocket."
        },
        expires_in: %Schema{
          type: :integer,
          description: "Segundos que el ticket es válido desde que se emite."
        }
      },
      required: [:ticket, :expires_in]
    })
  end

  defmodule MuteRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MuteRequest",
      type: :object,
      properties: %{
        muted: %Schema{
          type: :boolean,
          description: "`true` silencia; `false` reactiva las notificaciones destacadas."
        }
      },
      required: [:muted]
    })
  end

  defmodule ServerMute do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ServerMute",
      type: :object,
      properties: %{
        server_id: %Schema{type: :string},
        muted: %Schema{type: :boolean}
      },
      required: [:server_id, :muted]
    })
  end

  defmodule ChannelMute do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelMute",
      type: :object,
      properties: %{
        channel_id: %Schema{type: :string},
        muted: %Schema{type: :boolean}
      },
      required: [:channel_id, :muted]
    })
  end

  defmodule MutedScopes do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MutedScopes",
      type: :object,
      properties: %{
        servers: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Ids de los servidores que el usuario silenció."
        },
        channels: %Schema{
          type: :array,
          description: "Canales que el usuario silenció, con el servidor al que pertenecen.",
          items: %Schema{
            type: :object,
            properties: %{
              channel_id: %Schema{type: :string},
              server_id: %Schema{type: :string}
            },
            required: [:channel_id, :server_id]
          }
        }
      },
      required: [:servers, :channels]
    })
  end
end
