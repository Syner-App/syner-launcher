# Helm commands

* Crear configuración `helm create <nombre>`
* Aplicar configuración inicial: `helm install <nombre> .`
* Aplicar actualizaciones: `helm upgrade <nombre> .`

# K8s commands

* Obtener pods, deployments y services: `kubectl get <pods | deployments | services>`
* Revisar todos pods: `kubectl describe pods`
* Revisar un pod: `kubectl describe pod <nombre>`
* Eliminar pod: `kubectl delete pod <nombre>`
* Revisar logs: `kubectl logs <nombre>`



# Crear deployment:
```
kubectl create deployment <nombre> --image=<registro/url/imagen> --dry-run=client -o yaml > deployment.yml
```

# Crear service
```
kubectl create service clusterip <nombre> --tcp=<8888> --dry-run=client -o yaml > service.yml 
**kubectl create service nodeport <nombre> --tcp=<3000> --dry-run=client -o yaml > service.yml**
```
* **clusterip**: solo se puede acceder desde dentro del cluster
* **nodeport**: se puede acceder desde fuera del cluster


# Secrets

* Crear secretos, varios a la vez, o uno por uno.
```
kubectl create secret generic <nombre> --from-literal=key=value

kubectl create secret generic secret1 --from-literal=key1=value1 --from-literal=key2=value2
```
* Obtener los secretos `kubectl get secrets`
* Ver el contenido de un secreto `kubectl get secrets <nombre> -o yaml`

## Editar un secret
La forma más fácil es borrarlo y volverlo a crear pero si es más de un secret, no vamos a querer perder los demás.
Recordar que los secrets están en `base64`, por lo que si queremos editar un secret, debemos hacerlo en `base64`.

1. Editar el secret con `kubectl edit secret <nombre>` esto invocará el editor
2. Cambiar el valor (se puede usar un editor en [línea para convertir a base64](https://www.rapidtables.com/web/tools/base64-decode.html))
3. Tocar **i** para insertar líneas y editar el archivo
4. Poner el valor a decodificar en una nueva línea
5. Presionar **esc** y luego `:. ! base64 -D` para decodificar el valor
6. Presionar **i** para insertar o editar el valor
7. Presionar **esc** y luego `:. ! base64` para codificar el valor
8. Editar nuevamente el archivo **i** y dejar la línea en su posición
9. Presionar **esc** y luego **:wq** para guardar y salir



## Configurar secretos de Google Cloud para obtener las imágenes

1. Crear secreto:
```
kubectl create secret docker-registry gcr-json-key --docker-server=SERVIDOR-DE-GOOGLE-docker.pkg.dev --docker-username=_json_key --docker-password="$(cat 'PATH/DE/Tienda Microservices IAM.json')" --docker-email=TU_CORREO@gmail.com
```

2. Path del secreto para que use la llave:
```
kubectl patch serviceaccounts default -p '{ "imagePullSecrets": [{ "name":"gcr-json-key" }] }'
```


## Exportar y aplicar configuraciones con archivos (secrets en este caso)
* Para exportar los archivos de configuración

```
kubectl get secret <nombre> -o yaml > <nombre>.yml
```

* Aplicar la configuración basado en el archivo
```
kubectl create -f <nombre>.yml
```

# Despliegue del chart `syner`

## Desplegar todo
Desde la raíz del proyecto (`syner-launcher/`):
```
# 1. Crear/actualizar todos los Secrets a partir del .env de la raíz
./k8s/create-secrets.sh

# 2. Desplegar todo el chart: microservicios, gateway, syner-app, DBs, RabbitMQ y migraciones
helm upgrade --install syner ./k8s/syner --timeout 10m
```
* `upgrade --install` sirve tanto para el primer despliegue como para los siguientes, no hay que elegir entre `install` y `upgrade`.
* **No usar `--wait`**: el pod de `auth-ms` espera a que terminen las migraciones, y las migraciones (hooks post-install) esperan a que los pods estén listos, así que ninguno avanza (ver [Migraciones](#migraciones)). El `--timeout 10m` da margen a los Jobs de migración.
* El paso 1 solo hace falta la primera vez o cuando cambie el `.env` (ojo: también re-aplica `JWT_SECRET`).
* Con DB externa en vez de las del cluster: agregar `--set databases.inCluster=false`.

Ver el progreso:
```
kubectl get pods,jobs -w
helm list
```

## Conexiones gRPC
Cada microservicio (`products-ms:3001`, `orders-ms:3002`, `auth-ms:3003`, `finance-ms:3004`) tiene un Service **ClusterIP**: el gateway y finance-ms los llaman por nombre DNS dentro del cluster. NodePort solo se usa para lo que se abre fuera del cluster (`client-gateway`, `syner-app`, `rabbitmq-management`).

> Con más de 1 réplica, kube-proxy balancea **por conexión** y gRPC (HTTP/2) mantiene una sola conexión abierta, así que todo el tráfico iría a un pod. Para escalar: Service headless (`clusterIP: None`) + balanceo `round_robin` en el cliente gRPC, o un service mesh.

## Bases de datos
`values.yaml` → `databases.inCluster`:
* `true` (por defecto): el chart crea `orders-db`, `products-db`, `finance-db` (Postgres, StatefulSet + PVC) y `auth-db` (Mongo replica set `rs0`). El rol de la app (RLS) se crea con `files/postgres-init/app-role.sh` la primera vez que se inicializa el volumen.
* `false`: no se crea ninguna DB; las URLs de los Secrets apuntan a una DB gestionada (Cloud SQL, RDS, Atlas). Ej: `helm upgrade --install syner ./syner --set databases.inCluster=false`

### Crear los Secrets (recomendado)
`./create-secrets.sh` lee el `.env` de la raíz (los mismos valores que `docker-compose.prod.yml`) y crea o actualiza todos los Secrets del chart: `<x>-db`, `<x>-ms` (`DATABASE_URL`, `MIGRATE_DATABASE_URL`, `RABBITMQ_URL`), `auth-secrets` y `client-gateway`. Es idempotente (volver a correrlo tras cambiar `.env`) y no imprime valores. Otro archivo: `./create-secrets.sh ruta/.env`

> Ojo: re-aplica **todo** desde `.env`, incluido `JWT_SECRET`; si difiere del que tiene el cluster, los tokens emitidos dejan de ser válidos.

Los comandos manuales equivalentes, como referencia.

Secrets de cada Postgres (`<orders|products|finance>-db`):
```
kubectl create secret generic products-db \
  --from-literal=POSTGRES_USER=<owner> --from-literal=POSTGRES_PASSWORD=<pass> --from-literal=POSTGRES_DB=<db> \
  --from-literal=APP_DB_USER=<app_user> --from-literal=APP_DB_PASSWORD=<app_pass>
```

## Migraciones
Jobs `<ms>-migrate` (hooks `post-install,post-upgrade`) con la imagen `spadilla117/syner-<ms>-migrate` (target `migrate` de `Dockerfile.prod`, publicada por CI). Si un Job falla, falla el `helm install/upgrade`. Las migraciones deben ser compatibles hacia atrás (primero agregar, borrar en un release posterior) porque pods viejos y nuevos conviven durante el rollout.

Cada Secret de micro necesita la URL del **dueño de las tablas** para migrar, además de la del rol app:
```
# DATABASE_URL         = postgresql://<app_user>:<app_pass>@products-db:5432/<db>?schema=public
# MIGRATE_DATABASE_URL = postgresql://<owner>:<pass>@products-db:5432/<db>?schema=public
kubectl patch secret products-ms -p "{\"data\":{\"MIGRATE_DATABASE_URL\":\"$(printf '%s' 'postgresql://<owner>:<pass>@products-db:5432/<db>?schema=public' | base64)\"}}"
```
`auth-ms` tiene un initContainer (`wait-for-schema`) que espera a que `prisma db verify` confirme que Mongo ya coincide con el contrato: si arrancara antes, crearía el superadmin, Mongo crearía `users` implícitamente y `prisma db update` rechazaría agregar el validador a una colección con datos. Por eso **no usar `helm ... --wait`** con este chart: `--wait` espera a que los pods estén listos *antes* de los hooks post-install, y `auth-ms` espera al hook (bloqueo mutuo).

`orders-ms` también tiene un `wait-for-schema`: espera a que `prisma migrate status` no tenga migraciones pendientes. Si arrancara antes que el Job, Prisma consultaría columnas que todavía no existen (ej: `alert_id`), los gRPC de órdenes fallarían y los `alert.created` terminarían en `orders.saga-replies.dlq`.

`auth-ms-migrate` usa la `DATABASE_URL` de `auth-secrets` (ej: `mongodb://auth-db:27017/<db>?replicaSet=rs0`).

* Ver logs: `kubectl logs job/products-ms-migrate` (el Job se borra al terminar bien; si falla queda para revisarlo)
* Aplicar: `helm upgrade --install syner ./syner`

## Actualizar a una nueva versión
Los Deployments usan las imágenes sin tag (`:latest`), así que `helm upgrade` no cambia el spec de los pods y **no los recrea**: siguen con la imagen vieja. Para desplegar código nuevo:
1. Push de los submódulos cambiados a `main` y esperar a que CI publique `latest` (app y `-migrate`).
2. Aplicar el chart (topología de RabbitMQ, templates y Jobs de migración):
   ```
   helm upgrade --install syner ./k8s/syner --timeout 10m
   ```
3. Recrear los pods para que bajen la imagen nueva (`latest` usa `imagePullPolicy: Always`):
   ```
   kubectl rollout restart deployment orders-ms products-ms syner-app   # solo los que cambiaron
   kubectl rollout restart deployment                                    # o todos
   ```

## Bajar / apagar el despliegue

**1. Borrar todo el release** (Deployments, Services, ConfigMaps y Jobs del chart):
```
helm uninstall syner
```
* Los Secrets creados a mano con `kubectl create secret` **no** se borran: siguen ahí para el próximo install.
* Los volúmenes de las DBs (PVC de los StatefulSets) **tampoco** se borran, así los datos sobreviven a un reinstall. Para borrarlos a propósito (se pierden los datos): `kubectl delete pvc -l app=products-db` o `kubectl delete pvc --all`
* Volver a levantar: `helm install syner ./syner`

**2. Apagar sin borrar nada** (los pods se detienen, la configuración queda):
```
kubectl scale deployment --all --replicas=0
kubectl scale statefulset --all --replicas=0
```
* Volver a levantar: `kubectl scale deployment --all --replicas=1` (y lo mismo con `statefulset`), o `helm upgrade syner ./syner`, que devuelve las réplicas a lo que dice el chart.

**3. Apagar Kubernetes completo**: Docker Desktop → Settings → Kubernetes → desmarcar *Enable Kubernetes* (libera CPU y RAM).

Verificar que no queda nada corriendo:
```
kubectl get pods,deployments,statefulsets,services
helm list
```

> `kubectl delete pod <nombre>` no sirve para bajar un servicio: el Deployment lo vuelve a crear al instante.
