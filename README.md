# notifications

Servicio de notificaciones de Discordia.

## Tabla de contenidos

- [Introducción](#introducción)
- [Pre-requisitos](#pre-requisitos)
- [Cómo correr](#cómo-correr)
- [Variables de entorno](#variables-de-entorno)
- [Comandos Docker](#comandos-docker)
- [Tests](#tests)
- [Más documentación](#más-documentación)

## Introducción

`notifications` es el servicio que le avisa a cada usuario lo que se perdió y lo que cambió. Se divide en cuatro partes:

- **No leídos:** qué canales y servidores tienen mensajes sin leer, y cuáles tienen menciones. Sirve para los indicadores de la barra lateral.
- **Silencios y preferencias:** silenciar un canal o un servidor y elegir qué se quiere recibir (todo, solo menciones o nada).
- **Centro de notificaciones:** el historial de menciones, mensajes directos y ofrecimientos de transferencia de propiedad. Lo leído de las transferencias se guarda en el servidor (`POST /v1/notifications/history/transfers/read`), así que vale en todos los dispositivos del usuario.
- **Push y avisos en vivo:** notificaciones al navegador y al celular, y un aviso corto por WebSocket cada vez que algo cambia en otro servicio, para que las pantallas se actualicen sin recargar.

Está hecho en Elixir con Phoenix y guarda su estado en MongoDB. No llama a ningún otro servicio: todo lo que sabe lo aprende de los eventos de RabbitMQ (por eso RabbitMQ es obligatorio). Por ejemplo, para saber qué canales puede ver cada usuario guarda su propia copia de los permisos que publica `servers`.

Los clientes se conectan por WebSocket para recibir los cambios en vivo. Como el navegador no deja mandar headers en esa conexión, primero piden un ticket por REST (con su JWT, que valida el gateway) y después abren el socket con ese ticket, que vale una sola vez.

La API REST está descripta en [`openapi.yaml`](openapi.yaml).

## Pre-requisitos

- **Docker** y **Docker Compose** v2.24 o más nuevo.
- **RabbitMQ**, que se levanta con el repositorio [`rabbit-mq`](https://github.com/discordia-grupo01/rabbit-mq).
- **Elixir 1.16.2** y **Erlang 26.2.1**, solo si querés correr el servicio en tu máquina. El archivo `.tool-versions` los fija, y con [asdf](https://asdf-vm.com/) se instalan con `asdf install`.

## Cómo correr

### Con Docker Compose

Primero levantá RabbitMQ desde el repositorio `rabbit-mq`:

```bash
cd ../rabbit-mq
docker compose up -d
```

Después, en este repositorio, levantá el servicio con su base MongoDB:

```bash
docker compose up --build
```

Cuando termine de arrancar, comprobá que esté vivo:

```bash
curl http://localhost:4000/readyz
```

El servicio se conecta a RabbitMQ en `host.docker.internal:5672`, que desde un contenedor es tu máquina. Si lo levantaste en otro lado, completá `RABBITMQ_URL_DOCKER` en el `.env`.

Si querés cambiar puertos o la clave del servicio, copiá el archivo de ejemplo y editalo antes de levantar:

```bash
cp .env.example .env
```

Este compose levanta solo lo que es de este servicio. Para el sistema completo (con el gateway y los demás servicios) usá el compose del repositorio `infrastructure`.

### Para desarrollar

Si vas a tocar el código, te conviene correr el servicio en tu máquina (con recarga en caliente) y dejar en un contenedor solo la base:

```bash
cp .env.example .env
asdf install
mix local.hex --force && mix local.rebar --force
mix deps.get
docker compose up -d mongo
mix phx.server
```

Con el `.env` de ejemplo, el servicio se conecta a la base que acabás de levantar y a RabbitMQ en `localhost`.

## Variables de entorno

Se leen del entorno o de un archivo `.env`. El archivo [`.env.example`](.env.example) trae valores listos para correr en local.

| Variable | Default | Descripción |
|---|---|---|
| `SECRET_KEY_BASE` | obligatoria | Secreto de Phoenix. Se genera con `mix phx.gen.secret`. |
| `PORT` | `4000` | Puerto donde escucha el servicio. |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warning` o `error`. |
| `MONGO_URL` | `mongodb://localhost:27017/notifications_dev` | Conexión a MongoDB. En producción, Atlas. |
| `MONGO_POOL_SIZE` | `10` | Conexiones a Mongo por instancia. |
| `RABBITMQ_URL` | `amqp://guest:guest@localhost:5672` | Conexión a RabbitMQ, sin barra final (una barra es el vhost vacío y el broker rechaza la conexión). Obligatoria. |
| `CHECK_ORIGIN` | los dominios de la web | Orígenes permitidos para el WebSocket, separados por coma, o `false` para aceptar cualquiera. Solo en producción. |
| `HISTORY_RETENTION_DAYS` | `0` | Días que se conserva cada entrada del historial. `0` = para siempre. |
| `VAPID_PRIVATE_KEY` | vacío | Clave privada VAPID en base64url (se genera con `mix push.gen_vapid`). Sin ella no se envían pushes web. Es un secreto. |
| `VAPID_SUBJECT` | `mailto:contacto@discordia.example` | Contacto que viaja en el push web. |
| `EXPO_ACCESS_TOKEN` | vacío | Token de acceso de Expo, opcional. Es un secreto. |
| `EXPO_PUSH_URL` | la oficial de Expo | URL de la API de push de Expo, opcional. |
| `PUSH_MAX_DEVICES` | `10` | Dispositivos máximos por usuario. |
| `PUSH_ALLOWED_HOSTS` | los servicios de push conocidos | Servicios de push web aceptados, como sufijos de host separados por comas. |
| `TS_AUTHKEY` | vacío | Clave de Tailscale. Si está, el contenedor entra a la red privada y abre un puente hacia RabbitMQ. Solo en producción. |
| `RABBITMQ_TS_HOST` | vacío | IP o nombre Tailscale de RabbitMQ. Obligatoria si hay `TS_AUTHKEY`. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | vacío | Backend OpenTelemetry (por ejemplo New Relic). Vacío = sin trazas ni métricas. |
| `OTEL_EXPORTER_OTLP_HEADERS` | vacío | Credenciales del backend. Es un secreto. |
| `LOG_SHIP_URL` | vacío | Si se completa, también manda los logs a New Relic. |

Variables que usa solo `docker-compose.yml`:

| Variable | Default | Descripción |
|---|---|---|
| `API_PORT` | `4000` | Puerto del servicio en tu máquina. |
| `MONGO_PORT` | `27017` | Puerto de MongoDB en tu máquina. |
| `RABBITMQ_URL_DOCKER` | `amqp://guest:guest@host.docker.internal:5672` | Conexión a RabbitMQ para el servicio que corre dentro del compose. |

## Comandos Docker

Todos desde la raíz del repositorio.

| Qué querés hacer | Comando |
|---|---|
| Levantar todo | `docker compose up --build` |
| Levantar todo en segundo plano | `docker compose up -d --build` |
| Levantar solo la base | `docker compose up -d mongo` |
| Ver los logs del servicio | `docker compose logs -f api` |
| Ver qué está corriendo | `docker compose ps` |
| Reconstruir solo el servicio | `docker compose up -d --build api` |
| Abrir una consola de MongoDB | `docker compose exec mongo mongosh notifications_dev` |
| Bajar todo, conservando los datos | `docker compose down` |
| Bajar todo y borrar los datos | `docker compose down -v` |

Para construir y correr la imagen a mano:

```bash
docker build -t notifications .
docker run --rm -p 4000:4000 --env-file .env notifications
```

Dentro de un contenedor, `MONGO_URL` y `RABBITMQ_URL` no pueden apuntar a `localhost`: tienen que usar el nombre del contenedor o `host.docker.internal`.

## Tests

Los tests unitarios no necesitan nada más:

```bash
mix test --cover
```

Los de integración usan MongoDB y RabbitMQ reales y se saltean solos si faltan las variables. Para correrlos todos, con RabbitMQ levantado desde el repositorio `rabbit-mq`:

```bash
docker compose up -d mongo

MONGO_URL=mongodb://localhost:27017/notifications_test \
RABBITMQ_URL=amqp://guest:guest@localhost:5672 \
MIX_ENV=test mix coveralls
```

El CI exige una cobertura mínima del 70 % y corre con las dos infraestructuras levantadas.

El código se revisa con `make format`, `make lint` y `make dialyzer`. `make ci` corre lo mismo que el CI. Activá el hook de formato una vez por clon:

```bash
git config core.hooksPath .githooks
```

### Tests de contrato
Schemathesis (`4.33.4`) corre `openapi.yaml` contra el servicio real, con Mongo y RabbitMQ
locales: un 5xx, un status no declarado o una respuesta que no cumple el esquema hacen fallar
la corrida. El WebSocket queda fuera (es REST solamente).

```bash
python -m venv .contract-venv
.contract-venv/bin/pip install schemathesis==4.33.4   # en Windows: .contract-venv/Scripts

make contract-deps-up    # Mongo (55527) y RabbitMQ (55517) en contenedores contract-notifications-*
make contract-test       # arranca el servicio en 18087, corre Schemathesis y lo apaga
make contract-deps-down
```

- El servicio arranca con `MIX_ENV=prod` y secretos de juguete. La identidad sale del `sub` de un
  JWT sin firma (el servicio no verifica la firma). La clave VAPID es de juguete (no es un
  secreto) para que `GET /push/vapid-public-key` responda 200; no hay claves de Expo y en la
  corrida no hay eventos, asi que no se envia ningun push.
- `scripts/contract-test.sh` se niega a correr si `MONGO_URL` o `RABBITMQ_URL` no apuntan a
  `localhost`/`127.0.0.1`. Se ajusta con `APP_PORT`, `CONTRACT_MAX_EXAMPLES` (50; 25 en el CI),
  `CONTRACT_SEED` (1) y `CONTRACT_REPORT_DIR` (`contract-report/`, con el reporte JUnit y el log).
- `CONTRACT_APP_MODE=docker` arranca el servicio dentro de un contenedor `elixir:1.16` en vez
  de usar el `mix` local; sirve si el Erlang instalado es muy nuevo para compilar las
  dependencias (el CI usa Elixir 1.16 / OTP 26).
- Camino feliz: `scripts/contract/seed.js` siembra en Mongo un servidor, una membresia y un
  canal (y limpia los dispositivos push, que tienen un tope de 10 por usuario) y un hook
  (`scripts/contract/hooks.py`) usa esos ids en la mitad de los casos de `settings`. Al final
  `scripts/contract/coverage.py` cuenta con el HAR de Schemathesis cuantas operaciones
  obtuvieron un 2xx real y el script falla si alguna no (hoy 13 de 13).
- Excepcion documentada: Cowboy responde 501 a `TRACE` antes de llegar a Phoenix, asi que se
  acepta ese 501 y se apaga el check `unsupported_method` (ver `scripts/contract/schemathesis.toml`).
- Si el contrato cambia (specs de `open_api_spex`), regeneralo con `make openapi`.

## Más documentación

En este repositorio:

- [`docs/historias-de-usuario.md`](docs/historias-de-usuario.md): las historias del catálogo que resuelve este servicio.
- [`openapi.yaml`](openapi.yaml): contrato de la API REST. Se genera con `make openapi`, no se edita a mano.

En el repositorio [`docs`](https://github.com/discordia-grupo01/docs):

- [`asyncapi`](https://github.com/discordia-grupo01/docs/tree/main/asyncapi): los eventos que este servicio consume.
