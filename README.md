# Syner

Microservicios NestJS:

| Servicio | Puerto | Transporte | Persistencia |
| --- | --- | --- | --- |
| [`client-gateway`](client-gateway) | 3000 (HTTP, `/api`), el único publicado | gRPC hacia los microservicios | — |
| [`products-ms`](products-ms) | 3001 (gRPC, solo red interna de Docker) | gRPC + RabbitMQ | PostgreSQL (`products-db`) |
| [`orders-ms`](orders-ms) | 3002 (gRPC, solo red interna de Docker) | gRPC + RabbitMQ | PostgreSQL (`orders-db`) |
| [`auth-ms`](auth-ms) | 3003 (gRPC, solo red interna de Docker) | gRPC | MongoDB (`auth-db`) con Prisma 8 |

## Multitenancy

Syner es multitenant: varias **organizaciones** comparten los mismos servicios y bases de datos, y cada una ve solo sus datos.

- `auth-ms` es el plano de control: guarda las organizaciones, los usuarios y las **memberships** (el rol de un usuario dentro de una organización). Un usuario puede pertenecer a varias organizaciones con un rol distinto en cada una.
- El **superadmin** de la plataforma crea las organizaciones y sus miembros. No hay registro público. auth-ms lo crea al arrancar con `SUPERADMIN_NAME`, `SUPERADMIN_EMAIL` y `SUPERADMIN_PASSWORD` del `.env` (si ya existe un usuario con ese email no lo toca). El superadmin no trabaja dentro de ninguna organización: su token no sirve para productos ni órdenes.
- El JWT queda asociado a una sola organización. En cada request, el gateway toma el `organization_id` del token verificado por auth-ms, **nunca del body ni de la query**, y lo envía en cada llamada gRPC y en cada evento de la saga.
- products-ms y orders-ms usan una base compartida en la que cada fila lleva `organization_id`, con dos barreras:
  1. Los servicios filtran por `organization_id` y ejecutan cada consulta dentro de `PrismaService.withTenant()`. Un id de otra organización responde 404.
  2. **Row Level Security** de Postgres (política `tenant_isolation`): aunque una consulta olvide el filtro, la base no devuelve ni deja escribir filas de otra organización. Por eso los servicios se conectan con un rol sin superusuario (`*_DB_APP_USER`, creado por [`postgres-init/app-role.sh`](postgres-init/app-role.sh) la primera vez que arranca cada Postgres), y las migraciones corren con el owner (`MIGRATE_DATABASE_URL`).
- El mismo `codigo_sku` puede existir en dos organizaciones. Una orden de compra solo acepta productos de su propia organización: la saga rechaza cualquier otro.

Flujo de alta (todas las rutas requieren `Authorization: Bearer <token>` salvo el login):

```bash
POST /api/auth/login                         # { email, password, organization_id? } → { user, token, memberships }
POST /api/organizations                      # superadmin: { name, slug }
POST /api/organizations/:id/members          # superadmin: { email, role, name?, password? } (crea el usuario si el email no existe)
GET  /api/organizations/:id/members          # superadmin
PATCH /api/organizations/:id/status          # superadmin: { status: ACTIVE | SUSPENDED }
DELETE /api/organizations/:id/members/:userId
POST /api/auth/switch-organization           # { organization_id } → token para otra organización del usuario
GET  /api/auth/verify                        # usuario (con organization_id y role) y token renovado
PATCH /api/auth/users/:id/role               # owner de la organización activa: { role }
```

Al hacer login, un usuario con una sola organización recibe directamente el token de esa organización. Si pertenece a varias, recibe un token sin organización más la lista `memberships`, y elige una con `organization_id` en el login o con `switch-organization`. Un token sin organización responde 403 en productos, alertas y órdenes.

Roles, por organización:

| Rol | Permisos |
|---|---|
| `owner` | Todo dentro de su organización. Es el único que cambia roles en ella (no el suyo propio) |
| `admin` | Todo sobre productos, alertas y órdenes de compra (crear, editar, eliminar, cambiar estado) |
| `user` | Solo lectura de productos, alertas y órdenes de compra, más movimientos de stock (`POST /api/products/:id/stock`) |

auth-ms relee el usuario, la membership y la organización en cada request. Por eso un cambio de rol, una membership eliminada (401) o una organización suspendida (403) aplican de inmediato. Sin token la respuesta es 401, y con un rol sin permiso, 403.

Las organizaciones nuevas arrancan vacías. Para cargar el catálogo demo de productos en una de ellas:

```bash
docker exec -e SEED_ORGANIZATION_ID=<id de la organización> syner_products_ms pnpm prisma db seed
```

`products-ms` maneja el inventario: productos, historial de movimientos y alertas de stock bajo. `orders-ms` maneja las órdenes de compra. No se llaman entre sí: las órdenes de compra son una **saga asíncrona** sobre RabbitMQ (exchange topic `syner.events`):

```
gateway ─POST /api/purchase-orders─▶ orders-ms ── 202 EN_VALIDACION
orders-ms ──purchase-order.created (outbox)──▶ products-ms
products-ms ──purchase-order.product.validated | .rejected──▶ orders-ms
orders-ms: PENDIENTE | RECHAZADA (con motivo) | RECHAZADA por timeout

gateway ─PATCH /api/purchase-orders/update-status-purchase/:id─▶ orders-ms
  PENDIENTE → APROBADA | RECHAZADA (motivo obligatorio), APROBADA → RECIBIDA
orders-ms ──purchase-order.received (outbox)──▶ products-ms: entrada de stock + historial + alertas
```

## Infraestructura

`docker-compose.yml` levanta todo el sistema:

- **Postgres de órdenes** (`orders_database`, :5432, datos en `./postgres`).
- **Postgres de productos** (`products_database`, :5433, datos en `./postgres-products`).
- Los dos Postgres montan [`postgres-init/`](postgres-init) en `/docker-entrypoint-initdb.d`: al inicializar un directorio de datos vacío crean el rol de la app (`*_DB_APP_USER`, sin superusuario ni `BYPASSRLS`) con permisos CRUD sobre las tablas que creen las migraciones. Con un directorio de datos existente no se ejecuta.
- **MongoDB de auth** (`auth_database`, :27017, datos en `./mongo`). Corre como replica set de un nodo (`rs0`); el healthcheck lo inicializa en el primer arranque. Prisma 8 exige MongoDB >= 8.0.
- **RabbitMQ** (`syner_rabbitmq`, AMQP :5672, UI http://localhost:15672 con `guest`/`guest`, datos en `./rabbitmq-data`). Tiene `hostname` fijo porque RabbitMQ guarda sus datos en `mnesia/rabbit@<hostname>`.
- Los tres servicios NestJS.

Los Postgres, MongoDB y RabbitMQ tienen healthchecks; orders-ms, products-ms y auth-ms esperan a que estén `healthy`.

La topología de RabbitMQ está en [`rabbitmq/definitions.json`](rabbitmq/definitions.json) y se carga en cada arranque:

- el usuario `guest`
- los exchanges `syner.events` y `syner.dlx`
- las colas de trabajo `orders.saga-replies` (`purchase-order.product.validated`, `purchase-order.product.rejected`) y `products.purchase-orders` (`purchase-order.created`, `purchase-order.received`), con sus bindings
- las colas de mensajes fallidos `orders.saga-replies.dlq` y `products.purchase-orders.dlq`

Las colas de trabajo se declaran en el broker, y no solo en cada servicio, para que un evento publicado antes del primer arranque de su consumidor no se pierda. Los servicios vuelven a declararlas con los mismos argumentos (`x-dead-letter-exchange`, `x-dead-letter-routing-key`), así que ambos lados deben coincidir.

## Arranque

```bash
docker compose up -d --build     # la primera vez, o si cambian package.json / Dockerfile
docker compose up -d             # las siguientes
docker compose logs -f orders-ms  # logs de un servicio
docker compose down              # detener (los datos quedan en ./postgres, ./postgres-products, ./mongo y ./rabbitmq-data)
```

Los servicios corren en **modo desarrollo**:

- Se montan `src/` (y `prisma/`) de cada servicio, y `nest start --watch` recompila y reinicia al guardar un archivo.
- `node_modules` vive solo dentro de la imagen, porque las dependencias nativas (`grpc-tools`, `esbuild`) deben compilarse para Linux. Si agregas una dependencia, reconstruye con `--build`.
- Al arrancar, orders-ms y products-ms ejecutan `prisma generate` y `prisma migrate deploy` (como owner, con `MIGRATE_DATABASE_URL`). Después el servicio se conecta con el rol de la app (`DATABASE_URL`). auth-ms ejecuta `prisma contract emit` y `prisma db update --no-interactive` (crea o actualiza las colecciones `users`, `organizations` y `memberships`, sus validadores y sus índices únicos; un cambio destructivo hace fallar el arranque en vez de aplicarse). Para crear una migración, córrela en tu máquina (`pnpm prisma migrate dev`) y reinicia el contenedor.
- Las variables de `environment:` en `docker-compose.yml` apuntan a los nombres de servicio (`orders-db`, `products-db`, `auth-db`, `rabbitmq`, `orders-ms`, `products-ms`, `auth-ms`) y tienen prioridad sobre el `.env` de cada servicio. Los `.env` siguen apuntando a `localhost`.

Todos los valores de `environment:` de `docker-compose.yml` y `docker-compose.prod.yml` salen del `.env` de la raíz (ver `.env.template`): puertos y hosts de los microservicios, credenciales de los Postgres (owner y rol de la app: `DATABASE_URL` y `MIGRATE_DATABASE_URL` de products-ms y orders-ms se arman con ellas), `AUTH_DATABASE_URL`, `RABBITMQ_URL`, `JWT_SECRET` y el superadmin. Los hosts son los nombres de servicio del compose, así que si renombras un servicio cambia también su `*_MS_HOST`.

Para depurar un servicio fuera de Docker, detén su contenedor (`docker compose stop orders-ms`) y córrelo local con `pnpm start:dev`: usa Postgres y RabbitMQ por sus puertos publicados. El gateway en Docker no ve un servicio corriendo en tu máquina, así que en ese caso corre también el gateway local.

## Producción

`docker-compose.prod.yml` usa el `Dockerfile.prod` de cada servicio: imagen con `dist/` compilado y solo las dependencias de producción, sin montar `src/` ni watcher. El build corre los tests del servicio y falla si alguno falla.

Los cambios de base de datos corren antes como jobs de una sola ejecución, construidos con el target `migrate` del mismo `Dockerfile.prod` (que conserva el CLI de Prisma): `products-migrate` y `orders-migrate` (`migrate deploy` como owner) y `auth-migrate` (`db update --no-interactive`). Cada microservicio arranca solo cuando su job termina bien.

**Construye las imágenes servicio por servicio**, no todas a la vez:

```bash
docker compose -f docker-compose.prod.yml build auth-migrate
docker compose -f docker-compose.prod.yml build auth-ms
docker compose -f docker-compose.prod.yml build products-migrate
docker compose -f docker-compose.prod.yml build products-ms
docker compose -f docker-compose.prod.yml build orders-migrate
docker compose -f docker-compose.prod.yml build orders-ms
docker compose -f docker-compose.prod.yml build client-gateway
docker compose -f docker-compose.prod.yml up -d
```

Si lanzas todo a la vez (`docker compose -f docker-compose.prod.yml build`), los `pnpm install` en paralelo saturan el registro de npm y pnpm falla con `ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION` (`could not be checked against minimumReleaseAge (The operation was aborted due to timeout)`). Son timeouts contra el registro, no un error de los Dockerfiles ni del lockfile: vuelve a construir servicio por servicio.

El stack de producción usa los mismos nombres de contenedor y puertos que el de desarrollo, así que no pueden correr a la vez: `docker compose -f docker-compose.prod.yml up -d` reemplaza los contenedores de desarrollo (los datos se conservan), y `docker compose up -d --build` vuelve a desarrollo.

## Mensajes fallidos (DLQ)

Un mensaje de la saga que no se puede procesar (payload inválido o error repetido) termina en su cola `.dlq`. Para revisarlo o reintentarlo:

1. Abrir http://localhost:15672 → **Queues** → `*.dlq` → **Get messages**. El header `x-death` indica el motivo.
2. Para reprocesarlo: **Move messages** hacia la cola original (`orders.saga-replies` o `products.purchase-orders`).

Si cambias los argumentos de una cola (por ejemplo, el DLX), bórrala desde la UI antes de reiniciar el servicio. Si no, `assertQueue` falla con `PRECONDITION_FAILED`.

## Dev

1. Clonar el repositorio
2. Crear un .env basado en el .env.template (incluye las credenciales de los Postgres y de sus roles de app, `JWT_SECRET`, que firma los tokens de auth-ms, y las credenciales `SUPERADMIN_*` del superadmin). Postgres aplica las credenciales y crea el rol de la app solo al inicializar un directorio de datos vacío: si vienes de la versión single-tenant, detén el stack y borra `./postgres`, `./postgres-products` y `./mongo` antes del primer arranque (los datos anteriores no se migran)
3. Ejecutar el comando `git submodule update --init --recursive` para reconstruir los sub-módulos
4. Ejecutar el comando `docker compose up --build`


### Pasos para crear los Git Submodules

1. Crear un nuevo repositorio en GitHub
2. Clonar el repositorio en la máquina local
3. Añadir el submodule, donde `repository_url` es la url del repositorio y `directory_name` es el nombre de la carpeta donde quieres que se guarde el sub-módulo (no debe de existir en el proyecto)
```
git submodule add <repository_url> <directory_name>
```
4. Añadir los cambios al repositorio (git add, git commit, git push)
Ej:
```
git add .
git commit -m "Add submodule"
git push
```
5. Inicializar y actualizar Sub-módulos, cuando alguien clona el repositorio por primera vez, debe de ejecutar el siguiente comando para inicializar y actualizar los sub-módulos
```
git submodule update --init --recursive
```
6. Para actualizar las referencias de los sub-módulos
```
git submodule update --remote
```

## Importante
Si se trabaja en el repositorio que tiene los sub-módulos, **primero actualizar y hacer push** en el sub-módulo y **después** en el repositorio principal. 

Si se hace al revés, se perderán las referencias de los sub-módulos en el repositorio principal y tendremos que resolver conflictos.

