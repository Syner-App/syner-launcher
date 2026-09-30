# Syner

Microservicios NestJS:

| Servicio | Puerto | Transporte | Persistencia |
| --- | --- | --- | --- |
| [`client-gateway`](client-gateway) | 3000 (HTTP, `/api`), el único publicado | gRPC hacia los microservicios | — |
| [`products-ms`](products-ms) | 3001 (gRPC, solo red interna de Docker) | gRPC + RabbitMQ | PostgreSQL (`products-db`) |
| [`orders-ms`](orders-ms) | 3002 (gRPC, solo red interna de Docker) | gRPC + RabbitMQ | PostgreSQL (`orders-db`) |
| [`auth-ms`](auth-ms) | 3003 (gRPC, solo red interna de Docker) | gRPC | MongoDB (`auth-db`) con Prisma 8 |

`auth-ms` maneja los usuarios, la autenticación con JWT y los roles: `POST /api/auth/login` (público), `POST /api/auth/register`, `GET /api/auth/verify` (devuelve el usuario y un token renovado) y `PATCH /api/auth/users/:id/role` (`{ "role": "admin" }`). Todas las rutas salvo login requieren el header `Authorization: Bearer <token>`.

Roles:

| Rol | Permisos |
|---|---|
| `owner` | Todo el sistema. Es el único que cambia roles (no el suyo propio) y puede registrar usuarios de cualquier rol |
| `admin` | Todo sobre productos, alertas y órdenes de compra (crear, editar, eliminar, cambiar estado). Solo registra usuarios `user` |
| `user` | Solo lectura de productos, alertas y órdenes de compra, más movimientos de stock (`POST /api/products/:id/stock`) |

El primer `owner` lo crea auth-ms al arrancar con `OWNER_NAME`, `OWNER_EMAIL` y `OWNER_PASSWORD` del `.env` (si ya existe un usuario con ese email no lo toca). El rol se relee de la base en cada request, así que un cambio de rol aplica de inmediato. Sin token la respuesta es 401; con un rol sin permiso, 403.

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
- Al arrancar, orders-ms y products-ms ejecutan `prisma generate` y `prisma migrate deploy`. products-ms además corre `prisma db seed`, que carga los productos iniciales sin tocar los existentes. auth-ms ejecuta `prisma contract emit` y `prisma db update --no-interactive` (crea o actualiza la colección `users`, su validador y el índice único de `email`; un cambio destructivo hace fallar el arranque en vez de aplicarse). Para crear una migración, córrela en tu máquina (`pnpm prisma migrate dev`) y reinicia el contenedor.
- Las variables de `environment:` en `docker-compose.yml` apuntan a los nombres de servicio (`orders-db`, `products-db`, `auth-db`, `rabbitmq`, `orders-ms`, `products-ms`, `auth-ms`) y tienen prioridad sobre el `.env` de cada servicio. Los `.env` siguen apuntando a `localhost`.

Para depurar un servicio fuera de Docker, detén su contenedor (`docker compose stop orders-ms`) y córrelo local con `pnpm start:dev`: usa Postgres y RabbitMQ por sus puertos publicados. El gateway en Docker no ve un servicio corriendo en tu máquina, así que en ese caso corre también el gateway local.

## Mensajes fallidos (DLQ)

Un mensaje de la saga que no se puede procesar (payload inválido o error repetido) termina en su cola `.dlq`. Para revisarlo o reintentarlo:

1. Abrir http://localhost:15672 → **Queues** → `*.dlq` → **Get messages**. El header `x-death` indica el motivo.
2. Para reprocesarlo: **Move messages** hacia la cola original (`orders.saga-replies` o `products.purchase-orders`).

Si cambias los argumentos de una cola (por ejemplo, el DLX), bórrala desde la UI antes de reiniciar el servicio. Si no, `assertQueue` falla con `PRECONDITION_FAILED`.

## Dev

1. Clonar el repositorio
2. Crear un .env basado en el .env.template (incluye `JWT_SECRET`, que firma los tokens de auth-ms, y las credenciales `OWNER_*` del owner inicial)
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

