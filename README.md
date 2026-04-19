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
| **ArgoCD** | GitOps / Continuous Delivery — sincroniza el cluster desde Git | `argocd` |

### Dominios

| Dominio | Servicio |
|---------|----------|
| `authenticate.prueba.ticksar.com.ar` | Pomerium — endpoint de autenticación |
| `auth.osfatun.ticksar.com.ar` | Keycloak — consola de administración y OIDC |
| `api.osfatun.ticksar.com.ar` | OSFATUN Backend — API REST Django |
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
| `certificate.yaml` | Certificate para `authenticate.prueba.ticksar.com.ar` (namespace `pomerium`). |
| `ingressclass.yaml` | IngressClass `pomerium` como default del cluster. |
| `pomerium.yaml` | CRD Pomerium — configuración global con Keycloak como IdP OIDC. |
| `pomerium-proxy.yaml` | Service `pomerium-proxy` con annotation de external-dns. |
| `pomerium-node-patch.yaml` | Patch para fijar los deployments de Pomerium al nodo control-plane (aplicar post-instalación del operador). |
| `secret_keycloak.yaml` | Secret `idp` en namespace `pomerium` con credenciales del client OIDC `pomerium` configurado en Keycloak. |
| `config.yaml` | Configuración legacy de Pomerium (file-based). No se utiliza con el enfoque actual basado en CRD. |
| `osfatun-backend.yaml` | Manifiesto plano original del backend. **Reemplazado por el Helm chart** en `charts/osfatun-backend/`. Conservado como referencia. |
| `charts/osfatun-backend/` | Helm chart del backend Django: templates K8s + `values.yaml` con toda la configuración parametrizada. |
| `argocd-ingress.yaml` | ConfigMap insecure + Issuer cert-manager + Ingress para exponer la UI de ArgoCD via Pomerium (restringido a grupo `admin`). |
| `argocd/osfatun-backend.yaml` | Application CRD de ArgoCD que apunta al Helm chart y define los value overrides para producción. |
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

# Aplicar la configuración global de Pomerium y el secret del IdP.
# El secret_keycloak.yaml se aplica con valores provisorios (placeholder);
# se actualizará con el client_secret real en el Paso 7.
kubectl apply -f secret_keycloak.yaml
kubectl apply -f pomerium.yaml
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

### Paso 9 — OSFATUN Backend (Helm + ArgoCD)

Ver guía detallada en `documentacion/osfatun-backend.md` y `documentacion/helm-argocd.md`.

```bash
# Crear la base de datos 'osfatun' en PostgreSQL
kubectl exec -it -n database main-db-1 -- psql -U postgres -c "CREATE DATABASE osfatun OWNER app;"

# Editar argocd/osfatun-backend.yaml: configurar repoURL y parameters (secrets)
# Registrar el repo en ArgoCD si es privado:
#   argocd repo add <REPO_URL> --username <USER> --password <TOKEN>

# Desplegar via ArgoCD
kubectl apply -f argocd/osfatun-backend.yaml

# O desplegar manualmente con Helm (sin ArgoCD):
# helm install osfatun-backend charts/osfatun-backend \
#   --namespace osfatun-backend --create-namespace \
#   --set db.password=<PASSWORD> --set django.secretKey=<KEY> ...
```

---

## Notas operativas

### Credenciales y secrets

- **`CHANGE_ME_DB_APP_PASSWORD`** en `cloudnativepg.yaml` debe coincidir con el mismo valor en `keycloak.yaml` (`keycloak-db-credentials`) y en `osfatun-backend.yaml` (`backend-db-credentials`). Mantener sincronizados manualmente.
- **`CHANGE_ME_DB_SUPERUSER_PASSWORD`** en `cloudnativepg.yaml` — password del superusuario `postgres`.
- **`CHANGE_ME_KEYCLOAK_PASSWORD`** en `keycloak.yaml` — password del admin de Keycloak.
- **`client_secret`** en `secret_keycloak.yaml` — se obtiene de Keycloak después de crear el client OIDC.
- **Secrets del backend** se configuran en `charts/osfatun-backend/values.yaml` o como parameter overrides en `argocd/osfatun-backend.yaml`. Ver `documentacion/helm-argocd.md` para detalles.

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
