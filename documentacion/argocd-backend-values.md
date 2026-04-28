# ArgoCD — Planilla de values para OSFATUN Backend

Guía práctica para levantar cada instancia del backend (`prod`, `qa`, `dev`) en ArgoCD sin commitear datos sensibles al repositorio.

---

## Filosofía del chart

El chart `kubernetes/charts/osfatun-backend/` está diseñado así:

- **`values.yaml` (en Git)** — contiene defaults razonables para todo lo **no sensible** (hosts, puertos, resources, TTLs, rutas, tamaño de PVC, etc.). Los campos **sensibles** están declarados como `""` (cadena vacía) para forzar que se carguen en runtime.
- **`argocd/osfatun-backend.yaml` (en Git)** — template del `Application` CRD con **solo los `parameters` por-entorno NO sensibles** (imagen, dominio, DB name, Redis DB number, etc.).
- **Interfaz web de ArgoCD** — donde se cargan los **parameters sensibles**. Estos quedan guardados en el recurso `Application` del cluster (en etcd), **nunca en Git**.

### ¿Por qué ArgoCD UI para los secretos?

Cuando un `parameter` figura en `spec.source.helm.parameters` del Application YAML en Git, cualquiera con acceso al repo lo ve. Si se carga **solo** vía UI/CLI de ArgoCD:

- El valor queda en el `Application` CRD dentro del cluster (accesible solo con permisos sobre el namespace `argocd`).
- `kubectl apply -f argocd/osfatun-backend.yaml` **NO lo pisa**, siempre que:
  1. El YAML en Git no mencione ese parameter (nuestro caso), y
  2. Se use `ServerSideApply=true` en `syncOptions` (ya configurado).
- Si rotás la clave, actualizás en la UI y ArgoCD re-renderiza el Secret de Kubernetes en el próximo sync.

---

## Flujo recomendado (primer despliegue de un entorno)

1. **Crear la base de datos** en PostgreSQL:
   ```bash
   kubectl exec -it -n database main-db-1 -- psql -U postgres \
     -c "CREATE DATABASE <DB_NAME> OWNER app;"
   ```

2. **Ajustar el YAML del Application** (`argocd/osfatun-backend.yaml` o copia por entorno) con los parameters por-entorno NO sensibles. **Temporalmente** comentar el bloque `syncPolicy.automated` para crear la app en estado manual.

3. **Aplicar el Application**:
   ```bash
   kubectl apply -f argocd/osfatun-backend.yaml
   ```
   La app aparece en ArgoCD como `OutOfSync` y NO se sincroniza todavía.

4. **Cargar los parameters sensibles** desde la UI:
   `Applications → <app> → App Details (icono de engranaje) → PARAMETERS → EDIT`.
   Agregar uno a uno los de la sección **Parameters sensibles** más abajo.

5. **Sincronizar manualmente** (botón `SYNC`) y verificar que todos los pods pasan a `Running`.

6. **Volver a activar `syncPolicy.automated`** en el YAML y re-aplicar. A partir de ahora los secretos cargados por UI se conservan en cada sync.

---

## Planilla de `parameters`

Los nombres son exactamente los que esperás en la UI de ArgoCD (dot-notation del path en `values.yaml`).

### A. Parameters POR-ENTORNO (no sensibles) — van en el `Application` YAML

| Parameter | PROD | QA | DEV |
|-----------|------|----|----|
| `image.repository` | `registry.gitlab.com/org/osfatun-backend` | idem | idem |
| `image.tag` | `v1.0.0` (versión fija) | `qa-latest` | `dev-latest` |
| `django.envStage` | `PRODUCTION` | `QA` | `DEVELOPMENT` |
| `django.settingsModule` | `config.settings.production` | `config.settings.production` | `config.settings.development` |
| `django.debug` | `"False"` | `"False"` | `"True"` |
| `db.name` | `osfatun` | `osfatun_qa` | `osfatun_dev` |
| `redis.db` | `"0"` | `"1"` | `"2"` |
| `ingress.host` | `api.osfatun.ticksar.com.ar` | `api-qa.osfatun.ticksar.com.ar` | `api-dev.osfatun.ticksar.com.ar` |
| `cors.whitelist` | `https://api.osfatun.ticksar.com.ar` | `https://api-qa.osfatun.ticksar.com.ar` | `https://api-dev.osfatun.ticksar.com.ar` |
| `cors.trustedOrigins` | igual que `whitelist` | igual | igual |
| `email.defaultFrom` | `noreply@osfatun.ticksar.com.ar` | `qa-noreply@osfatun.ticksar.com.ar` | `dev-noreply@osfatun.ticksar.com.ar` |
| `keycloak.url` | `http://keycloak.keycloak.svc.cluster.local:8080` | idem | idem |
| `keycloak.frontendUrl` | `https://auth.osfatun.ticksar.com.ar` | idem | idem |
| `keycloak.realm` | `osfatun` | `osfatun-qa` *(si hay realm aparte)* | `osfatun-dev` *(idem)* |

> **Nota sobre dominios:** el chart actual usa `osfatun.ticksar.com.ar` pero `keycloak.yaml` tiene fijado `auth.osfatun.com.ar` en `KC_HOSTNAME`. Verificar cuál es el dominio real del IdP antes de setear `keycloak.frontendUrl`.

### B. Parameters SENSIBLES — SOLO en ArgoCD UI (nunca en Git)

> Agregarlos uno a uno en `Applications → <app> → App Details → PARAMETERS → EDIT`.

#### B.1 — Obligatorios para que arranque la app

| Parameter | Descripción | Cómo obtener |
|-----------|-------------|--------------|
| `db.password` | Password del user `app` en PostgreSQL. | Debe coincidir con `main-db-app-credentials` (`cloudnativepg.yaml`). |
| `django.secretKey` | `SECRET_KEY` de Django. Firma sessions, CSRF, JWT. **≥50 chars aleatorios.** | `python -c "from django.core.management.utils import get_random_secret_key; print(get_random_secret_key())"` |
| `imagePullSecret.dockerconfigjson` | `~/.docker/config.json` en base64 para que el cluster pueda pullear del registry privado. | `kubectl create secret docker-registry tmp --docker-server=registry.gitlab.com --docker-username=<USER> --docker-password=<TOKEN> --dry-run=client -o jsonpath='{.data.\.dockerconfigjson}'` |

#### B.2 — Usuario administrador inicial

| Parameter | Descripción | Cómo obtener |
|-----------|-------------|--------------|
| `admin.username` | Username del admin inicial. | Elegir uno fuerte (ej: `radmin`). |
| `admin.password` | Password del admin inicial. **≥16 chars, mayúsculas, minúsculas, números, símbolos.** | Generar manualmente. |
| `admin.email` | Email del admin (opcional). | — |
| `admin.firstName` | Nombre (default: `Administrador`). | — |
| `admin.lastName` | Apellido (default: `Sistema`). | — |
| `admin.dni` | Número de documento (default: `00000000`). **Debe ser único en la DB.** | — |

> El command `ensure_admin` se ejecuta automáticamente en cada deploy (después de `migrate`). Es idempotente: si el usuario ya existe, no hace nada. Si `admin.username` o `admin.password` están vacíos, se omite silenciosamente.

#### B.3 — Obligatorios si se usa Keycloak (y el backend lo usa)

| Parameter | Descripción |
|-----------|-------------|
| `keycloak.adminUser` | Usuario admin del realm master (ej: `admin`). |
| `keycloak.adminPassword` | Password de ese usuario (mismo valor que `KEYCLOAK_ADMIN_PASSWORD` en `keycloak.yaml`). |

> `keycloak.adminClientId` queda en `admin-cli` (default en `values.yaml`), no suele cambiar.

#### B.4 — Opcionales (dejar sin cargar si la integración no se usa)

| Parameter | Descripción | Si se omite |
|-----------|-------------|-------------|
| `email.user` | SMTP user (ej: `noreply@dominio.com`). | Email backend no envía mails. |
| `email.password` | SMTP password / app password. | idem |
| `sentry.dsn` | DSN de Sentry. | Sentry queda desactivado. |
| `whatsapp.apiToken` | Token de Meta WhatsApp Business API. | Integración WhatsApp inactiva. |
| `whatsapp.phoneNumberId` | Phone Number ID de WhatsApp. | idem |
| `externalSystem.apiUrl` | URL del sistema externo a sincronizar. | Sync tasks no funcionan. |
| `externalSystem.apiKey` | API key del sistema externo. | idem |
| `externalSystem.username` | Usuario si usa basic auth. | idem |
| `externalSystem.password` | Password idem. | idem |
| `webhook.apiUrl` | URL del webhook de notificaciones salientes. | Webhooks no se disparan. |
| `webhook.apiToken` | Token del webhook. | idem |

---

## Forma rápida: cargar los sensibles por CLI

Si preferís no usar la UI:

```bash
argocd login <ARGOCD_URL>

# Ejemplo: cargar los secretos obligatorios de prod
argocd app set osfatun-backend-prod \
  --helm-set db.password='<DB_PASS>' \
  --helm-set django.secretKey='<RANDOM_SECRET>' \
  --helm-set imagePullSecret.dockerconfigjson='<BASE64>' \
  --helm-set keycloak.adminUser='admin' \
  --helm-set keycloak.adminPassword='<KC_ADMIN_PASS>' \
  --helm-set admin.username='<ADMIN_USER>' \
  --helm-set admin.password='<ADMIN_PASS>' \
  --helm-set admin.email='<ADMIN_EMAIL>' \
  --helm-set admin.dni='<ADMIN_DNI>'

# Sincronizar
argocd app sync osfatun-backend-prod
```

Los valores quedan en el recurso `Application` del cluster, no en el shell history si se pasan desde un archivo con `--helm-set-file`.

---

## Verificación post-despliegue

```bash
# Todos los pods deberían estar Running
kubectl get pods -n osfatun-prod

# Revisar que el Secret de config se generó con los valores esperados
# (los campos sensibles deben tener valor real, NO cadena vacía)
kubectl get secret -n osfatun-prod backend-config -o jsonpath='{.data.SECRET_KEY}' | base64 -d
kubectl get secret -n osfatun-prod backend-db-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d

# Probar conectividad contra Keycloak desde el pod del backend
kubectl exec -n osfatun-prod deployment/backend -- \
  python manage.py shell -c "from apps.users.services.keycloak_service import KeycloakService; print(KeycloakService()._get_admin_token()[:20])"

# Logs del backend
kubectl logs -n osfatun-prod deployment/backend -f
```

---

## Rotación de un secreto

1. Generar el nuevo valor.
2. UI de ArgoCD → App → App Details → PARAMETERS → actualizar el valor del parameter.
3. `SYNC` (o esperar al self-heal). ArgoCD re-renderiza el Secret de Kubernetes.
4. Los Deployments (backend, celery-worker, celery-beat) consumen el Secret vía `envFrom`, por lo que **hay que reiniciarlos** para que lean el valor nuevo:
   ```bash
   kubectl rollout restart deployment -n osfatun-prod
   ```

> Mejora futura: agregar una anotación con hash del Secret en los Pod templates del chart para que un cambio de Secret dispare rolling restart automático.

---

## Resumen para los tres entornos

Tres Applications, misma fuente (mismo chart), distinto namespace y distintos parameters.

| Application | Namespace | `db.name` | `redis.db` | `ingress.host` | `envStage` |
|-------------|-----------|-----------|-----------|----------------|-----------|
| `osfatun-backend-prod` | `osfatun-prod` | `osfatun` | `"0"` | `api.osfatun.ticksar.com.ar` | `PRODUCTION` |
| `osfatun-backend-qa` | `osfatun-qa` | `osfatun_qa` | `"1"` | `api-qa.osfatun.ticksar.com.ar` | `QA` |
| `osfatun-backend-dev` | `osfatun-dev` | `osfatun_dev` | `"2"` | `api-dev.osfatun.ticksar.com.ar` | `DEVELOPMENT` |

Cada uno tiene sus propios secretos cargados independientemente desde la UI.
