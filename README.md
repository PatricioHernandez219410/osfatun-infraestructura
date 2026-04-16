# Infraestructura Kubernetes — OSFATUN

Documentación de respaldo para el cluster K3s de producción de OSFATUN.

---

## Arquitectura del cluster

### Topología de nodos

| Nodo | Rol | Etiqueta / Taint | Qué ejecuta |
|------|-----|-------------------|--------------|
| **Nodo maestro** | Control-plane K3s | `node-role.kubernetes.io/control-plane=true` (automático) | K3s server, Pomerium (ingress controller), Keycloak (IdP), cert-manager |
| **Nodo base de datos** | PostgreSQL dedicado | Label: `node-role=database` / Taint: `node-role=database:NoSchedule` | CloudNativePG (PostgreSQL) — exclusivamente |
| **Nodos worker** (futuros) | Aplicaciones | — | Servicios y aplicaciones del negocio |

### Componentes principales

| Componente | Propósito | Namespace |
|------------|-----------|-----------|
| **K3s** | Distribución ligera de Kubernetes (sin Traefik) | — |
| **cert-manager** | Gestión automática de certificados TLS via Let's Encrypt | `cert-manager` |
| **CloudNativePG** | Operador para gestionar PostgreSQL como recurso nativo de Kubernetes | Operador: `cnpg-system` / Cluster: `database` |
| **Pomerium** | Ingress controller con autenticación integrada (reemplaza a Traefik) | `pomerium` |
| **Keycloak** | Proveedor de identidad (IdP) OIDC, integrado con Pomerium | `keycloak` |
| **OSFATUN Backend** | API REST Django (Gunicorn) + Celery Worker/Beat + Redis | `osfatun-backend` |

### Dominios

| Dominio | Servicio |
|---------|----------|
| `authenticate.prueba.ticksar.com.ar` | Pomerium — endpoint de autenticación |
| `auth.osfatun.ticksar.com.ar` | Keycloak — consola de administración y OIDC |
| `api.osfatun.ticksar.com.ar` | OSFATUN Backend — API REST Django |

### Diagrama de dependencias

```
                     ┌──────────────┐
                     │     K3s      │
                     │ (sin Traefik)│
                     └──────┬───────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
     ┌────────▼───────┐ ┌──▼───────┐ ┌───▼──────────┐
     │  cert-manager   │ │CloudNative│ │   Pomerium   │
     │ (certificados)  │ │    PG     │ │  (ingress)   │
     └────────┬───────┘ └──┬───────┘ └───┬──────────┘
              │            │             │
              │       ┌────▼─────┐       │
              │       │PostgreSQL│       │
              │       │ (main-db)│       │
              │       └────┬─────┘       │
              │            │             │
              └──────┐ ┌───┘    ┌────────┘
                     │ │        │
                 ┌───▼─▼────────▼───┐
                 │     Keycloak     │
                 │   (IdP / OIDC)   │
                 └──────────────────┘
```

---

## Inventario de archivos

| Archivo | Descripción |
|---------|-------------|
| `.env-example` | Plantilla con **todas** las variables de entorno del ecosistema. Copiar a `.env`, completar y usar con `envsubst` antes de aplicar los manifiestos. |
| `.gitignore` | Excluye el archivo `.env` con credenciales reales del control de versiones. |
| `cloudnativepg.yaml` | Namespace `database`, secrets de credenciales, Cluster CloudNativePG (PostgreSQL 16). Fijado al nodo con label `node-role=database`. |
| `keycloak.yaml` | Namespace `keycloak`, secret de credenciales DB (réplica), secret admin Keycloak, Deployment, Service, Issuer cert-manager, Ingress. Fijado al nodo control-plane. |
| `issuer.yaml` | Issuer ACME Let's Encrypt producción en namespace `pomerium`. |
| `certificate.yaml` | Certificate para `authenticate.prueba.ticksar.com.ar` (namespace `pomerium`). |
| `ingressclass.yaml` | IngressClass `pomerium` como default del cluster. |
| `pomerium.yaml` | CRD Pomerium — configuración global con Keycloak como IdP OIDC. |
| `pomerium-proxy.yaml` | Service `pomerium-proxy` con annotation de external-dns. |
| `pomerium-node-patch.yaml` | Patch para fijar los deployments de Pomerium al nodo control-plane (aplicar post-instalación del operador). |
| `secret_keycloak.yaml` | Secret `idp` en namespace `pomerium` con credenciales del client OIDC `pomerium` configurado en Keycloak. |
| `config.yaml` | Configuración legacy de Pomerium (file-based). No se utiliza con el enfoque actual basado en CRD. |
| `osfatun-backend.yaml` | Namespace `osfatun-backend`, secrets (registry, DB, config), Redis, Deployment backend (Django+Gunicorn), Celery Worker, Celery Beat, PVC media, Service, Issuer cert-manager, Ingress. |
| `capa1.yaml` | Servicio de ejemplo (whoami). No forma parte del despliegue de producción. |
| `capa2.yaml` | Servicio de ejemplo (uptime-kuma). No forma parte del despliegue de producción. |

---

## Orden de despliegue

### Paso 0 — Instalar K3s y preparar nodos

```bash
# En el nodo maestro: instalar K3s sin Traefik
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable=traefik" sh -s - --node-external-ip=<IP_PUBLICA_NODO>

# Obtener token para unir nodos
cat /var/lib/rancher/k3s/server/node-token

# En el nodo de base de datos: unir al cluster
curl -sfL https://get.k3s.io | K3S_URL=https://<IP_MASTER>:6443 K3S_TOKEN=<TOKEN> sh -s - --node-external-ip=<IP_PUBLICA_NODO>

# Desde el maestro: etiquetar y taintear el nodo de DB
kubectl label node <NOMBRE_NODO_DB> node-role=database
kubectl taint node <NOMBRE_NODO_DB> node-role=database:NoSchedule
```

### Paso 1 — cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
```

Si las VPS no estan en la misma red, por ejemplo en AWS en la misma zona, es necesario indicarle a K3S que debe utilizar la IP pública para el DNS:

#En el maestro hay que hacer un:
```bash
cat > /etc/rancher/k3s/config.yaml <<EOF
flannel-external-ip: true
EOF
 
systemctl restart k3s
```

### Paso 2 — CloudNativePG (operador + cluster PostgreSQL)

```bash
# Instalar el operador de CloudNativePG
kubectl apply --server-side -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.29/releases/cnpg-1.29.0.yaml
kubectl wait --for=condition=Available deployment --all -n cnpg-system --timeout=120s

# Crear el cluster PostgreSQL (se ejecutará en el nodo de DB)
kubectl apply -f cloudnativepg.yaml
kubectl wait --for=condition=Ready cluster/main-db -n database --timeout=300s
```

### Paso 3 — Pomerium Ingress Controller

```bash
# Instalar el operador de Pomerium
kubectl apply -f https://raw.githubusercontent.com/pomerium/ingress-controller/main/deployment.yaml
kubectl wait --for=condition=Available deployment --all -n pomerium --timeout=120s

# Fijar Pomerium al nodo control-plane
kubectl get deployments -n pomerium -o name | xargs -I {} kubectl patch {} -n pomerium --patch-file pomerium-node-patch.yaml
```

### Paso 4 — Infraestructura base (IngressClass, Issuer, Certificate)

```bash
kubectl apply -f ingressclass.yaml
kubectl apply -f issuer.yaml
kubectl apply -f certificate.yaml
kubectl apply -f pomerium-proxy.yaml
```

### Paso 5 — Keycloak

```bash
kubectl apply -f keycloak.yaml
kubectl wait --for=condition=Available deployment/keycloak -n keycloak --timeout=300s
```

### Paso 6 — Configurar Keycloak (manual, via UI)

Acceder a `https://auth.osfatun.ticksar.com.ar` con las credenciales del secret `keycloak-credentials`.

1. **Crear realm** `osfatun`
2. **Crear client** OpenID Connect:
   - **Client ID:** `pomerium`
   - **Client authentication:** On (confidential)
   - **Valid redirect URIs:** `https://authenticate.prueba.ticksar.com.ar/oauth2/callback`
   - **Web origins:** `https://authenticate.prueba.ticksar.com.ar`
3. Ir a la pestaña **Credentials** del client y copiar el **Client Secret**

### Paso 7 — Integración Pomerium ↔ Keycloak

Actualizar `secret_keycloak.yaml` con el `client_secret` real obtenido en el paso anterior.

```bash
kubectl apply -f secret_keycloak.yaml
kubectl apply -f pomerium.yaml
```

A partir de este punto, Pomerium redirigirá a Keycloak para autenticar usuarios en cualquier Ingress que lo requiera.

### Paso 8 — OSFATUN Backend

Ver guía detallada en `documentacion/osfatun-backend.md`.

```bash
# Crear la base de datos 'osfatun' en PostgreSQL
kubectl exec -it -n database main-db-1 -- psql -U postgres -c "CREATE DATABASE osfatun OWNER app;"

# Editar osfatun-backend.yaml y reemplazar todos los CHANGE_ME_*
# (ver documentación para cada valor)

# Desplegar
kubectl apply -f osfatun-backend.yaml
kubectl wait --for=condition=Available deployment/backend -n osfatun-backend --timeout=300s
```

---

## Notas operativas

### Configuración de credenciales

Todos los manifiestos usan variables `${VAR_NAME}` resolubles con `envsubst`. El flujo para desplegar es:

```bash
# 1. Copiar el ejemplo y completar los valores
cp .env-example .env
# Editar .env con las credenciales reales

# 2. Cargar variables en el shell
set -a && source .env && set +a

# 3. Aplicar manifiestos pasándolos por envsubst
envsubst < cloudnativepg.yaml   | kubectl apply -f -
envsubst < keycloak.yaml        | kubectl apply -f -
envsubst < secret_keycloak.yaml | kubectl apply -f -
envsubst < osfatun-backend.yaml | kubectl apply -f -
```

Resumen de variables por componente:

| Variable | Archivo(s) | Descripción |
|----------|-----------|-------------|
| `DB_APP_PASSWORD` | cloudnativepg, keycloak, osfatun-backend | Password usuario `app`. **Debe ser idéntico** en los tres archivos. |
| `DB_SUPERUSER_PASSWORD` | cloudnativepg | Password superusuario `postgres`. |
| `KEYCLOAK_ADMIN_PASSWORD` | keycloak | Password admin de Keycloak. |
| `KEYCLOAK_OIDC_CLIENT_SECRET` | secret_keycloak | Secret del client OIDC `pomerium` (obtenido post Paso 6). |
| `DOCKER_CONFIG_BASE64` | osfatun-backend | Pull secret del registry de imágenes (base64). |
| `BACKEND_IMAGE` | osfatun-backend | Imagen Docker completa con tag (ej: `registry.../osfatun-backend:v1.0.0`). |
| `DJANGO_SECRET_KEY` | osfatun-backend | Secret key de Django (generar con `get_random_secret_key()`). |
| `EMAIL_*`, `SENTRY_*`, `WHATSAPP_*`, `EXTERNAL_SYSTEM_*`, `WEBHOOK_*` | osfatun-backend | Variables de integración del backend. |

### Verificación del estado

```bash
# Estado general de pods por namespace
kubectl get pods -A

# Estado del cluster PostgreSQL
kubectl get cluster -n database

# Logs de Keycloak
kubectl logs -n keycloak deployment/keycloak

# Logs de Pomerium
kubectl logs -n pomerium deployment/pomerium

# Certificados emitidos
kubectl get certificates -A
```

### Entorno de prueba

Existe una carpeta `../prueba/` con los mismos manifiestos pero sin restricciones de nodo (sin `nodeSelector`, `tolerations` ni `affinity`), pensada para probar todo el stack en un único servidor antes de desplegar en el cluster multi-nodo de producción.

---

## Deuda técnica

Lista de items pendientes a resolver para mejorar la estabilidad y calidad del cluster.

| # | Descripción | Prioridad | Contexto |
|---|-------------|-----------|----------|
| 1 | **Webhooks de operadores no responden tras fix de hairpin NAT.** Los webhooks de CloudNativePG y cert-manager requirieron `failurePolicy: Ignore` como workaround para poder aplicar los manifiestos. Investigar por qué los webhooks no responden a pesar de que la conectividad ClusterIP (`10.43.0.1`) funciona correctamente. Restaurar `failurePolicy: Fail` una vez resuelto. | Alta | Ver `errors/cloudnativepg.md` |
