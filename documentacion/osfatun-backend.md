# OSFATUN Backend — Guía de despliegue en Kubernetes

Guía para desplegar el backend Django (API REST) en el cluster K3s de OSFATUN.

El backend se compone de cuatro workloads:

| Componente | Tipo | Réplicas | Función |
|------------|------|----------|---------|
| **backend** | Deployment | 1+ (escalable) | Django + Gunicorn — sirve la API REST |
| **celery-worker** | Deployment | 1+ (escalable) | Procesa tareas asíncronas (sync, emails, etc.) |
| **celery-beat** | Deployment | **siempre 1** | Scheduler de tareas periódicas |
| **redis** | Deployment | 1 | Broker de Celery y cache de Django |

Todos los recursos se crean en el namespace `osfatun-backend`.

---

## Prerequisitos

- Cluster K3s funcionando con cert-manager, Pomerium y CloudNativePG desplegados (pasos 0–7 del README principal).
- Imagen Docker del backend publicada en un registry accesible (GitLab Container Registry, Docker Hub, etc.).
- Dominio DNS apuntando a la IP pública del cluster (ej: `api.osfatun.ticksar.com.ar`).

---

## Paso 1 — Crear la base de datos en PostgreSQL

CloudNativePG solo crea una base de datos en el bootstrap (`keycloak`). Para el backend necesitamos crear la base `osfatun` manualmente:

```bash
# Conectar al pod de PostgreSQL como superusuario
kubectl exec -it -n database main-db-1 -- psql -U postgres

# Dentro de psql:
CREATE DATABASE osfatun OWNER app;
\q
```

Verificar:

```bash
kubectl exec -it -n database main-db-1 -- psql -U app -d osfatun -c "SELECT 1;"
```

---

## Paso 2 — Construir y publicar la imagen Docker

El repositorio incluye un CI/CD en GitLab que construye la imagen automáticamente. Si se necesita hacer manualmente:

```bash
cd osfatun-backend/

# Build de la imagen de producción
docker build -f docker/Dockerfile --target django-production -t registry.gitlab.com/<ORG>/osfatun-backend:v1.0.0 .

# Push al registry
docker login registry.gitlab.com
docker push registry.gitlab.com/<ORG>/osfatun-backend:v1.0.0
```

---

## Paso 3 — Configurar el manifiesto

Editar `osfatun-backend.yaml` y reemplazar **todos** los valores `CHANGE_ME_*`:

### 3.1 — Pull Secret (registry de imágenes)

Generar el secret para autenticarse contra el registry:

```bash
kubectl create secret docker-registry gitlab-registry \
  --namespace=osfatun-backend \
  --docker-server=registry.gitlab.com \
  --docker-username=<USUARIO_O_DEPLOY_TOKEN> \
  --docker-password=<TOKEN> \
  --dry-run=client -o yaml
```

Copiar el valor de `.dockerconfigjson` de la salida y pegarlo en el manifiesto, o aplicar el secret por separado.

### 3.2 — Credenciales de base de datos

El campo `POSTGRES_PASSWORD` en `backend-db-credentials` **debe coincidir** con el password configurado en `cloudnativepg.yaml` (`main-db-app-credentials`).

### 3.3 — SECRET_KEY de Django

Generar una clave segura:

```bash
python -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())"
```

### 3.4 — Imagen del backend

Reemplazar `CHANGE_ME_REGISTRY/osfatun-backend:latest` en los **tres** Deployments (backend, celery-worker, celery-beat) por la ruta real de la imagen. Ejemplo:

```
registry.gitlab.com/org/osfatun-backend:v1.0.0
```

### 3.5 — Dominio

Ajustar `api.osfatun.ticksar.com.ar` en el Ingress y en las variables `ALLOWED_HOSTS`, `CORS_ORIGIN_WHITELIST` y `CSRF_TRUSTED_ORIGINS`.

### 3.6 — SECURE_SSL_REDIRECT

El manifiesto ya viene con `SECURE_SSL_REDIRECT: "False"`. Esto es correcto porque **Pomerium termina TLS** antes de llegar al backend. Si se cambia a `True`, Django intentará redirigir a HTTPS en un loop infinito.

### 3.7 — Variables opcionales

Las variables de Email, Sentry, WhatsApp, Sistema Externo y Webhooks pueden dejarse con valores placeholder si esas integraciones no están activas aún. El backend arrancará igual.

---

## Paso 4 — Desplegar

```bash
kubectl apply -f osfatun-backend.yaml

# Verificar que todos los pods estén corriendo
kubectl get pods -n osfatun-backend -w

# Esperar a que el backend esté ready
kubectl wait --for=condition=Available deployment/backend -n osfatun-backend --timeout=300s
```

El script de inicio del backend (`start.prod`) ejecuta automáticamente:
1. Espera a que PostgreSQL esté disponible
2. `python manage.py migrate --noinput`
3. `python manage.py collectstatic --noinput --clear`
4. Inicia Gunicorn

### Verificar logs

```bash
# Backend
kubectl logs -n osfatun-backend deployment/backend -f

# Celery Worker
kubectl logs -n osfatun-backend deployment/celery-worker -f

# Celery Beat
kubectl logs -n osfatun-backend deployment/celery-beat -f

# Redis
kubectl logs -n osfatun-backend deployment/redis -f
```

### Verificar el Ingress y certificado TLS

```bash
kubectl get ingress -n osfatun-backend
kubectl get certificate -n osfatun-backend
```

---

## Escalado y réplicas

### Backend (Django + Gunicorn)

El backend es stateless (no guarda estado en disco más allá de media). Se puede escalar horizontalmente:

```bash
# Escalar a 3 réplicas
kubectl scale deployment/backend -n osfatun-backend --replicas=3

# Verificar
kubectl get pods -n osfatun-backend -l app=osfatun-backend
```

El **Service** `backend` distribuye automáticamente el tráfico entre todas las réplicas (round-robin por defecto). Pomerium, como Ingress controller, envía el tráfico al Service, que a su vez lo balancea entre los pods.

**Consideraciones al escalar el backend:**

- **Migraciones:** El script `start.prod` ejecuta `migrate` en cada pod al iniciar. Django usa locks de base de datos para evitar conflictos, así que es seguro. Para un enfoque más limpio en producción, considerar ejecutar migraciones como un Job previo al deploy:
  ```bash
  kubectl run migrate --rm -it --restart=Never -n osfatun-backend \
    --image=REGISTRO/osfatun-backend:TAG \
    --overrides='{"spec":{"imagePullSecrets":[{"name":"gitlab-registry"}]}}' \
    -- python manage.py migrate --noinput
  ```
- **Media (PVC):** El PVC `backend-media` es `ReadWriteOnce`, lo que significa que solo un nodo puede montarlo. Si las réplicas están en el **mismo nodo**, funciona sin problema. Si se distribuyen en **múltiples nodos**, hay dos opciones:
  1. Cambiar a un StorageClass con `ReadWriteMany` (requiere NFS o similar).
  2. Migrar el almacenamiento de media a un servicio de objetos como S3 (recomendado para producción).
- **Static files:** Usan `emptyDir` (se regeneran en cada pod con `collectstatic`). No hay conflicto al escalar.
- **Sessions:** Si se usan sessions de Django, asegurar que el backend use `SESSION_ENGINE = 'django.contrib.sessions.backends.cache'` para que las sessions se almacenen en Redis (compartido) y no en la DB.

### Celery Worker

Los workers también se pueden escalar para procesar más tareas en paralelo:

```bash
kubectl scale deployment/celery-worker -n osfatun-backend --replicas=3
```

Cada worker adicional levanta `--concurrency=4` procesos. Con 3 réplicas se tendrían 12 procesos de Celery en total.

### Celery Beat

**NUNCA escalar más allá de 1 réplica.** Múltiples instancias de Beat duplicarían la programación de tareas, ejecutándolas N veces. El manifiesto ya tiene `strategy: Recreate` para evitar que coexistan dos pods durante un rolling update.

### Redis

Para el caso de uso actual (cache + broker de Celery), una sola instancia es suficiente. Si se necesita alta disponibilidad de Redis, considerar Redis Sentinel o Redis Cluster, o un operador como Spotahome/redis-operator.

---

## HorizontalPodAutoscaler (HPA)

Para escalar automáticamente basado en uso de CPU/memoria:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: backend-hpa
  namespace: osfatun-backend
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: backend
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
```

Requisito: tener metrics-server instalado en el cluster (K3s lo incluye por defecto).

```bash
# Verificar que metrics-server funciona
kubectl top pods -n osfatun-backend
```

---

## Actualizar la aplicación

Para desplegar una nueva versión:

```bash
# Opción 1: Cambiar la imagen directamente
kubectl set image deployment/backend -n osfatun-backend \
  backend=registry.gitlab.com/org/osfatun-backend:v1.1.0
kubectl set image deployment/celery-worker -n osfatun-backend \
  celery-worker=registry.gitlab.com/org/osfatun-backend:v1.1.0
kubectl set image deployment/celery-beat -n osfatun-backend \
  celery-beat=registry.gitlab.com/org/osfatun-backend:v1.1.0

# Opción 2: Editar el manifiesto y re-aplicar
# Actualizar la imagen en osfatun-backend.yaml y luego:
kubectl apply -f osfatun-backend.yaml
```

El Deployment del backend usa `RollingUpdate` con `maxUnavailable: 0`, lo que garantiza zero-downtime durante el deploy: primero levanta un pod nuevo, espera a que pase el readinessProbe, y luego termina el viejo.

---

## Comandos útiles

```bash
# Estado general
kubectl get all -n osfatun-backend

# Entrar al pod del backend (shell interactivo)
kubectl exec -it -n osfatun-backend deployment/backend -- bash

# Ejecutar comando Django
kubectl exec -it -n osfatun-backend deployment/backend -- python manage.py shell

# Crear superusuario
kubectl exec -it -n osfatun-backend deployment/backend -- python manage.py createsuperuser

# Ver eventos del namespace (útil para debugging)
kubectl get events -n osfatun-backend --sort-by='.lastTimestamp'

# Describir un pod con problemas
kubectl describe pod <NOMBRE_POD> -n osfatun-backend

# Reiniciar un deployment (nueva rollout)
kubectl rollout restart deployment/backend -n osfatun-backend

# Ver historial de rollouts
kubectl rollout history deployment/backend -n osfatun-backend

# Rollback a la versión anterior
kubectl rollout undo deployment/backend -n osfatun-backend

# Verificar conectividad a la DB desde un pod
kubectl exec -it -n osfatun-backend deployment/backend -- \
  python -c "import django; django.setup(); from django.db import connection; connection.ensure_connection(); print('OK')"

# Verificar conectividad a Redis
kubectl exec -it -n osfatun-backend deployment/redis -- redis-cli ping
```

---

## Troubleshooting

### El backend no arranca (CrashLoopBackOff)

```bash
kubectl logs -n osfatun-backend deployment/backend --previous
```

Causas comunes:
- **DB no accesible:** Verificar que el pod puede resolver `main-db-rw.database.svc.cluster.local` y que la base de datos `osfatun` existe.
- **Credenciales incorrectas:** El password en `backend-db-credentials` no coincide con `cloudnativepg.yaml`.
- **SECRET_KEY no configurada:** Django no arranca sin una SECRET_KEY válida.

### ImagePullBackOff

```bash
kubectl describe pod -n osfatun-backend -l app=osfatun-backend | grep -A5 "Events"
```

El secret `gitlab-registry` no está configurado correctamente o el token expiró. Regenerar con el comando de la sección 3.1.

### Certificado TLS no se emite

```bash
kubectl describe certificate backend-tls -n osfatun-backend
kubectl describe order -n osfatun-backend
kubectl logs -n cert-manager deployment/cert-manager
```

Verificar que el dominio apunta a la IP del cluster y que el challenge HTTP-01 es accesible desde internet.

### Celery no procesa tareas

```bash
# Ver workers activos
kubectl exec -it -n osfatun-backend deployment/backend -- \
  celery -A config inspect active

# Ver tareas en cola
kubectl exec -it -n osfatun-backend deployment/backend -- \
  celery -A config inspect reserved

# Purgar la cola (usar con cuidado)
kubectl exec -it -n osfatun-backend deployment/backend -- \
  celery -A config purge
```

---

## Arquitectura de red dentro del cluster

```
Internet
   │
   ▼
┌─────────────────────┐
│  Pomerium (Ingress)  │  ← TLS termination
│  api.osfatun....     │
└──────────┬──────────┘
           │ HTTP :8000
           ▼
┌─────────────────────┐     ┌──────────────────┐
│  Service: backend    │────▶│  Pod: backend    │ x N réplicas
│  (ClusterIP)         │     │  (Gunicorn)      │
└─────────────────────┘     └────────┬─────────┘
                                     │
                    ┌────────────────┼────────────────┐
                    │                │                │
           ┌───────▼──────┐ ┌───────▼──────┐ ┌───────▼──────────────┐
           │ Redis :6379   │ │ PostgreSQL   │ │ Celery Worker(s)     │
           │ (ns: osfatun- │ │ :5432        │ │ (misma imagen,       │
           │  backend)     │ │ (ns: database)│ │  distinto command)   │
           └───────────────┘ └──────────────┘ └───────────────────────┘
                    ▲                                    │
                    │           ┌─────────────────┐      │
                    └───────────│ Celery Beat      │◀────┘
                                │ (scheduler)      │
                                └─────────────────┘
```
