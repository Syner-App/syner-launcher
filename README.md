# Syner

Microservicios NestJS:

| Servicio | Puerto | Transporte | Persistencia |
| --- | --- | --- | --- |
| [`client-gateway`](client-gateway) | 3000 (HTTP, `/api`), el único publicado | gRPC hacia los microservicios | — |
| [`products-ms`](products-ms) | 3001 (gRPC, solo red interna de Docker) | gRPC + RabbitMQ | SQLite (`products-ms/data/dev.db`) |
| [`orders-ms`](orders-ms) | 3002 (gRPC, solo red interna de Docker) | gRPC + RabbitMQ | PostgreSQL |

`orders-ms` y `products-ms` no se llaman entre sí. La creación de órdenes es una **saga asíncrona** sobre RabbitMQ (exchange topic `syner.events`):

```
gateway ─POST /api/orders─▶ orders-ms ── 202 AWAITING_VALIDATION
orders-ms ──order.created (outbox)──▶ products-ms
products-ms ──order.products.validated | order.products.rejected──▶ orders-ms
orders-ms: PENDING (con precios) | REJECTED (con motivo) | REJECTED por timeout
```

## Infraestructura

`docker-compose.yml` levanta todo el sistema:

- **Postgres** (`orders_database`, :5432, datos en `./postgres`).
- **RabbitMQ** (`syner_rabbitmq`, AMQP :5672, UI http://localhost:15672 con `guest`/`guest`, datos en `./rabbitmq-data`). Tiene `hostname` fijo porque RabbitMQ guarda sus datos en `mnesia/rabbit@<hostname>`.
- Los tres servicios NestJS.

Postgres y RabbitMQ tienen healthchecks; orders-ms y products-ms esperan a que estén `healthy`.

La topología de RabbitMQ está en [`rabbitmq/definitions.json`](rabbitmq/definitions.json) y se carga en cada arranque:

- el usuario `guest`
- los exchanges `syner.events` y `syner.dlx`
- las colas de trabajo `orders.saga-replies` y `products.order-validation`, con sus bindings
- las colas de mensajes fallidos `orders.saga-replies.dlq` y `products.order-validation.dlq`

Las colas de trabajo se declaran en el broker, y no solo en cada servicio, para que un evento publicado antes del primer arranque de su consumidor no se pierda. Los servicios vuelven a declararlas con los mismos argumentos (`x-dead-letter-exchange`, `x-dead-letter-routing-key`), así que ambos lados deben coincidir.

## Arranque

```bash
docker compose up -d --build     # la primera vez, o si cambian package.json / Dockerfile
docker compose up -d             # las siguientes
docker compose logs -f orders-ms  # logs de un servicio
docker compose down              # detener (los datos quedan en ./postgres, ./rabbitmq-data y products-ms/data)
```

Los servicios corren en **modo desarrollo**:

- Se montan `src/` (y `prisma/`) de cada servicio, y `nest start --watch` recompila y reinicia al guardar un archivo.
- `node_modules` vive solo dentro de la imagen, porque las dependencias nativas (`better-sqlite3`, `grpc-tools`) deben compilarse para Linux. Si agregas una dependencia, reconstruye con `--build`.
- Al arrancar, orders-ms y products-ms ejecutan `prisma generate` y `prisma migrate deploy`. Para crear una migración, córrela en tu máquina (`pnpm prisma migrate dev`) y reinicia el contenedor.
- Las variables de `environment:` en `docker-compose.yml` apuntan a los nombres de servicio (`orders-db`, `rabbitmq`, `orders-ms`, `products-ms`) y tienen prioridad sobre el `.env` de cada servicio. Los `.env` siguen apuntando a `localhost`.

Para depurar un servicio fuera de Docker, detén su contenedor (`docker compose stop orders-ms`) y córrelo local con `pnpm start:dev`: usa Postgres y RabbitMQ por sus puertos publicados. El gateway en Docker no ve un servicio corriendo en tu máquina, así que en ese caso corre también el gateway local.

## Mensajes fallidos (DLQ)

Un mensaje de la saga que no se puede procesar (payload inválido o error repetido) termina en su cola `.dlq`. Para revisarlo o reintentarlo:

1. Abrir http://localhost:15672 → **Queues** → `*.dlq` → **Get messages**. El header `x-death` indica el motivo.
2. Para reprocesarlo: **Move messages** hacia la cola original (`orders.saga-replies` o `products.order-validation`).

Si cambias los argumentos de una cola (por ejemplo, el DLX), bórrala desde la UI antes de reiniciar el servicio. Si no, `assertQueue` falla con `PRECONDITION_FAILED`.

## Dev

1. Clonar el repositorio
2. Crear un .env basado en el .env.template
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

