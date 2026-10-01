# Syner

Microservicios NestJS y el frontend Next.js:

| Servicio | Puerto | Transporte | Persistencia |
| --- | --- | --- | --- |
| [`syner-app`](syner-app) | 3001 (HTTP, Next.js), publicado | HTTP hacia el gateway (BFF) + Socket.IO | — |
| [`client-gateway`](client-gateway) | 3000 (HTTP, `/api`), publicado | gRPC hacia los microservicios | — |
| [`products-ms`](products-ms) | 3001 (gRPC, solo red interna de Docker) | gRPC + RabbitMQ | PostgreSQL (`products-db`) |
| [`orders-ms`](orders-ms) | 3002 (gRPC, solo red interna de Docker) | gRPC + RabbitMQ | PostgreSQL (`orders-db`) |
| [`auth-ms`](auth-ms) | 3003 (gRPC, solo red interna de Docker) | gRPC | MongoDB (`auth-db`) con Prisma 8 |
| [`finance-ms`](finance-ms) | 3004 (gRPC, solo red interna de Docker) | gRPC + RabbitMQ | PostgreSQL (`finance-db`) |

## Multitenancy

Syner es multitenant: varias **organizaciones** comparten los mismos servicios y bases de datos, y cada una ve solo sus datos.

- `auth-ms` es el plano de control: guarda las organizaciones, los usuarios y las **memberships** (el rol de un usuario dentro de una organización). Un usuario puede pertenecer a varias organizaciones con un rol distinto en cada una.
- El **superadmin** de la plataforma crea las organizaciones y sus miembros. No hay registro público. auth-ms lo crea al arrancar con `SUPERADMIN_NAME`, `SUPERADMIN_EMAIL` y `SUPERADMIN_PASSWORD` del `.env` (si ya existe un usuario con ese email no lo toca). El superadmin no trabaja dentro de ninguna organización: su token no sirve para productos, órdenes ni finanzas.
- El JWT queda asociado a una sola organización. En cada request, el gateway toma el `organization_id` del token verificado por auth-ms, **nunca del body ni de la query**, y lo envía en cada llamada gRPC y en cada evento de la saga.
- products-ms, orders-ms y finance-ms usan una base compartida en la que cada fila lleva `organization_id`, con dos barreras:
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

Al hacer login, un usuario con una sola organización recibe directamente el token de esa organización. Si pertenece a varias, recibe un token sin organización más la lista `memberships`, y elige una con `organization_id` en el login o con `switch-organization`. Un token sin organización responde 403 en productos, alertas, órdenes y finanzas.

Roles, por organización:

| Rol | Permisos |
|---|---|
| `owner` | Todo dentro de su organización. Es el único que cambia roles en ella (no el suyo propio) y el único que toma las decisiones de dinero en finanzas: aportes, retiros, reserva, créditos nuevos, abonos extraordinarios, política y cierre de mes |
| `admin` | Todo sobre productos, alertas y órdenes de compra (crear, editar, eliminar, cambiar estado). En finanzas: gastos, insumos, recetas, cuentas por pagar, cuotas del crédito y reportes |
| `user` | Solo lectura de productos, alertas y órdenes de compra, más movimientos de stock (`POST /api/products/:id/stock`). En finanzas solo registra ventas y lee las recetas |

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

### Finanzas

`finance-ms` lleva la contabilidad, el flujo de caja y el punto de equilibrio del negocio de cada organización. No duplica a los otros servicios ni cambia sus reglas: los insumos y su stock siguen en products-ms, y las compras en orders-ms. finance-ms agrega solo lo que tiene que ver con dinero: costos en pesos, recetas, ventas, gastos, cuentas por pagar, crédito, retiros, reserva, la cascada del dinero, el punto de equilibrio y los escenarios. Ver [`finance-ms/README.md`](finance-ms/README.md).

```
gateway ─POST /api/finance/sales─▶ finance-ms: ingreso + finance.sale.registered (outbox)
finance-ms ──finance.sale.registered──▶ products-ms: salida de los insumos de la receta (todo o nada)
products-ms ──finance.sale.stock.applied | .rejected──▶ finance-ms (estado_stock de la venta)

orders-ms ──purchase-order.received──▶ products-ms (+stock) y finance-ms (cuenta por pagar)

finance-ms ──gRPC de solo lectura──▶ products-ms (stock) y orders-ms (órdenes abiertas): reposición en la cascada
```

finance-ms es el único servicio que llama a otro por gRPC, y solo para leer: cualquier cambio en el stock viaja como evento. Si products-ms u orders-ms no responden, la reposición se estima con las ventas promedio y el dashboard lo avisa.

## Infraestructura

`docker-compose.yml` levanta todo el sistema:

- **Postgres de órdenes** (`orders_database`, :5432, datos en `./postgres`).
- **Postgres de productos** (`products_database`, :5433, datos en `./postgres-products`).
- **Postgres de finanzas** (`finance_database`, :5434, datos en `./postgres-finance`).
- Los tres Postgres montan [`postgres-init/`](postgres-init) en `/docker-entrypoint-initdb.d`: al inicializar un directorio de datos vacío crean el rol de la app (`*_DB_APP_USER`, sin superusuario ni `BYPASSRLS`) con permisos CRUD sobre las tablas que creen las migraciones. Con un directorio de datos existente no se ejecuta.
- **MongoDB de auth** (`auth_database`, :27017, datos en `./mongo`). Corre como replica set de un nodo (`rs0`); el healthcheck lo inicializa en el primer arranque. Prisma 8 exige MongoDB >= 8.0.
- **RabbitMQ** (`syner_rabbitmq`, AMQP :5672, UI http://localhost:15672 con `guest`/`guest`, datos en `./rabbitmq-data`). Tiene `hostname` fijo porque RabbitMQ guarda sus datos en `mnesia/rabbit@<hostname>`.
- Los cinco servicios NestJS.
- **syner-app** (`syner_app`, http://localhost:3001): `next dev` con `src/` y `public/` montados. Sus route handlers llaman al gateway por la red de Docker (`GATEWAY_URL=http://client-gateway:3000/api`); el navegador abre el socket de notificaciones contra el gateway publicado (`SYNER_APP_PUBLIC_GATEWAY_URL`). En producción usa el build `standalone` de Next.js; `NEXT_PUBLIC_GATEWAY_WS_URL` se incrusta en el bundle al construir, así que si cambia `SYNER_APP_PUBLIC_GATEWAY_URL` hay que reconstruir la imagen.

Los Postgres, MongoDB y RabbitMQ tienen healthchecks; orders-ms, products-ms, auth-ms y finance-ms esperan a que estén `healthy`.

La topología de RabbitMQ está en [`rabbitmq/definitions.json`](rabbitmq/definitions.json) y se carga en cada arranque:

- el usuario `guest`
- los exchanges `syner.events` y `syner.dlx`
- las colas de trabajo, con sus bindings:
  - `orders.saga-replies` (`purchase-order.product.validated`, `purchase-order.product.rejected`)
  - `products.purchase-orders` (`purchase-order.created`, `purchase-order.received`, `finance.sale.registered`)
  - `finance.events` (`purchase-order.received`, `finance.sale.stock.applied`, `finance.sale.stock.rejected`)
- las colas de mensajes fallidos `orders.saga-replies.dlq`, `products.purchase-orders.dlq` y `finance.events.dlq`

Cada servicio consume del exchange con **una sola cola**. Con `wildcards: true`, el servidor RMQ de NestJS enlaza su cola a todos los patrones de los handlers RMQ de la app, así que una segunda cola del mismo servicio recibiría cada evento por duplicado.

Las colas de trabajo se declaran en el broker, y no solo en cada servicio, para que un evento publicado antes del primer arranque de su consumidor no se pierda. Los servicios vuelven a declararlas con los mismos argumentos (`x-dead-letter-exchange`, `x-dead-letter-routing-key`), así que ambos lados deben coincidir.

## Arranque

```bash
docker compose up -d --build     # la primera vez, o si cambian package.json / Dockerfile
docker compose up -d             # las siguientes
docker compose logs -f orders-ms  # logs de un servicio
docker compose down              # detener (los datos quedan en ./postgres, ./postgres-products, ./postgres-finance, ./mongo y ./rabbitmq-data)
```

Los servicios corren en **modo desarrollo**:

- Se montan `src/` (y `prisma/`) de cada servicio, y `nest start --watch` recompila y reinicia al guardar un archivo.
- `node_modules` vive solo dentro de la imagen, porque las dependencias nativas (`grpc-tools`, `esbuild`) deben compilarse para Linux. Si agregas una dependencia, reconstruye con `--build`.
- Al arrancar, orders-ms, products-ms y finance-ms ejecutan `prisma generate` y `prisma migrate deploy` (como owner, con `MIGRATE_DATABASE_URL`). Después el servicio se conecta con el rol de la app (`DATABASE_URL`). auth-ms ejecuta `prisma contract emit` y `prisma db update --no-interactive` (crea o actualiza las colecciones `users`, `organizations` y `memberships`, sus validadores y sus índices únicos; un cambio destructivo hace fallar el arranque en vez de aplicarse). Para crear una migración, córrela en tu máquina (`pnpm prisma migrate dev`) y reinicia el contenedor.
- Las variables de `environment:` en `docker-compose.yml` apuntan a los nombres de servicio (`orders-db`, `products-db`, `finance-db`, `auth-db`, `rabbitmq`, `orders-ms`, `products-ms`, `auth-ms`, `finance-ms`) y tienen prioridad sobre el `.env` de cada servicio. Los `.env` siguen apuntando a `localhost`.

Todos los valores de `environment:` de `docker-compose.yml` y `docker-compose.prod.yml` salen del `.env` de la raíz (ver `.env.template`): puertos y hosts de los microservicios, credenciales de los Postgres (owner y rol de la app: `DATABASE_URL` y `MIGRATE_DATABASE_URL` de products-ms, orders-ms y finance-ms se arman con ellas), `AUTH_DATABASE_URL`, `RABBITMQ_URL`, `JWT_SECRET`, el superadmin y `BUSINESS_TIMEZONE` (la zona horaria que decide el día, y por lo tanto el mes contable, de una venta o un gasto registrado sin `fecha`). Los hosts son los nombres de servicio del compose, así que si renombras un servicio cambia también su `*_MS_HOST`.

Para depurar un servicio fuera de Docker, detén su contenedor (`docker compose stop orders-ms`) y córrelo local con `pnpm start:dev`: usa Postgres y RabbitMQ por sus puertos publicados. El gateway en Docker no ve un servicio corriendo en tu máquina, así que en ese caso corre también el gateway local.

## Producción

`docker-compose.prod.yml` usa el `Dockerfile.prod` de cada servicio: imagen con `dist/` compilado y solo las dependencias de producción, sin montar `src/` ni watcher. El build corre los tests del servicio y falla si alguno falla.

Los cambios de base de datos corren antes como jobs de una sola ejecución, construidos con el target `migrate` del mismo `Dockerfile.prod` (que conserva el CLI de Prisma): `products-migrate`, `orders-migrate` y `finance-migrate` (`migrate deploy` como owner) y `auth-migrate` (`db update --no-interactive`). Cada microservicio arranca solo cuando su job termina bien.

**Construye las imágenes servicio por servicio**, no todas a la vez. [`build-prod.sh`](build-prod.sh) lo hace por ti: construye cada imagen en orden, empieza la siguiente solo cuando termina la anterior, reintenta cada build hasta 3 veces (`MAX_ATTEMPTS`) y al final ejecuta `up -d` (`--no-up` para solo construir):

```bash
./build-prod.sh
./build-prod.sh --no-up
MAX_ATTEMPTS=5 ./build-prod.sh
```

Equivale a:

```bash
docker compose -f docker-compose.prod.yml build auth-migrate
docker compose -f docker-compose.prod.yml build auth-ms
docker compose -f docker-compose.prod.yml build products-migrate
docker compose -f docker-compose.prod.yml build products-ms
docker compose -f docker-compose.prod.yml build orders-migrate
docker compose -f docker-compose.prod.yml build orders-ms
docker compose -f docker-compose.prod.yml build finance-migrate
docker compose -f docker-compose.prod.yml build finance-ms
docker compose -f docker-compose.prod.yml build client-gateway
docker compose -f docker-compose.prod.yml build syner-app
docker compose -f docker-compose.prod.yml up -d
```

Si lanzas todo a la vez (`docker compose -f docker-compose.prod.yml build`), los `pnpm install` en paralelo saturan el registro de npm y pnpm falla con `ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION` (`could not be checked against minimumReleaseAge (The operation was aborted due to timeout)`). Son timeouts contra el registro, no un error de los Dockerfiles ni del lockfile: vuelve a construir servicio por servicio.

El stack de producción usa los mismos nombres de contenedor y puertos que el de desarrollo, así que no pueden correr a la vez: `docker compose -f docker-compose.prod.yml up -d` reemplaza los contenedores de desarrollo (los datos se conservan), y `docker compose up -d --build` vuelve a desarrollo.

Las imágenes de los servicios que se descargan de Docker Hub las publica el CI de cada repo para `linux/amd64` y `linux/arm64` (incluye Mac con Apple Silicon). Si `up -d` avisa `no matching manifest for linux/arm64/v8`, la imagen `latest` es anterior a ese cambio: haz un push a `main` del servicio para que el CI la vuelva a publicar.

Si `up -d` falla con `failed to set up container networking: network <id> not found`, hay contenedores viejos que apuntan a una red que ya no existe. Bájalo todo y vuelve a levantarlo:

```bash
docker compose -f docker-compose.prod.yml down --remove-orphans
docker compose -f docker-compose.prod.yml up -d
```

## Mensajes fallidos (DLQ)

Un mensaje de la saga que no se puede procesar (payload inválido o error repetido) termina en su cola `.dlq`. Para revisarlo o reintentarlo:

1. Abrir http://localhost:15672 → **Queues** → `*.dlq` → **Get messages**. El header `x-death` indica el motivo.
2. Para reprocesarlo: **Move messages** hacia la cola original (`orders.saga-replies`, `products.purchase-orders` o `finance.events`).

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

