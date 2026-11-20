# Aviso al dueño cuando el staff elimina su servidor

> Diseño acordado el 2026-11-20. La decisión de arquitectura está en `docs/adr/045-aviso-al-dueno-de-servidor-eliminado.md`. Este documento cuenta cómo funciona de punta a punta.

## 1. El problema

Cuando el staff elimina un servidor desde el backoffice, el servidor desaparece de la lista de todos sus miembros. Para los miembros está bien así. Pero el **dueño** tiene que enterarse de que lo eliminó la plataforma, no quedarse buscando dónde fue a parar. La historia pide un modal parecido al de cuenta suspendida:

| CA | Qué pide | Estado antes del cambio |
|---|---|---|
| 1 | Al dueño le aparece un modal que dice que su servidor fue eliminado, con el nombre | ❌ el front no tiene cómo saber que lo borró el staff |
| 2 | Si estaba desconectado, lo ve al volver a entrar | ❌ no queda nada guardado |
| 3 | El resto de los miembros sigue como hasta ahora | ✅ el servidor sale de la lista con `server_left` |

Textos del modal:

| | Texto |
|---|---|
| Título | Tu servidor fue eliminado |
| Cuerpo | El equipo de la plataforma eliminó el servidor *{nombre}*. Esta acción no se puede deshacer. |
| Botón | Entendido |

El motivo de la eliminación no viaja en ningún evento (minimización de datos), así que el modal no lo muestra.

## 2. Por qué el front no se podía enterar

Hay que distinguir dos tipos de mensajes:

- Un **evento** viaja por RabbitMQ, el "correo interno" entre servicios del back. Las apps no lo leen.
- Las apps hablan con el back por **REST** (preguntan y el back responde) o por **WebSocket** (una conexión abierta por la que el back les puede avisar algo cuando quiere).

Así funcionaba el borrado:

```
backoffice ──DELETE──► admin ──admin.server_deletion_requested──► servers
                                                                    │ borra todo
                                                                    ├─ servers.member_left (uno por miembro)
                                                                    └─ servers.server_deleted
                                                                           │
                                         messaging ◄──────────────────────┘
                                             │
                                             └─ "server_left" ──► sala user:<id> de cada miembro
```

El problema es que `server_left` es el mismo aviso que llega cuando el dueño borra su propio servidor o cuando alguien se va. Ninguno de esos mensajes dice "lo borró el staff". Y si el dueño estaba desconectado, el aviso por socket se pierde: nadie se lo guarda.

## 3. Cómo funciona ahora en el back

### 3.1 Admin publica dos eventos en la misma transacción

Ana es staff y elimina el servidor "Club de Lectura" de Beto. `admin` registra el pedido y escribe **dos** eventos en su outbox, en la misma transacción:

- `admin.server_deletion_requested`, el de siempre. Es el que `servers` usa para borrar y no cambia.
- `admin.server_deletion_notice`, el nuevo. Lleva `server_id`, `owner_id` (Beto) y `server_name` ("Club de Lectura").

El **outbox** es una tabla donde el servicio anota los eventos a publicar dentro de la misma transacción que el cambio. Después un proceso aparte los manda a RabbitMQ (ADR-018). Así, o quedan el pedido y los dos eventos, o no queda nada.

Admin ya sabe el dueño y el nombre porque guarda una copia de cada servidor para el listado del backoffice (`servers.server_updated`).

Dónde pasa: `admin/internal/service/server_moderation_service.go` (`Delete`) arma y firma los dos eventos, y `admin/internal/repository/server_moderation_repo.go` (`RequestDeletion`) los escribe en el outbox.

### 3.2 El evento va firmado

Cualquiera con las credenciales de RabbitMQ podría publicar un evento falso. Por eso todos los eventos de `admin` llevan una **firma HMAC**: un código calculado con un secreto que solo tienen admin y quienes verifican. Si alguien cambia un campo, la firma ya no coincide (ADR-041).

Se firman `routing_key`, `event_id`, `server_id`, `owner_id`, `server_name` y `occurred_at`. El dueño y el nombre van firmados para que nadie pueda tomar un aviso válido y mandárselo a otra persona o con otro nombre.

Dónde pasa: `events-contract/admin/events.go` (`ServerDeletionNotice.Sign` y `Verify`) y su copia en Elixir en `events-contract/admin/events.ex` (`verify_server_deletion_notice/2`).

### 3.3 Notifications lo guarda

```
admin ──admin.server_deletion_notice──► notifications
                                            │ 1. verifica la firma
                                            │ 2. guarda el aviso en staff_notices
                                            └─ 3. "changed" {resource: "notices"} ──► sala user:<Beto>
```

1. Si la firma no verifica, descarta el evento y lo anota en la auditoría como `discarded_invalid_signature`. No se reintenta, porque nunca va a pasar a ser válido.
2. Guarda el aviso con id `<owner_id>:<server_id>`, **solo si no existe**. El staff puede repetir el pedido de borrado (es la forma de reintentar si algo se perdió). Con este id, un aviso que Beto ya vio no le vuelve a aparecer.
3. Le avisa a Beto por su sala personal que cambió el recurso `notices`, con el mismo mecanismo de "cambió esto, volvé a pedirlo" que usa el resto de notifications (ADR-032).

Dónde pasa: `notifications/lib/notifications/events/event.ex` reconoce el evento, `lifecycle.ex` lo aplica y `notifications/lib/notifications/notices.ex` lo guarda y lo lista.

### 3.4 Las apps lo piden por REST

| Endpoint | Qué hace |
|---|---|
| `GET /v1/notifications/notices` | Devuelve los avisos que el usuario todavía no vio |
| `POST /v1/notifications/notices/:id/seen` | Marca uno como visto |

El `GET` es el que resuelve el caso del dueño desconectado. Cuando vuelve a entrar, la app pregunta si tiene avisos pendientes, aunque no le haya llegado nada por el socket. El `POST` evita que el modal le aparezca cada vez que entra.

### 3.5 El caso completo

**Beto conectado.** Ana elimina "Club de Lectura". En unos segundos, a Beto le pasan dos cosas: el servidor desaparece de la barra (por `server_left`, como siempre) y le aparece el modal "Tu servidor fue eliminado". Toca "Entendido" y el modal no vuelve.

**Beto desconectado.** Ana elimina el servidor mientras Beto duerme. El aviso queda guardado en notifications. A la mañana, Beto abre la app, la app pide `GET /notices`, recibe el aviso y muestra el modal.

**Carla, miembro.** No recibe ningún aviso: el evento lleva solo al dueño. El servidor desaparece de su lista como hasta ahora.

**Ana repite el pedido.** Admin publica otro aviso, pero notifications ya tiene uno con el mismo id y no lo vuelve a insertar. Si Beto ya lo había visto, no le aparece de nuevo.

**Beto con dos dispositivos.** Le aparece en los dos. Si lo cierra en uno, el otro lo sigue mostrando hasta que lo cierre ahí también, o hasta que vuelva a pedir los avisos.

**Notifications caído.** El evento espera en la cola de RabbitMQ y se procesa cuando vuelve.

## 4. Cómo va a quedar en el front

### Lo que ve el dueño

Web y mobile hacen lo mismo:

1. Al entrar a la app, se piden los avisos pendientes.
2. Si llega el cambio `notices` por el socket de notifications, se vuelven a pedir.
3. Si hay alguno, aparece el modal con el nombre del servidor. Si hay varios, se muestran de a uno.
4. Al tocar "Entendido", se manda el `POST .../seen` y el modal se cierra. Si el `POST` falla, el modal se cierra igual y el aviso vuelve a aparecer la próxima vez que se pidan los avisos.

### Piezas nuevas

```
client-shared/src/
  domain/staff-notice.ts        tipo StaffNotice y resultados de las llamadas
  messages/staff-notice.ts      textos del modal
  domain/resource-change.ts     suma el recurso "notices"

web-client/src/
  app/api/notifications/notices/route.ts           BFF del GET
  app/api/notifications/notices/[id]/seen/route.ts BFF del POST
  services/notifications/service.ts                llamadas al Gateway (servidor)
  services/notifications/client.ts                 llamadas al BFF (navegador)
  components/home/hooks/useStaffNotices.ts         pide, escucha "notices" y marca visto
  components/home/ServerDeletedModal.tsx           el modal
  components/home/HomeShell.tsx                    monta el modal

app-mobile/src/
  features/notifications/api.ts                    llamadas al Gateway
  features/notifications/useStaffNotices.ts        mismo hook que en web
  features/servers/components/ServerDeletedModal.tsx el modal
  screens/HomeScreen.tsx                           monta el modal
```

El tipo, los textos y el nombre del recurso van en `client-shared` porque los usan las dos apps igual. El modal, el hook y las llamadas HTTP van en cada app porque dependen de la plataforma.

## 5. Hallazgos en el back

No hay bugs. Las observaciones son de diseño:

- El borrado por staff y el borrado del dueño son idénticos a propósito (`servers/internal/service/server_service.go`, `deletionEvents`). Por eso el aviso no podía salir de `servers`.
- Notifications no tenía `ADMIN_EVENTS_HMAC_SECRET`. Ahora lo necesita (`config/runtime.exs` e `infrastructure/docker-compose.yml`).
- Kong declara cada ruta de notifications por separado. Hay que sumar `/v1/notifications/notices` (`gateway/kong/kong.yml.template`).

## 6. Despliegue

- `events-contract` necesita un tag nuevo (el último es `v0.24.0`), y admin y notifications tienen que apuntar a él.
- Orden: **notifications antes que admin**. La cola de notifications se suscribe al evento nuevo al arrancar. Si admin lo publica antes, el aviso se pierde.

## 7. Referencia del contrato

### Evento `admin.server_deletion_notice`

| Campo | Tipo | Qué es |
|---|---|---|
| `event_id` | uuid | id del evento |
| `occurred_at` | fecha ISO 8601 UTC | momento del pedido de borrado |
| `server_id` | uuid | servidor eliminado |
| `owner_id` | uuid | dueño del servidor al momento del pedido |
| `server_name` | texto | nombre del servidor al momento del pedido |
| `signature` | hex | HMAC-SHA256 de `routing_key \n event_id \n server_id \n owner_id \n server_name \n occurred_at` |

Lo publica `admin` y lo consume `notifications`.

### `GET /v1/notifications/notices`

Requiere JWT. Si no se puede leer, responde `503 NOTICES_UNAVAILABLE` y la app no muestra nada hasta el próximo intento. Respuesta `200`:

```json
{
  "items": [
    {
      "id": "6f1c…",
      "kind": "server_deleted",
      "server_id": "0b7e…",
      "server_name": "Club de Lectura",
      "occurred_at": "2026-11-20T14:03:11Z"
    }
  ]
}
```

Los avisos vienen del más viejo al más nuevo. `id` es el `event_id` del aviso.

### `POST /v1/notifications/notices/:id/seen`

Requiere JWT. Responde `204` aunque el aviso no exista o ya estuviera visto, para que la app no tenga que distinguir esos casos. Un `id` que no es un UUID responde `400 INVALID_BODY`. Si no se puede guardar, responde `503 NOTICES_UNAVAILABLE`; el modal se cierra igual y el aviso vuelve a aparecer la próxima vez que se pidan los avisos.

### Qué está dónde

| Pieza | Dónde |
|---|---|
| Evento y firma (Go) | `events-contract/admin/events.go` |
| Firma (Elixir) | `events-contract/admin/events.ex` |
| Publicación | `admin/internal/service/server_moderation_service.go` (`Delete`) |
| Outbox | `admin/internal/repository/server_moderation_repo.go` (`RequestDeletion`) |
| Parseo y firma en notifications | `notifications/lib/notifications/events/event.ex` |
| Aplicación del evento | `notifications/lib/notifications/events/lifecycle.ex` |
| Guardado y listado | `notifications/lib/notifications/notices.ex` y `notices/repo/mongo.ex` |
| Endpoints | `notifications/lib/notifications_web/controllers/notices_controller.ex` |
| Ruta en el Gateway | `gateway/kong/kong.yml.template` (`notifications-notices`) |
