# Historias de usuario

Las historias del catálogo de la cátedra que resuelve este servicio, con su número, y las que resuelve junto con otros servicios. Las rutas REST están en [`openapi.yaml`](../openapi.yaml). Los cambios en vivo llegan por WebSocket (`/notifications/socket`), con un ticket de un solo uso que se pide con `POST /v1/notifications/socket-tickets`.

## Obligatorias

| # | Historia | Puntos | Cómo se usa |
|---|---|---|---|
| 27 | Ver notificaciones no leídas | 3 | Al unirse al socket llega un `snapshot` con los canales y servidores sin leer, y después `unread_updated` con cada cambio |
| 28 | Marcar notificaciones como leídas | 1 | Evento `mark_read` del socket |

## Optativas

| # | Historia | Puntos | Cómo se usa |
|---|---|---|---|
| 64 | Silenciar notificaciones de un canal o servidor | 3 | `PUT /v1/notifications/settings/servers/{serverId}` y `PUT /v1/notifications/settings/channels/{channelId}` |
| 65 | Configurar preferencias de notificación | 3 | `GET /v1/notifications/settings` y los mismos `PUT`, con el nivel de aviso (todo, solo menciones o nada) |
| 66 | Notificaciones push | 5 | `GET /v1/notifications/push/vapid-public-key`, `GET` y `PUT /v1/notifications/push/settings`, `POST /v1/notifications/push/devices`, `DELETE /v1/notifications/push/devices/{id}` |
| 67 | Centro de notificaciones con historial | 5 | `GET /v1/notifications/history` |

## Historias en las que participa

Estas historias las completan otros servicios. Acá está la parte que le toca a `notifications`:

| # | Historia | Qué hace este servicio |
|---|---|---|
| 46 | Menciones | Cuenta las menciones sin leer y marca el canal con una mención destacada. `messaging` las detecta y las avisa. |
| 74 | Estado de la plataforma e incidentes | Reenvía a los clientes, por el socket, los cambios de estado de la plataforma que publica `metrics`. |
| 10 | Transferir propiedad del servidor | Avisa al destinatario de la oferta y al dueño de la respuesta. |
| 29, 31, 32, 68, 69, 70, 71, 76, 78, 79 | Pantallas del backoffice, de métricas y de compras | Manda un aviso corto (`changed`) por el socket cada vez que algo cambia en `servers`, `billing` o `admin`, para que la pantalla vuelva a pedir sus datos sin recargar. |

## Decisiones técnicas

- **ADR 0007, no leídos por eventos:** cómo se calcula lo que falta leer sin consultar a otros servicios.
- **ADR 0008, notificaciones push:** por qué se usa Web Push para el navegador y Expo para el celular.
- **ADR 0003, réplica local de permisos:** el mismo patrón que `messaging`, aplicado a los canales que cada usuario puede ver.
