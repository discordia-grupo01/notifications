# notifications (Elixir)

Servicio de **notificaciones** de Discordia. Cubre cuatro historias:

- **"Ver notificaciones no leídas"**: CA1 indicador de no leído por canal, CA2 indicador de no
  leído por servidor (si al menos un canal tiene no leídos) y CA3 indicador destacado para las
  menciones (historia optativa, ya implementada del lado de `messaging` en #46).
- **"Silenciar notificaciones de un canal o servidor"** (HU #64): ver "Silenciar un canal o un
  servidor".
- **"Configurar preferencias de notificación"** (HU #65): ver "Preferencias de notificación".
- **"Centro de notificaciones con historial"** (HU #67): ver "Centro de notificaciones (historial)".
- **"Notificaciones push"** (HU #66): ver "Notificaciones push".

El servicio **no llama a ningún otro servicio por HTTP**: todo lo que sabe lo aprende
consumiendo eventos del bus (lo único que sale hacia afuera son los envíos a los servicios de
push, ver "Notificaciones push"). Lo que expone por REST es el ticket para abrir el WebSocket (ver
"Por qué hay un endpoint HTTP"), la configuración del propio usuario (silenciados y
preferencias) y la lectura de su historial.

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
- **Posición de un mensaje**: dónde está en la línea de tiempo del canal, como un texto que se
  ordena por tiempo: `"<milisegundos de occurred_at, con ceros>_<message_id>"`
  (`Notifications.Unread.Position`). **No se comparan ids de mensaje**: `messaging` genera
  ids ordenables por tiempo (UUIDv7) solo cuando el cliente no manda `client_id`; con
  `client_id` (lo que hacen las dos apps) el id es un hash (UUIDv5) sin orden. El
  `occurred_at` del evento es el `inserted_at` del mensaje; el id solo desempata dentro del
  mismo milisegundo.
- **Actividad por canal**: cada `messaging.message_created` guarda la posición del último
  mensaje del canal y la de los últimos 50 (para resolver `mark_read` con un `message_id`).
  El evento lleva solo ids (canal, mensaje, autor, mencionados), nunca el contenido.
- **Marcadores por usuario**: `read_markers` (hasta qué posición leyó) y `unread_mentions`
  (una entrada por cada mención todavía sin leer, con su posición). Leer un canal borra las
  menciones hasta la posición leída.
- **El estado se deriva comparando posiciones**: "hay no leídos" es
  `último_mensaje > hasta_donde_leí`, y la cantidad de menciones es cuántas menciones
  guardadas quedan después de `hasta_donde_leí`. Reprocesar un evento no cambia nada
  (idempotente).
- **Línea base**: lo que cuenta como leído es el máximo entre lo que el usuario marcó como
  leído y el momento en que se unió al servidor (`Position.floor(joined_at)`). Los mensajes
  anteriores a que entrara nunca aparecen como no leídos.
- **Tus propios mensajes** nunca te dejan un canal no leído, y además marcan como leído lo
  anterior (escribir en un canal implica haberlo visto).
- **Menciones**: si alguna mención es posterior a tu línea base, el canal se marca
  `mention: true` (además de `unread: true`) y `mention_count` dice cuántas son. El servidor
  hereda `mention` si alguno de sus canales lo tiene y suma sus `mention_count`.
- **Datos anteriores a las posiciones**: los documentos viejos (`last_message_id`,
  `last_read_id` y la colección `mention_markers`) se ignoran. Cada canal arranca como leído
  y vuelve a contar desde su próximo mensaje. `mention_markers` ya no se usa y se puede borrar.

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
- `GET /v1/notifications/history?limit=&before=` -- historial de menciones y mensajes directos,
  del más nuevo al más viejo (ver "Centro de notificaciones (historial)")
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
      "mention": true,
      "mention_count": 2,
      "notify": true,
      "muted": false,
      "channels": [
        { "channel_id": "…", "unread": true, "mention": true, "mention_count": 2, "notify": true, "muted": false }
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
mención pendiente que sigue contando como destacada, y `mention_count` cuántas son (es `0`
cuando `mention` es `false`, por ejemplo en un canal silenciado).

`unread_updated` -- cambió el estado de un canal (y de su servidor):

```json
{
  "server_id": "…",
  "channel_id": "…",
  "unread": true,
  "mention": true,
  "mention_count": 1,
  "notify": true,
  "muted": false,
  "server": { "unread": true, "mention": true, "mention_count": 3, "notify": true, "muted": false }
}
```

Solo se empuja cuando cambian los indicadores: un segundo mensaje en un canal que ya estaba
no leído no genera otro aviso (una mención nueva sí, porque cambia `mention_count`).

Eventos que manda el cliente:

| Evento | Payload | Respuesta |
|---|---|---|
| `mark_read` | `{"channel_id": "…", "message_id": "…"}` (`message_id` es opcional: sin él se lee hasta el último mensaje) | `ok`, o error `FORBIDDEN` / `CHANNEL_NOT_FOUND` / `UNREAD_UNAVAILABLE` |
| `mark_all_read` | `{}` | `{"channels": N}` con cuántos canales se limpiaron, o error `UNREAD_UNAVAILABLE`; después llega un `snapshot` (vacío) a todas las sesiones del usuario |
| `snapshot` | `{}` | `ok` y un nuevo `snapshot` |

`mark_read` nunca retrocede un marcador. El `message_id` puede ser cualquier UUID (v7 o el hash
v5 de los envíos con `client_id`; si no tiene formato de UUID responde `INVALID_PAYLOAD`), y se
resuelve así:

| `message_id` | Lee hasta |
|---|---|
| no viene | el último mensaje conocido del canal |
| uno de los últimos 50 mensajes conocidos | exactamente ese mensaje |
| uno que todavía no llegó por RabbitMQ | **ahora** (o el último conocido, si es posterior) |

El último caso existe porque el cliente ve el mensaje en vivo por `messaging` antes de que
`notifications` procese el evento: si se recortara al último mensaje conocido, el canal se
encendería como no leído justo después de leerlo.
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

### Notificaciones push

Avisa por fuera de la app (HU #66). Dos proveedores: **Web Push** (VAPID, para el navegador) y
**Expo Push Service** (para la app móvil; Android primero, iOS necesita una cuenta de Apple
Developer).

**Quién recibe un push** (se calcula con los mismos silenciados y niveles que el historial):

| Mensaje | Recibe push |
|---|---|
| Directo | Siempre el destinatario (si hay bloqueo, `messaging` ni siquiera lo envía). |
| En un canal, con mención | El mencionado, salvo canal o servidor silenciado o nivel `none`. |
| En un canal, sin mención | Solo quien tiene el nivel efectivo `all`, si además puede ver el canal. |

El autor nunca recibe el suyo, y silenciar siempre gana. Además se descartan:

- **Quien apagó el push** (`PUT /v1/notifications/push/settings`): un interruptor único, válido
  para todos sus dispositivos. No toca los indicadores ni el historial dentro de la app.
- **Quien tiene la app abierta**: `messaging` publica `messaging.user_presence_changed` cuando
  cambia su estado (conexión activa, inactiva o ninguna, y "No molestar"). Se guarda una réplica y
  no se manda push si hay una conexión **activa** en cualquier dispositivo, o si está en "No
  molestar". Inactiva (5 minutos sin interacción) o sin conexión recibe el push. Si no hay dato, o
  venció (6 horas), se asume app cerrada: se prefiere un aviso de más a perder uno.

**Qué dice el push.** Canal: título `Nombre en #canal`, cuerpo `Servidor · mensaje`. Directo:
título `Nombre`, cuerpo `mensaje`. El texto llega cortado (unos 140 caracteres) en el
propio evento y **no se guarda**; los nombres salen de réplicas alimentadas por
`users.profile_updated` y `servers.server_updated` (si faltan, "Usuario" y "Servidor"). El payload
incluye ids para abrir el lugar correcto: `kind` (`mention`, `message`, `direct_message` u `ownership_transfer`),
`message_id`, `author_id` y `server_id` + `channel_id` o `conversation_id`. En Expo, una llamada
que está sonando va con `categoryId: private_call_incoming`, que la app registra con los botones
Aceptar y Rechazar.

**Transferencia de propiedad.** `servers` publica `servers.ownership_transfer_updated` en cada
cambio de estado (foto completa: `transfer_id`, `server_id`, `from_user_id`, `to_user_id`, `status`,
`created_at`, `resolved_at`). Se aplica con la regla de `occurred_at` (una foto vieja o repetida
no pisa a una nueva; el reloj `transfer:<id>` dura 7 días) y deja entradas `ownership_transfer` en el
historial:

| `status` | Entrada en el historial | Push |
|---|---|---|
| `pending` | del receptor (`occurred_at` = creación) | al receptor: "Ana quiere transferirte la propiedad de Mi Server" |
| `accepted`, `rejected` | se actualiza la del receptor y aparece una para el dueño anterior | al dueño anterior: "Beto aceptó/rechazó ser el nuevo dueño de Mi Server" |
| `expired` | igual que arriba | al dueño anterior: "La transferencia de Mi Server venció sin respuesta" |
| `cancelled` | se actualiza la del receptor (queda cerrada) | ninguno |

El push no sigue los ajustes por canal ni por servidor (no es un mensaje): solo el interruptor
general y la regla de presencia. `message_id` de esa entrada es el id de la transferencia, y
`to_user_id` dice a quién se ofreció (si es quien consulta, es un ofrecimiento hecho a él; si no,
es la respuesta a su ofrecimiento).

**Dispositivos** (el token viaja solo en el cuerpo, nunca en la URL ni en los logs):

| Método y ruta | Qué hace |
|---|---|
| `POST /v1/notifications/push/devices` | Registra el dispositivo. `201 {id}` si es nuevo, `200 {id}` si ya estaba (pasa al usuario actual si estaba a nombre de otro). `409 DEVICE_LIMIT` pasados los 10 por usuario. |
| `DELETE /v1/notifications/push/devices/:id` | Lo quita (`204`, idempotente). El `id` es opaco, no contiene el token. |
| `GET` / `PUT /v1/notifications/push/settings` | Interruptor `{"enabled": bool}` (por defecto `true`). |
| `GET /v1/notifications/push/vapid-public-key` | Clave pública VAPID para `pushManager.subscribe` (`404` si el push web no está configurado). |

Cuerpo de registro: app `{"provider": "expo", "platform": "android" | "ios", "token":
"ExponentPushToken[...]"}`; navegador `{"provider": "webpush", "platform": "web", "endpoint": "...",
"p256dh": "...", "auth": "..."}`. El `endpoint` debe ser https de un servicio conocido
(`PUSH_ALLOWED_HOSTS`), para que nadie nos haga llamar a una dirección cualquiera.

**Cómo se envía.** El consumidor no espera a los servicios de push: arma el mensaje y lo deja en
tareas en segundo plano con tope (`max_concurrency`, 50); si hay demasiadas en vuelo se descartan
y se loguea. Por dispositivo: se reserva `evento + dispositivo` (colección `push_deliveries`, TTL
de 24 h) para no mandar dos veces si RabbitMQ repite el evento; `404`/`410` de Web Push y
`DeviceNotRegistered` de Expo borran el dispositivo; `429`/`5xx`/red se reintentan 3 veces con
espera creciente (respeta `Retry-After`); el resto queda anotado en `last_error`. Un fallo de push
**nunca** hace reintentar el evento, que ya cumplió con el no leído y el historial. Como la reserva
va antes del envío, si el nodo se cae justo en medio se pierde ese push (a lo sumo uno por
dispositivo), no se duplica.

**Editar y borrar.** Al editar un mensaje de canal, `notifications` compara las menciones nuevas con
las entradas que ya tiene del mensaje: quien queda mencionado y no tenía entrada la recibe (si su
silenciado y nivel lo permiten) y además le llega un push con `(editado)` al final del cuerpo y
`edited: true` en el payload; a quien dejó de estar mencionado se le quita la entrada; los demás no
se tocan, así que nadie recibe dos avisos por el mismo mensaje. Al borrar un mensaje (de canal o
directo) se borran sus entradas de todos los historiales. Un push que ya salió no se puede retirar.

**Qué no cubre.** No agrupa ni limita avisos (cada mensaje, un push). Las reacciones no generan push
ni entrada. Editar el texto de un mensaje directo no hace nada (no tiene menciones) y las pantallas
abiertas no se enteran en vivo de una entrada que aparece o desaparece por una edición o un borrado
hasta que recargan el centro de notificaciones. Los recibos de
entrega de Expo (errores de FCM posteriores al envío) no se consultan. Las credenciales de los
dispositivos se guardan sin cifrar en Mongo.

Para generar las claves VAPID: `mix push.gen_vapid`.

### Centro de notificaciones (historial)

Un solo lugar para repasar la actividad relevante sin buscarla canal por canal: **menciones** y
**mensajes directos** recientes del usuario.

```
GET /v1/notifications/history?limit=50&before=<next_cursor>

200 {
  "items": [
    { "kind": "mention", "message_id": "…", "author_id": "…", "occurred_at": "…",
      "server_id": "…", "channel_id": "…", "conversation_id": null },
    { "kind": "direct_message", "message_id": "…", "author_id": "…", "occurred_at": "…",
      "server_id": null, "channel_id": null, "conversation_id": "…" }
  ],
  "next_cursor": "…"
}
```

- **CA1 (listado cronológico con acceso directo):** `items` viene del más nuevo al más viejo
  (los ids de mensaje son UUIDv7, que ordenan por tiempo). Cada entrada trae los ids para abrir la
  conversación: `server_id` + `channel_id` (+ `message_id` para saltar al mensaje) en una mención y
  `conversation_id` en un mensaje directo. El cliente resuelve nombres y contenido con lo que ya
  tiene o con `messaging`: **el historial guarda solo ids, nunca el texto** (igual que los eventos).
- **CA2 (historial vacío):** si no hay nada, `items` es `[]` y `next_cursor` es `null`. Mostrar el
  aviso "no hay notificaciones" es del cliente.
- **Orden:** por el momento en que ocurrió el evento (`occurred_at`), del más nuevo al más viejo; si
  dos entradas tienen el mismo instante, desempata por `message_id`. **No se ordena por `message_id`**:
  `messaging` genera ids ordenables por tiempo (v7) solo cuando el cliente no manda `client_id`; con
  `client_id` (lo que hace el web-client al enviar) el id es un hash (v5) sin orden temporal.
- **Paginación:** `limit` de 1 a 100 (50 por defecto) y `before` con el `next_cursor` de la página
  anterior. `next_cursor` es un texto **opaco** (hoy `<milisegundos>_<message_id>`): se reenvía tal
  cual, sin interpretarlo. Es `null` cuando no quedan más. Un `limit` o `before` inválido es
  `400 INVALID_PAYLOAD`. Una página puede venir con menos entradas que `limit` (si se ocultaron
  menciones, ver abajo) y aun así traer `next_cursor`: hay que seguir pidiendo hasta que sea `null`.
- **Qué entra:** una mención entra si **avisa** para ese usuario según sus preferencias *en el
  momento en que llega*: un canal silenciado, o con nivel `none` (propio o heredado del servidor),
  no deja entrada. Las menciones ya vienen filtradas por `messaging` (solo quienes pueden ver el
  canal, sin el autor, con `@everyone` y roles ya resueltos). Un mensaje directo entra siempre al
  destinatario. Reactivar un canal **no** recupera lo que no se guardó mientras estaba silenciado.
- **Qué se oculta al leer:** las menciones de canales que el usuario ya no puede ver (perdió un rol,
  salió del servidor, el canal se borró). Al salir de un servidor o borrarse un canal/servidor, sus
  entradas también se borran.
- **Retención:** por defecto las entradas se conservan **siempre** (sin `expires_at`). Con
  `HISTORY_RETENTION_DAYS=N` (mayor a 0) cada entrada nueva dura `N` días contados desde el momento
  del mensaje y Mongo la borra solo (índice TTL en `expires_at`). Cambiar el valor no toca las entradas
  ya guardadas. Aunque no haya plazo, se borran al salir del servidor o al borrarse el canal/servidor.
- **Idempotente:** reprocesar un evento no duplica la entrada (`_id` = `usuario:mensaje`).
- Fuera de alcance: marcar entradas como leídas y avisar en vivo que llegó una (el cliente vuelve a
  pedir la lista al abrir el centro).

## Eventos que consume

Una única cola durable, `notifications.unread_state`, enlazada a `discordia.events` (topic):

| Routing key | Para qué |
|---|---|
| `messaging.message_created` | actividad del canal, menciones e historial (no se audita: es de alto volumen) |
| `messaging.direct_message_created` | historial del destinatario del mensaje directo (no se audita: es de alto volumen) |
| `messaging.message_updated` | edición de un mensaje de canal: agrega la entrada de quien quedó mencionado (y le manda un push "editado") y quita la de quien dejó de estarlo (no se audita: lleva texto) |
| `messaging.message_deleted` | borra de todos los historiales las entradas que apuntan al mensaje |
| `servers.ownership_transfer_updated` | cada cambio de estado de una transferencia de propiedad: deja una entrada en el historial y manda un push (ver "Transferencia de propiedad") |
| `messaging.user_presence_changed` | réplica de si el usuario tiene la app abierta, para decidir el push (no se audita) |
| `users.profile_updated` | nombre del autor para el texto del push (solo `user_id`, `name` y `version`; no se audita) |
| `servers.server_updated` | nombre del servidor para el título del push |
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
| `channel_activity` | `_id` = canal, `last_position` (`$max`), `recent` (los últimos 50 `{message_id, position}`) |
| `read_markers` | `_id` = `user:canal`, `last_read_position` (`$max`) |
| `unread_mentions` | `_id` = `user:mensaje`, `channel_id`, `server_id`, `message_id`, `position`; se borran al leer |
| `replica_servers`, `replica_roles`, `replica_members`, `replica_overrides` | réplica de permisos |
| `event_clocks` | relojes LWW y lápidas |
| `consumed_events` | auditoría de lo consumido |
| `notification_settings` | `_id` = `user:canal_o_servidor`, `scope` (`server`/`channel`), `scope_id`, `server_id`, `muted`, `level` (`all`/`mentions`/`none` o `null`) |
| `notification_history` | `_id` = `user:mensaje`, `user_id`, `kind` (`mention`/`direct_message`/`ownership_transfer`), `message_id` (en `ownership_transfer`, el id de la transferencia), `author_id`, `occurred_at`, `server_id`/`channel_id` o `conversation_id` (en `ownership_transfer`, también `to_user_id` y `transfer_status`), `expires_at` (TTL) |
| `socket_tickets` | tickets de un solo uso (TTL) |
| `replica_user_names`, `replica_server_names` | nombre por `user_id` (última `version`) y por `server_id` (último `occurred_at`) |
| `replica_presence` | `_id` = usuario, `connections` (`active`/`idle`/`none`), `do_not_disturb`, `version`, `expires_at` (TTL) |
| `push_settings` | `_id` = usuario, `enabled` (si no hay documento, está activado) |
| `push_devices` | `_id` opaco, `user_id`, `provider`, `platform`, `credential`, `credential_hash` (único), `created_at`, `last_used_at`, `last_error` |
| `push_deliveries` | `_id` = `evento:dispositivo`, `expires_at` (TTL): evita el doble envío |

Los índices se crean al arrancar (`Notifications.Unread.IndexSetup`, con reintentos).

## Variables de entorno

Ver `.env.example`.

| Variable | Descripción |
|---|---|
| `MONGO_URL` | conexión a Mongo |
| `MONGO_POOL_SIZE` | conexiones que mantiene el servicio |
| `RABBITMQ_URL` | conexión a RabbitMQ **sin barra final** (una barra es el vhost vacío y el broker rechaza la conexión). Con el puente de Tailscale: `amqp://USUARIO:CLAVE@127.0.0.1:5672` |
| `TS_AUTHKEY` | opcional: clave de autenticación de Tailscale (reusable y efímera). Si está definida, el contenedor entra a la tailnet y abre el puente hacia RabbitMQ |
| `RABBITMQ_TS_HOST` | IP o nombre Tailscale del RabbitMQ (obligatoria si hay `TS_AUTHKEY`) |
| `RABBITMQ_TS_PORT` | puerto de RabbitMQ en la tailnet (5672) |
| `RABBITMQ_LOCAL_PORT` | puerto local donde escucha el puente (5672) |
| `TS_HOSTNAME` | nombre del nodo en la tailnet (`discordia-notifications`) |
| `SECRET_KEY_BASE` | clave del endpoint (obligatoria en producción) |
| `CHECK_ORIGIN` | orígenes permitidos para el WebSocket (lista separada por comas, o `false`) |
| `HISTORY_RETENTION_DAYS` | días que se conserva cada entrada del historial; `0` o sin definir = para siempre (por defecto) |
| `VAPID_PRIVATE_KEY` | clave privada VAPID en base64url (`mix push.gen_vapid`). Sin ella no se envían pushes web |
| `VAPID_SUBJECT` | contacto que viaja en el JWT VAPID, por ejemplo `mailto:equipo@dominio` |
| `EXPO_ACCESS_TOKEN` | opcional: token de acceso de Expo (seguridad reforzada) |
| `EXPO_PUSH_URL` | opcional: URL de la API de Expo (por defecto la oficial) |
| `PUSH_MAX_DEVICES` | dispositivos máximos por usuario (10) |
| `PUSH_ALLOWED_HOSTS` | servicios de push web aceptados, como sufijos de host separados por comas |
| `LOG_LEVEL` | `debug`, `info`, `warning` o `error` |
| `LOG_SHIP_URL` | opcional: URL del Log API al que se envían los logs. En New Relic (cuenta de EE. UU.): `https://log-api.newrelic.com/log/v1`. Sin ella los logs solo salen por la salida estándar |
| `LOG_SHIP_API_KEY` | opcional: clave de ingesta para `LOG_SHIP_URL`. Si no está, se toma la `api-key` de `OTEL_EXPORTER_OTLP_HEADERS` |

## Logs

JSON, una línea por evento, con `service`, `request_id` y los ids relevantes. Nunca se
registra el query string (lleva el ticket) ni contenido de mensajes.

## Deploy (Render + Atlas)

La imagen es el `Dockerfile` del repo (release de Elixir, usuario sin privilegios, ~120 MB con Tailscale) y
`render.yaml` es el blueprint de Render. **No usa Supabase**: `notifications` no tiene outbox
ni Postgres, solo Mongo y RabbitMQ.

1. **Atlas (Mongo).** Creá un usuario con rol `readWrite` sobre la base `notifications` y
   habilitá en *Network Access* las IPs de salida de Render (están en el dashboard del
   servicio; para probar se puede abrir `0.0.0.0/0`). La URL lleva el nombre de la base:
   `mongodb+srv://USUARIO:CLAVE@cluster0.xxxxx.mongodb.net/notifications?retryWrites=true&w=majority`
   (si la clave tiene caracteres especiales, codificarla como URL). Con `mongodb+srv://` el
   servicio activa TLS verificado solo. Los índices se crean al arrancar.
2. **RabbitMQ (por Tailscale).** El RabbitMQ del proyecto corre en una VM y solo es alcanzable
   por la tailnet. Render no expone `/dev/net/tun`, así que la imagen corre `tailscaled` en modo
   userspace y un `socat` que reenvía `127.0.0.1:5672` al RabbitMQ con `tailscale nc`
   (`docker-entrypoint.sh`). En Render se definen `TS_AUTHKEY` (clave de Tailscale *Reusable* y
   *Ephemeral*), `RABBITMQ_TS_HOST` (IP o nombre Tailscale de la VM de RabbitMQ) y
   `RABBITMQ_URL=amqp://USUARIO:CLAVE@127.0.0.1:5672` (sin barra final y con un usuario propio,
   no `guest`). Si `TS_AUTHKEY` no está definida el contenedor arranca directo, como en local y
   en el CI. Si Tailscale no conecta, la app arranca igual y el consumidor reintenta. Usa **una
   sola conexión** a RabbitMQ.
3. **Render.** *New > Blueprint*, elegí el repo y completá `MONGO_URL`, `RABBITMQ_URL`, `TS_AUTHKEY`
   y `RABBITMQ_TS_HOST` (`SECRET_KEY_BASE` se genera solo). Render despliega cuando pasa el CI
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

## Trazas y métricas (OpenTelemetry)

El servicio manda trazas y métricas a cualquier backend que hable OTLP por HTTP (New Relic, Grafana Cloud, un colector propio). Está **apagado por defecto**: sin `OTEL_EXPORTER_OTLP_ENDPOINT` no se exporta nada y el servicio funciona igual.

| Variable | Para qué |
|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | URL base del backend. En New Relic (cuenta de EE. UU.): `https://otlp.nr-data.net` |
| `OTEL_EXPORTER_OTLP_HEADERS` | Credenciales, por ejemplo `api-key=<clave de licencia de ingesta>`. Es un secreto: va solo en las variables de entorno del despliegue, nunca en el repositorio |
| `OTEL_SERVICE_NAME` | Nombre con el que aparece el servicio (por defecto `notifications`) |

- **Pedidos HTTP:** un span por pedido (`Notifications.Tracing`), llamado como el patrón de la ruta (`PUT /v1/notifications/settings/servers/:server_id`). Solo guarda `http.request.method`, `http.route` y `http.response.status_code`: nunca el path real, la query string, headers ni la IP. Si el pedido trae un `traceparent`, la traza continúa desde ahí.
- **Eventos de RabbitMQ:** el consumidor de `notifications.unread_state` abre un span `<routing key> process` dentro de la traza que llega en la cabecera `traceparent` del mensaje; si el evento va a reintento, el span queda marcado como error. Si el mensaje no la trae, empieza una traza nueva.
- **Métricas HTTP:** el histograma `http.server.request.duration` (en segundos, temporalidad delta, exportado cada 60 s) lo registra `Notifications.Metrics` al terminar cada pedido, con `http.request.method`, `http.route` y `http.response.status_code`; si el estado es 5xx suma `error.type`. De ahí salen el throughput, la latencia y la tasa de errores del resumen de APM en New Relic. Los pedidos a rutas inexistentes se agrupan en la ruta `unmatched`.
- **Logs:** las líneas escritas mientras corre un pedido o un evento llevan `trace_id` y `span_id`.
- **Todavía sin instrumentar:** las consultas a Mongo, los canales de WebSocket y los envíos a Expo y a Web Push.

## Envío de logs (New Relic)

Además de la salida estándar, el servicio puede enviar sus logs al Log API de New Relic. Está **apagado por defecto**: solo se activa si hay `LOG_SHIP_URL` y una clave (`LOG_SHIP_API_KEY` o la `api-key` de `OTEL_EXPORTER_OTLP_HEADERS`).

- **Qué se envía:** las mismas entradas que salen por la salida estándar, con el mismo filtrado de datos sensibles (`token`, `ticket`, `content`, etc.) y solo los campos de metadata permitidos. `trace_id` y `span_id` viajan como `trace.id` y `span.id`, que es como New Relic enlaza cada log con su traza. El servicio se identifica con `service.name` (el valor de `OTEL_SERVICE_NAME`).
- **Cómo se envía:** `Notifications.Log.Shipper` junta las entradas en lotes de hasta 200 o cada 5 segundos, las comprime en gzip y las manda por HTTPS. Los pedidos no esperan al envío.
- **Si el backend falla:** reintenta con espera creciente (de 1 s hasta 60 s) ante errores de red, 408, 429 y 5xx; un lote rechazado de forma definitiva (por ejemplo 400 o 403) se descarta. La cola está acotada a 5.000 entradas: si se llena descarta las más viejas, para no crecer sin límite en memoria.
- **Sin bucles:** los avisos del propio envío (`log_shipping_failed`, `log_shipping_recovered`, `log_batch_discarded`, `log_entries_dropped`) salen por la salida estándar pero nunca se reenvían.
- **Al apagar:** intenta enviar lo que quedó pendiente durante unos 3 segundos.

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

`make ci` incluye el análisis estático de seguridad con [Sobelow](https://github.com/nccgroup/sobelow)
(`mix sobelow --config`, configurado en `.sobelow-conf`). Falla ante cualquier hallazgo, y el
mismo paso corre en el pipeline de GitHub, que bloquea el merge a `main`.

Se ignoran dos reglas, a propósito:
- `Config.HTTPS`: el TLS lo termina Render, delante de la aplicación.
- `Config.CSWH`: el `check_origin` del WebSocket se configura en `config/runtime.exs` con la lista
  de orígenes permitidos (`CHECK_ORIGIN`), no en la definición del socket.

## Pendiente / fuera de alcance
- Los eventos de suspensión de usuarios no se consumen (no cambian el estado de lectura).
- Los mensajes directos no encienden indicadores de no leído acá (eso lo lleva `messaging`); en
  `notifications` solo alimentan el historial.
- Publicar la imagen y desplegarla (secrets de Docker Hub y la VM) no está en este pipeline.
