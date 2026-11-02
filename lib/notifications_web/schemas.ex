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

  defmodule SettingsRequest do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SettingsRequest",
      type: :object,
      description: "Al menos uno de `muted` o `level`. Solo cambia lo que se manda.",
      properties: %{
        muted: %Schema{
          type: :boolean,
          description: "`true` silencia; `false` reactiva las notificaciones destacadas."
        },
        level: %Schema{
          type: :string,
          nullable: true,
          enum: ["all", "mentions", "none", nil],
          description:
            "Qué avisa: `all` (todos los mensajes), `mentions` (solo menciones; es el valor por defecto) o `none`. `null` borra la preferencia y vuelve a heredar."
        }
      }
    })
  end

  defmodule ServerSetting do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ServerSetting",
      type: :object,
      properties: %{
        server_id: %Schema{type: :string},
        muted: %Schema{type: :boolean},
        level: %Schema{
          type: :string,
          nullable: true,
          enum: ["all", "mentions", "none", nil],
          description: "Preferencia guardada, o `null` si no hay (se usa el valor por defecto)."
        }
      },
      required: [:server_id, :muted, :level]
    })
  end

  defmodule ChannelSetting do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ChannelSetting",
      type: :object,
      properties: %{
        channel_id: %Schema{type: :string},
        muted: %Schema{type: :boolean},
        level: %Schema{
          type: :string,
          nullable: true,
          enum: ["all", "mentions", "none", nil],
          description: "Preferencia guardada, o `null` si hereda la del servidor."
        }
      },
      required: [:channel_id, :muted, :level]
    })
  end

  defmodule SettingsListing do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SettingsListing",
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
        },
        preferences: %Schema{
          type: :object,
          description: "Preferencias de nivel que el usuario fijó.",
          properties: %{
            servers: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{
                  server_id: %Schema{type: :string},
                  level: %Schema{type: :string, enum: ["all", "mentions", "none"]}
                },
                required: [:server_id, :level]
              }
            },
            channels: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{
                  channel_id: %Schema{type: :string},
                  server_id: %Schema{type: :string},
                  level: %Schema{type: :string, enum: ["all", "mentions", "none"]}
                },
                required: [:channel_id, :server_id, :level]
              }
            }
          },
          required: [:servers, :channels]
        }
      },
      required: [:servers, :channels, :preferences]
    })
  end

  defmodule HistoryItem do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HistoryItem",
      type: :object,
      description:
        "Una notificación del historial. Lleva solo ids (nunca el texto del mensaje): el cliente resuelve nombres y contenido con los datos que ya tiene o con messaging.",
      properties: %{
        kind: %Schema{
          type: :string,
          enum: ["mention", "direct_message"],
          description: "`mention`: te mencionaron en un canal. `direct_message`: te escribieron."
        },
        message_id: %Schema{type: :string, description: "Id (UUIDv7) del mensaje."},
        author_id: %Schema{type: :string},
        occurred_at: %Schema{type: :string, format: :"date-time"},
        server_id: %Schema{type: :string, nullable: true, description: "Solo en `mention`."},
        channel_id: %Schema{
          type: :string,
          nullable: true,
          description: "Canal de la mención. Solo en `mention`."
        },
        conversation_id: %Schema{
          type: :string,
          nullable: true,
          description: "Conversación del mensaje directo. Solo en `direct_message`."
        }
      },
      required: [:kind, :message_id, :author_id, :occurred_at]
    })
  end

  defmodule HistoryPage do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HistoryPage",
      type: :object,
      properties: %{
        items: %Schema{
          type: :array,
          description:
            "Más nuevas primero. Una lista vacía significa que no hay notificaciones para mostrar.",
          items: HistoryItem
        },
        next_cursor: %Schema{
          type: :string,
          nullable: true,
          description:
            "Pasarlo como `before` para pedir la página siguiente (más viejas). `null` cuando no hay más."
        }
      },
      required: [:items, :next_cursor]
    })
  end
end
