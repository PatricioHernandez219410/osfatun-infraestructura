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
| **Redis** | Broker Celery y caché — servicio compartido por todos los entornos | `redis` |
| **OSFATUN Backend** | API REST Django (Gunicorn) + Celery Worker/Beat. Un namespace por entorno (`osfatun-prod`, `osfatun-qa`, etc.) | `osfatun-*` |
| **ArgoCD** | GitOps / Continuous Delivery — sincroniza el cluster desde Git | `argocd` |

### Dominios

| Dominio | Servicio |
|---------|----------|
| `authenticate.prueba.ticksar.com.ar` | Pomerium — endpoint de autenticación |
| `auth.osfatun.ticksar.com.ar` | Keycloak — consola de administración y OIDC |
| `api.osfatun.ticksar.com.ar` | OSFATUN Backend — API REST Django (producción) |
| `argo.osfatun.ticksar.com.ar` | ArgoCD — UI de gestión GitOps (acceso restringido a grupo `admin`) |

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
| `cloudnativepg.yaml` | Namespace `database`, secrets de credenciales, Cluster CloudNativePG (PostgreSQL 16). Fijado al nodo con label `node-role=database`. |
| `keycloak.yaml` | Namespace `keycloak`, secret de credenciales DB (réplica), secret admin Keycloak, Deployment, Service, Issuer cert-manager, Ingress. Fijado al nodo control-plane. |
| `issuer.yaml` | Issuer ACME Let's Encrypt producción en namespace `pomerium`. |
| `certificate.yaml` | Certificate standalone para `authenticate.prueba.ticksar.com.ar` (namespace `pomerium`). **Es fundamental necesario**: se debe aplicar despues de haber aplicado el issuer de cert-manager para que pueda aplicar el certificado. |
| `ingressclass.yaml` | IngressClass `pomerium` como default del cluster. |
| `pomerium.yaml` | CRD Pomerium — configuración global con Keycloak como IdP OIDC. Incluye `spec.authenticate.ingress` para que cert-manager emita el certificado del endpoint authenticate via HTTP-01. |
| `pomerium-proxy.yaml` | Service `pomerium-proxy` con annotation de external-dns. |
| `pomerium-node-patch.yaml` | Patch para fijar los deployments de Pomerium al nodo control-plane (aplicar post-instalación del operador). |
| `secret_keycloak.yaml` | Secret `idp` en namespace `pomerium` con credenciales del client OIDC `pomerium` configurado en Keycloak. |
| `config.yaml` | Configuración legacy de Pomerium (file-based). No se utiliza con el enfoque actual basado en CRD. |
| `osfatun-backend.yaml` | Manifiesto plano original del backend. **Reemplazado por el Helm chart** en `charts/osfatun-backend/`. Conservado como referencia. |
| `charts/osfatun-backend/` | Helm chart del backend Django + Celery. Parametrizado para multi-entorno (DB, Redis DB, dominio). |
| `charts/redis/` | Helm chart de Redis compartido. Instancia única usada por todos los entornos (cada uno usa un DB number distinto). |
| `argocd-ingress.yaml` | ConfigMap insecure + Issuer cert-manager + Ingress para exponer la UI de ArgoCD via Pomerium (restringido a grupo `admin`). |
| `argocd/redis.yaml` | Application CRD de ArgoCD para desplegar Redis compartido en namespace `redis`. |
| `argocd/osfatun-backend.yaml` | Application CRD de ArgoCD para el backend producción (`osfatun-prod`). **Solo contiene parameters NO sensibles.** Los secretos se cargan desde la UI de ArgoCD. Duplicar para otros entornos. |
| `documentacion/argocd-backend-values.md` | Planilla completa de parameters (sensibles y por-entorno) para cargar al declarar cada instancia del backend en ArgoCD. |
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

A continuación se debe aplicar el issuer para que esté declarado cert-manager y pueda hacer la generación automatica de certificados antes de terminar de levantar pomerium, de manera en que cuando se genere, se autocertifique el subdominio "authenticate":
```bash
kubectl apply -f issuer.yaml
kubectl patch service pomerium-proxy -n pomerium --type merge --patch-file pomerium-proxy.yaml
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

# Aplicar la configuración global de Pomerium y el secret del IdP.
# El secret_keycloak.yaml se aplica con valores provisorios (placeholder);
# se actualizará con el client_secret real en el Paso 7.
kubectl apply -f secret_keycloak.yaml
kubectl apply -f pomerium.yaml
```

### Paso 4 — Infraestructura base (IngressClass)

```bash
kubectl apply -f ingressclass.yaml
# certificate.yaml NO se aplica: cert-manager emite el certificado
# automáticamente a partir del Ingress que crea pomerium.yaml
# (ver spec.authenticate.ingress).
```

### Paso 5 — Keycloak

```bash
kubectl apply -f keycloak.yaml
kubectl wait --for=condition=Available deployment/keycloak -n keycloak --timeout=300s
```

### Paso 6 — Configurar Keycloak (manual, via UI)

Acceder a `https://auth.osfatun.ticksar.com.ar` con las credenciales del secret `keycloak-credentials`.

**6.1 — Realm y client OIDC para Pomerium:**

1. **Crear realm** `osfatun`
2. **Crear client** OpenID Connect:
   - **Client ID:** `pomerium`
   - **Client authentication:** On (confidential)
   - **Valid redirect URIs:** `https://authenticate.prueba.ticksar.com.ar/oauth2/callback`
   - **Web origins:** `https://authenticate.prueba.ticksar.com.ar`
3. Ir a la pestaña **Credentials** del client y copiar el **Client Secret**

**6.2 — Grupo `admin` (para acceso a ArgoCD y otros paneles):**

4. **Groups → Create group** → nombre: `admin`
5. **Users** → seleccionar el/los usuario(s) administrador(es) → pestaña **Groups** → **Join group** → `admin`

**6.3 — Group Mapper (para que Pomerium reciba los grupos en el token OIDC):**

6. **Clients → `pomerium` → Client scopes → `pomerium-dedicated`**
7. **Add mapper → By configuration → Group Membership:**
   - **Name:** `groups`
   - **Token Claim Name:** `groups`
   - **Full group path:** OFF
   - **Add to ID token:** ON
   - **Add to access token:** ON
   - **Add to userinfo:** ON

Esto permite que Pomerium evalúe políticas basadas en grupos de Keycloak (ej: restringir ArgoCD al grupo `admin`).

### Paso 7 — Integración Pomerium ↔ Keycloak

Editar `secret_keycloak.yaml` y reemplazar el `client_secret` placeholder con el valor real copiado en el paso 6.1.3.

```bash
# Re-aplicar el secret con el client_secret real
kubectl apply -f secret_keycloak.yaml
```

Pomerium detecta automáticamente el cambio en el Secret y comienza a redirigir a Keycloak para autenticar usuarios en cualquier Ingress que lo requiera.

### Paso 8 — ArgoCD

Ver guía detallada en `documentacion/helm-argocd.md`.

**8.1 — Instalar ArgoCD:**

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s

# Obtener password del admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

**8.2 — DNS:**

Crear registro A para `argo.osfatun.ticksar.com.ar` apuntando a la IP pública del nodo control-plane (la misma IP que usan los demás dominios).

**8.3 — Exponer UI via Pomerium:**

```bash
kubectl apply -f argocd-ingress.yaml
kubectl rollout restart deployment/argocd-server -n argocd
```

`argocd-ingress.yaml` configura ArgoCD en modo HTTP interno (TLS lo termina Pomerium), crea el Issuer de cert-manager para el namespace `argocd`, y expone la UI con política de acceso restringida al grupo `admin` de Keycloak.

**8.4 — Verificar:**

```bash
kubectl get certificate -n argocd       # Certificado TLS emitido
kubectl get ingress -n argocd           # Ingress activo
```

Acceder a `https://argo.osfatun.ticksar.com.ar` — debe redirigir a Keycloak y solo permitir el acceso a usuarios del grupo `admin`.

### Paso 9 — Redis compartido

```bash
# Editar argocd/redis.yaml: configurar repoURL
kubectl apply -f argocd/redis.yaml
```

ArgoCD despliega Redis en el namespace `redis`. Todos los entornos del backend se conectan a esta instancia usando distintos DB numbers (`0`=prod, `1`=qa, `2`=dev, etc.).

### Paso 10 — OSFATUN Backend (Helm + ArgoCD)

Ver guía detallada en `documentacion/osfatun-backend.md` y `documentacion/helm-argocd.md`.

**10.1 — Crear la base de datos:**

```bash
kubectl exec -it -n database main-db-1 -- psql -U postgres -c "CREATE DATABASE osfatun OWNER app;"
```

**10.2 — Registrar el repo en ArgoCD (si es privado):**

```bash
argocd repo add <REPO_URL> --username <USER> --password <TOKEN>
```

**10.3 — Desplegar producción (flujo con secretos vía UI de ArgoCD):**

El `Application` YAML en Git contiene **solo** parameters no sensibles (imagen, envStage, DB name, dominio, CORS, URLs de Keycloak). Todos los secretos (`db.password`, `django.secretKey`, `imagePullSecret.dockerconfigjson`, `keycloak.adminPassword`, etc.) se cargan exclusivamente desde la interfaz web de ArgoCD. Ver planilla completa en `documentacion/argocd-backend-values.md`.

```bash
# 1. Editar argocd/osfatun-backend.yaml: configurar spec.source.repoURL y
#    ajustar los parameters por-entorno (image.repository, ingress.host, etc.).

# 2. Aplicar el Application (la primera vez, recomendado con auto-sync apagado):
kubectl apply -f argocd/osfatun-backend.yaml

# 3. En la UI de ArgoCD (argo.osfatun.ticksar.com.ar):
#    Applications → osfatun-backend-prod → App Details → PARAMETERS → EDIT
#    Agregar los parameters sensibles uno a uno (lista en argocd-backend-values.md).

# 4. Desde la UI pulsar SYNC para la primera sincronización.
#    A partir de entonces, con syncPolicy.automated activado en el YAML,
#    ArgoCD se encarga del resto. Los secretos cargados por UI se preservan
#    al re-aplicar desde Git (syncOptions: ServerSideApply=true).
```

**10.4 — Agregar otro entorno (ejemplo: QA):**

1. Crear base de datos: `CREATE DATABASE osfatun_qa OWNER app;`
2. Crear DNS para `api-qa.osfatun.ticksar.com.ar`.
3. Duplicar `argocd/osfatun-backend.yaml` → `argocd/osfatun-backend-qa.yaml`.
4. Ajustar en la copia (todos son parameters NO sensibles):
   - `metadata.name` → `osfatun-backend-qa`
   - `destination.namespace` → `osfatun-qa`
   - `parameters`: `django.envStage=QA`, `db.name=osfatun_qa`, `redis.db="1"`, `ingress.host=api-qa.osfatun.ticksar.com.ar`, `cors.whitelist/trustedOrigins` con el nuevo dominio, `email.defaultFrom` apropiado.
5. `kubectl apply -f argocd/osfatun-backend-qa.yaml`.
6. Cargar los parameters sensibles en la UI de ArgoCD para la nueva app (independientes de los de prod).

El chart es el mismo para los tres entornos — solo cambian los parameters del Application.

---

## Notas operativas

### Credenciales y secrets

- **`CHANGE_ME_DB_APP_PASSWORD`** en `cloudnativepg.yaml` debe coincidir con el mismo valor en `keycloak.yaml` (`keycloak-db-credentials`) y con el parameter `db.password` de cada Application de ArgoCD del backend. Mantener sincronizados manualmente.
- **`CHANGE_ME_DB_SUPERUSER_PASSWORD`** en `cloudnativepg.yaml` — password del superusuario `postgres`.
- **`CHANGE_ME_KEYCLOAK_PASSWORD`** en `keycloak.yaml` — password del admin de Keycloak; mismo valor que se carga como `keycloak.adminPassword` en cada Application del backend.
- **`client_secret`** en `secret_keycloak.yaml` — se obtiene de Keycloak después de crear el client OIDC.
- **Secrets del backend (por entorno)** — NUNCA en Git. Se cargan por cada Application de ArgoCD desde la UI web (o `argocd app set --helm-set ...`). El template `argocd/osfatun-backend.yaml` solo incluye parameters no sensibles. Planilla completa en `documentacion/argocd-backend-values.md`.
- **Redis** no requiere credenciales (sin autenticación, accesible solo desde dentro del cluster).

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
