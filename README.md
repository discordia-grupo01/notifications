# notifications (Elixir)

Servicio de **notificaciones** de Discordia. Cubre tres historias:

- **"Ver notificaciones no leídas"**: CA1 indicador de no leído por canal, CA2 indicador de no
  leído por servidor (si al menos un canal tiene no leídos) y CA3 indicador destacado para las
  menciones (historia optativa, ya implementada del lado de `messaging` en #46).
- **"Silenciar notificaciones de un canal o servidor"** (HU #64): ver "Silenciar un canal o un
  servidor".
- **"Configurar preferencias de notificación"** (HU #65): ver "Preferencias de notificación".

El servicio **no llama a ningún otro servicio por HTTP**: todo lo que sabe lo aprende
consumiendo eventos del bus. Lo que expone por REST es el ticket para abrir el WebSocket (ver
"Por qué hay un endpoint HTTP") y la configuración del propio usuario (silenciados y
preferencias).

## Stack
- Lenguaje: Elixir / Phoenix (Channels para WS)
- BDD: MongoDB (`mongodb_driver`) para el estado de lectura y la réplica local
- Event bus: RabbitMQ (`amqp`), solo para consumir los eventos de dominio de
  `discordia.events`
- Auth: Kong valida el JWT del endpoint de tickets; el socket se autentica con el ticket
- OpenAPI: `open_api_spex`, generado desde las anotaciones `operation` del controller

## Cómo funciona

```
 servers ──servers.*──────────┐
                              ▼
                     discordia.events ──► notifications.unread_state ──► Events.Consumer
 messaging ─messaging.message_created─┘                                       │
                                                                              ▼
                                                                   Mongo (réplica + actividad)
                                                                              │
                                                              Push local (Endpoint.broadcast)
                                                                              │
                                                                  sockets conectados
```

- **Réplica local de permisos** (mismo patrón que `messaging`, ADR 0003): el servicio guarda
  en Mongo los miembros, roles, overrides y dueño de cada servidor a partir de los eventos
  `servers.*`, y calcula con `Notifications.Unread.Access` qué canales de texto puede ver
  cada usuario (`VIEW_CHANNELS`). Nunca pregunta a `servers`.
- **Actividad por canal**: cada `messaging.message_created` guarda el id del último mensaje
  del canal. El evento lleva solo ids (canal, mensaje, autor, mencionados), nunca el
  contenido.
- **Marcadores por usuario**: `read_markers` (hasta qué mensaje leyó) y `mention_markers`
  (último mensaje que lo mencionó).
- **No hay contadores**. El estado se *deriva* comparando ids: los ids de mensaje son UUIDv7
  (ordenables por tiempo), así que "hay no leídos" es `último_mensaje > hasta_donde_leí`.
  Por eso reprocesar un evento no cambia nada (idempotente) y no hay que mantener sumas que
  se desincronicen.
- **Línea base**: lo que cuenta como leído es el máximo entre lo que el usuario marcó como
  leído y el momento en que se unió al servidor (`UUID.floor_v7(joined_at)`). Los mensajes
  anteriores a que entrara nunca aparecen como no leídos.
- **Tus propios mensajes** nunca te dejan un canal no leído, y además marcan como leído lo
  anterior (escribir en un canal implica haberlo visto).
- **Menciones**: si el último mensaje que te mencionó es posterior a tu línea base, el canal
  se marca `mention: true`, además de `unread: true`. El servidor hereda `mention` si alguno
  de sus canales lo tiene.

## Por qué hay un endpoint HTTP

El navegador no puede mandar el header `Authorization` al abrir un WebSocket y poner el JWT
en la URL lo deja en logs (ADR 0002). Por eso el cliente pide un ticket de un solo uso
(30 s) con `POST /v1/notifications/socket-tickets` y conecta con `?ticket=<ticket>`. Es la
única excepción a "todo por eventos" en el flujo de lectura, y es la misma que ya usa
`messaging`. Los silenciados son configuración del usuario, no un hecho de otro servicio, y por eso
se guardan acá y se piden por REST.

## Endpoints / Channels

- `GET /health` (ping: responde `{"status":"ok"}` sin tocar Mongo ni el broker), `GET /livez` (igual, en texto plano), `GET /readyz` (readiness pinguea Mongo)
- `POST /v1/notifications/socket-tickets` -- ticket para el WebSocket (Bearer JWT, validado
  por Kong)
- `GET /v1/notifications/settings` -- qué servidores y canales silenció el usuario y qué
  preferencias de nivel fijó
- `PUT /v1/notifications/settings/servers/:server_id` y
  `PUT /v1/notifications/settings/channels/:channel_id` -- silenciar o reactivar
  (`{"muted": true | false}`) y/o elegir el nivel de aviso
  (`{"level": "all" | "mentions" | "none" | null}`)
- WS `/notifications/socket?ticket=<ticket>`, canal `notifications:<user_id>` (solo se puede
  unir uno a su propio topic)

### Mensajes del canal (formato Phoenix)

Al unirse el servidor empuja `snapshot` con el estado completo; después va empujando
`unread_updated` cuando cambia algo.

`snapshot` -- solo lista los servidores y canales que tienen algo sin leer:

```json
{
  "servers": [
    {
      "server_id": "…",
      "unread": true,
      "mention": false,
      "notify": false,
      "muted": false,
      "channels": [
        { "channel_id": "…", "unread": true, "mention": false, "notify": false, "muted": false }
      ]
    }
  ],
  "muted": { "servers": ["…"], "channels": ["…"] },
  "preferences": { "servers": { "<server_id>": "all" }, "channels": { "<channel_id>": "none" } }
}
```

`muted` y `preferences` (arriba de todo) listan lo que el usuario configuró explícitamente, aunque
no tenga nada sin leer: sirven para dibujar el estado de cada canal y servidor sin pedir nada más.
`preferences` trae solo lo guardado; lo heredado o por defecto no aparece.

`notify` es el aviso destacado: lo que decide si hay que mostrar o enviar una notificación. `unread`
es solo "hay algo sin leer" y no depende de ninguna configuración. `mention` indica que hay una
mención pendiente que sigue contando como destacada.

`unread_updated` -- cambió el estado de un canal (y de su servidor):

```json
{
  "server_id": "…",
  "channel_id": "…",
  "unread": true,
  "mention": true,
  "notify": true,
  "muted": false,
  "server": { "unread": true, "mention": true, "notify": true, "muted": false }
}
```

Solo se empuja cuando cambian los indicadores: un segundo mensaje en un canal que ya estaba
no leído no genera otro aviso.

Eventos que manda el cliente:

| Evento | Payload | Respuesta |
|---|---|---|
| `mark_read` | `{"channel_id": "…", "message_id": "…"}` (`message_id` es opcional: sin él se lee hasta el último mensaje) | `ok`, o error `FORBIDDEN` / `CHANNEL_NOT_FOUND` / `UNREAD_UNAVAILABLE` |
| `mark_all_read` | `{}` | `{"channels": N}` con cuántos canales se limpiaron, o error `UNREAD_UNAVAILABLE`; después llega un `snapshot` (vacío) a todas las sesiones del usuario |
| `snapshot` | `{}` | `ok` y un nuevo `snapshot` |

`mark_read` nunca retrocede un marcador. Acepta el `message_id` que mande el cliente aunque el
evento de ese mensaje todavía no haya llegado por RabbitMQ (el cliente lo ve en vivo por
`messaging` antes que `notifications` lo procese; si se recortara al último mensaje conocido, el
canal se encendería como no leído justo después de leerlo). Tiene que ser un UUIDv7 y no estar
más de 60 s en el futuro; si no, responde `INVALID_PAYLOAD`.
Se avisa a las otras sesiones del mismo usuario para que apaguen el indicador también.

### Marcar como leído

- **Al abrir un canal.** El cliente manda `mark_read` cuando el usuario abre el canal y ve los
  mensajes nuevos, con el `message_id` del último mensaje que mostró (así no importa si el evento
  de ese mensaje todavía no llegó). El indicador del canal, su mención y, si era el último
  pendiente, el del servidor se apagan y llega `unread_updated`.
- **Marcar todo.** `mark_all_read` pone, para cada canal que el usuario puede ver y tiene algo sin
  leer, el marcador en el último mensaje del canal, con una sola escritura en bloque. Solo toca
  canales con contenido sin leer, así que repetirlo no escribe nada (`{"channels": 0}`). Después
  publica un `resync` a todas las sesiones del usuario, que reciben un `snapshot` ya vacío.
  Lo que se escriba después vuelve a contar como no leído. No existe una versión "por servidor":
  el cliente puede mandar un `mark_read` por cada canal si lo necesita.

Ejemplo (frames Phoenix v2, `[join_ref, ref, topic, event, payload]`):

```json
["1","1","notifications:<user_id>","phx_join",{}]
["1","2","notifications:<user_id>","mark_read",{"channel_id":"<channel_id>"}]
```

### Silenciar un canal o un servidor

Silenciar apaga **solo el aviso destacado** (`mention` y `notify`); la actividad sigue contando
como no leída (`unread`). Sale de dos silenciados posibles y se combinan con un "o":

| Silenciado | Efecto |
|---|---|
| Un canal | Ese canal queda `muted: true`; sus menciones dejan de destacarse. |
| Un servidor | Todos sus canales quedan `muted: true` y el servidor también. |

- `muted` del servidor es verdadero solo si se silenció **el servidor**; silenciar uno de sus
  canales no lo marca.
- El `mention` del servidor se calcula con los canales no silenciados: si el único canal con
  mención está silenciado, el servidor queda `unread: true` y `mention: false`.
- Reactivar (`{"muted": false}`) devuelve el aviso destacado de inmediato: la mención se deriva de
  los mismos marcadores, así que una mención todavía sin leer vuelve a destacarse.
- Para silenciar un canal hay que poder verlo (`403 FORBIDDEN`, o `404 CHANNEL_NOT_FOUND` si no
  existe); para silenciar un servidor hay que ser miembro (`404 SERVER_NOT_FOUND`). Reactivar no
  pide nada: siempre se puede sacar un silenciado.
- Es idempotente: repetir el mismo pedido deja el mismo resultado.
- Al guardar, el servicio le dice a todas las sesiones abiertas del usuario que recarguen su
  estado, así que reciben un `snapshot` nuevo con el `muted` actualizado.
- Si el usuario deja el servidor o el servidor/canal se borra, sus silenciados se borran también.

```json
PUT /v1/notifications/settings/channels/<channel_id>
{ "muted": true }

200 { "channel_id": "…", "muted": true }
```

### Preferencias de notificación

Cada usuario puede elegir **qué actividad avisa** de forma destacada (`notify`), por servidor y por
canal. Hay tres niveles:

| Nivel | Qué avisa |
|---|---|
| `all` | Todos los mensajes. |
| `mentions` | Solo las menciones. Es el comportamiento por defecto. |
| `none` | Nada, ni siquiera las menciones. |

- **Reglas de prioridad (la más específica gana):** el nivel del canal, si lo hay; si no, el del
  servidor; si no, el por defecto (`mentions`). Un canal con `all` dentro de un servidor en `none`
  avisa; un canal en `none` dentro de un servidor en `all`, no.
- **Silenciar gana siempre**: un canal o servidor silenciado vale como `none` aunque tenga un nivel
  más permisivo configurado.
- **`unread` no cambia nunca.** Elegir `none` (como silenciar) deja el canal sin leer; solo cambia
  `notify` y `mention`.
- **`mention` y `notify`**: con `mentions` van juntos. Con `all`, un mensaje común enciende `notify`
  pero no `mention` (no hay una mención). Con `none`, ninguno de los dos.
- `{"level": null}` borra la preferencia: un canal vuelve a heredar la del servidor y un servidor
  vuelve al valor por defecto. Si el documento queda sin silenciado ni nivel, se borra.
- El mismo `PUT` acepta `muted`, `level` o ambos y solo cambia lo que se manda. Hace falta al menos
  uno (`400 INVALID_PAYLOAD`; también si `level` no es `all`/`mentions`/`none`/`null`).
- Para fijar algo hay que poder ver el canal o ser miembro del servidor. Borrar (`level: null`) o
  reactivar (`muted: false`) no pide nada.
- Igual que al silenciar, las sesiones abiertas del usuario reciben un `snapshot` nuevo.

```json
PUT /v1/notifications/settings/channels/<channel_id>
{ "level": "all" }

200 { "channel_id": "…", "muted": false, "level": "all" }
```

`GET /v1/notifications/settings` mantiene `servers` y `channels` (los silenciados) y agrega
`preferences` con los niveles fijados.

## Eventos que consume

Una única cola durable, `notifications.unread_state`, enlazada a `discordia.events` (topic):

| Routing key | Para qué |
|---|---|
| `messaging.message_created` | actividad del canal y menciones (no se audita: es de alto volumen) |
| `servers.channel_created`, `servers.channel_deleted` | qué canales existen y de qué tipo |
| `servers.server_deleted` | borra todo lo del servidor y deja una lápida |
| `servers.member_joined`, `servers.member_left` | alta/baja de la membresía (y el momento de ingreso) |
| `servers.member_roles_updated`, `servers.role_updated`, `servers.role_deleted` | permisos |
| `servers.channel_overrides_updated`, `servers.owner_updated` | permisos |

Garantías (igual que el resto de los consumidores):

- **At-least-once con ack manual**: si el procesamiento falla (Mongo caído, push no
  confirmado) se hace `nack` con requeue y el evento se vuelve a procesar. Todas las
  escrituras son idempotentes.
- **Orden**: cada entidad tiene un reloj (`event_clocks`) y gana el evento más nuevo (LWW por
  `occurred_at`). Un evento viejo se ignora como `stale`. Los borrados dejan una lápida con
  TTL de 7 días para que un evento tardío no resucite lo borrado.
- **Mensajes inválidos** (JSON roto, routing key desconocida, campos faltantes) se descartan
  con ack y quedan en la colección de auditoría `consumed_events`.

## Eventos que publica

Ninguno.

## Una sola instancia

`notifications` **no está pensado para correr distribuido**: corre una única instancia, y esa
instancia es la que consume los eventos y la que tiene todos los sockets. Por eso no hay
fanout entre instancias: cuando un evento cambia el estado, se avisa directo a los sockets
locales con `Endpoint.broadcast`.

Si se levantaran dos instancias contra la misma cola, cada evento lo procesaría una sola y los
sockets de la otra no se enterarían hasta reconectar (el `snapshot` al unirse siempre sale de
Mongo y es correcto). No es un escenario soportado.

Igual se respeta la regla de no guardar estado en memoria que importe: lo que cuenta está en
Mongo, y cada socket solo mantiene una copia de trabajo de *su* usuario, que reconstruye desde
Mongo ante un `resync`.

## Modelo de datos (Mongo)

| Colección | Contenido |
|---|---|
| `channels` | canales conocidos (`kind`, `server_id`) |
| `channel_activity` | `_id` = canal, `last_message_id` (se actualiza con `$max`) |
| `read_markers` | `_id` = `user:canal`, `last_read_id` (`$max`) |
| `mention_markers` | `_id` = `user:canal`, `last_mention_id` (`$max`) |
| `replica_servers`, `replica_roles`, `replica_members`, `replica_overrides` | réplica de permisos |
| `event_clocks` | relojes LWW y lápidas |
| `consumed_events` | auditoría de lo consumido |
| `notification_settings` | `_id` = `user:canal_o_servidor`, `scope` (`server`/`channel`), `scope_id`, `server_id`, `muted`, `level` (`all`/`mentions`/`none` o `null`) |
| `socket_tickets` | tickets de un solo uso (TTL) |

Los índices se crean al arrancar (`Notifications.Unread.IndexSetup`, con reintentos).

## Variables de entorno

Ver `.env.example`.

| Variable | Descripción |
|---|---|
| `MONGO_URL` | conexión a Mongo |
| `MONGO_POOL_SIZE` | conexiones que mantiene el servicio |
| `RABBITMQ_URL` | conexión a RabbitMQ **sin barra final** (una barra es el vhost vacío y el broker rechaza la conexión) |
| `SECRET_KEY_BASE` | clave del endpoint (obligatoria en producción) |
| `CHECK_ORIGIN` | orígenes permitidos para el WebSocket (lista separada por comas, o `false`) |
| `LOG_LEVEL` | `debug`, `info`, `warning` o `error` |

## Logs

JSON, una línea por evento, con `service`, `request_id` y los ids relevantes. Nunca se
registra el query string (lleva el ticket) ni contenido de mensajes.

## Deploy (Render + Atlas)

La imagen es el `Dockerfile` del repo (release de Elixir, usuario sin privilegios, ~17 MB) y
`render.yaml` es el blueprint de Render. **No usa Supabase**: `notifications` no tiene outbox
ni Postgres, solo Mongo y RabbitMQ.

1. **Atlas (Mongo).** Creá un usuario con rol `readWrite` sobre la base `notifications` y
   habilitá en *Network Access* las IPs de salida de Render (están en el dashboard del
   servicio; para probar se puede abrir `0.0.0.0/0`). La URL lleva el nombre de la base:
   `mongodb+srv://USUARIO:CLAVE@cluster0.xxxxx.mongodb.net/notifications?retryWrites=true&w=majority`
   (si la clave tiene caracteres especiales, codificarla como URL). Con `mongodb+srv://` el
   servicio activa TLS verificado solo. Los índices se crean al arrancar.
2. **RabbitMQ (CloudAMQP).** `RABBITMQ_URL=amqps://USUARIO:CLAVE@host.rmq.cloudamqp.com/VHOST`.
   Con `amqps://` el servicio verifica el certificado del broker. Usa **una sola conexión**
   (el plan gratuito permite 20 y ya las comparten `servers`, `identity` y `messaging`).
3. **Render.** *New > Blueprint*, elegí el repo y completá `MONGO_URL` y `RABBITMQ_URL`
   (`SECRET_KEY_BASE` se genera solo). Render despliega cuando pasa el CI
   (`autoDeployTrigger: checksPass`) y usa `/health` como health check. Es una sola instancia.
   El plan es `free`, que se duerme a los 15 minutos sin tráfico entrante; para que no se
   duerma, en cron-job.org se programa un `GET https://<servicio>.onrender.com/health` cada
   10 minutos (timeout de 60 s: el primer ping tras una caída tarda ~1 minuto en despertarlo).
   `/health` no toca Mongo, así que el ping no mantiene despierto a Atlas ni gasta conexiones.
   Una instancia siempre encendida consume ~744 de las 750 horas gratuitas del mes de todo el
   workspace de Render: no puede haber otro servicio gratuito en el mismo workspace.
   Mientras el servicio duerme, los eventos esperan en la cola durable de RabbitMQ y se procesan
   al despertar; si hace falta un servicio sin esas pausas, se pasa a `plan: starter`.
4. **Gateway.** En el `.env` de la VM del gateway, `NOTIFICATIONS_UPSTREAM_URL=https://<servicio>.onrender.com`,
   y recrear Kong: `docker compose up -d --force-recreate kong-config gateway`.
5. **Comprobar.** `GET https://<servicio>.onrender.com/readyz` responde 200, y los logs muestran
   `events_consumer_connected` e `indexes_ready`.

**Primer arranque con datos existentes.** RabbitMQ no guarda lo publicado antes de que exista la
cola, así que la réplica de permisos arranca vacía. Hay que desplegar `notifications` y después
repetir el backfill de `servers` (migración `0022_backfill_access_events`, re-publica roles,
miembros, overrides y dueño; se puede repetir sin riesgo). Los canales no hacen falta en el
backfill: un canal desconocido se da de alta con su primer mensaje (siempre es de texto), salvo
que ya figure borrado. Lo que se escribió antes del deploy no cuenta como no leído: la línea
base de cada miembro es el momento en que el servicio lo vio.

## Setup local
```bash
cp .env.example .env
mix local.hex --force && mix local.rebar --force
mix deps.get
docker compose up -d mongo rabbitmq
mix phx.server
```

## Tests
```bash
mix test --cover
```

Los tests de integración contra Mongo y RabbitMQ reales se saltan solos si faltan las
variables. Para correrlos todos:

```bash
docker run -d --rm --name nt-mongo -p 27021:27017 mongo:7
docker run -d --rm --name nt-rabbit -p 5675:5672 rabbitmq:3.13-alpine

export MONGO_URL=mongodb://localhost:27021/notifications_test
export RABBITMQ_URL=amqp://guest:guest@localhost:5675
MIX_ENV=test mix coveralls
```

El CI exige 70 % de cobertura y corre con ambos servicios levantados.

## OpenAPI
```bash
make openapi
```

## Formateo automatico
Este repo se autoformatea con `mix format` en cada commit. Activalo una vez por clone:
```bash
git config core.hooksPath .githooks
```
Si usan VS Code con la extension ElixirLS, tambien formatea al guardar (ya configurado en .vscode/settings.json).

El CI sigue corriendo `mix format --check-formatted` como red de seguridad, por si alguien clono sin activar el hook.

## Version de Elixir/Erlang (asdf)
Este repo fija la version exacta en `.tool-versions`, para que todo el equipo y el CI usen la misma.
```bash
brew install asdf
asdf plugin add erlang
asdf plugin add elixir
asdf install
```

## Arquitectura del proyecto

Phoenix organiza el codigo por **Context** (dominio de negocio), no por capa tecnica.

```
lib/
├── notifications/
│   ├── application.ex            # Supervisor: Mongo, PubSub, consumidores, endpoint
│   ├── unread.ex                 # API publica: snapshot/1, mark_read/3 y mark_all_read/1
│   ├── unread/
│   │   ├── state.ex              # Calculo puro de los indicadores
│   │   ├── access.ex             # Que canales ve cada usuario
│   │   ├── permissions.ex        # Permisos efectivos (misma regla que servers)
│   │   ├── repo.ex, repo/mongo.ex
│   │   └── index_setup.ex
│   ├── events/                   # Consumidor de discordia.events
│   ├── push.ex, push/local.ex    # Aviso a los sockets de esta instancia
│   └── auth/                     # Tickets del WebSocket
└── notifications_web/            # Endpoint, router, controllers, socket y canal
```

El controller/channel (capa web) **nunca** accede directo a Mongo: siempre entra por
`Notifications.Unread`.

## CI local
```bash
make ci
```

## Pendiente / fuera de alcance
- Los eventos de suspensión de usuarios no se consumen (no cambian el estado de lectura).
- Los mensajes directos (DM) no generan notificaciones: `messaging` no los publica.
- Si un mensaje se edita y agrega una mención, no se vuelve a notificar.
- Publicar la imagen y desplegarla (secrets de Docker Hub y la VM) no está en este pipeline.
