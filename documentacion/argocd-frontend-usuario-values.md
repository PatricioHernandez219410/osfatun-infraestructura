# ArgoCD Parameters — OSFATUN Frontend (Panel Usuario)

Planilla de referencia para configurar los parameters de cada entorno del
frontend Panel Usuario en ArgoCD.

## Arquitectura de configuración

La imagen Docker se construye **una sola vez** con placeholders (`__VITE_*__`).
Al iniciar el contenedor, un entrypoint (`docker-entrypoint.sh`) reemplaza los
placeholders en los archivos JS por los valores reales de las env vars.

Esto permite usar **la misma imagen** para todos los entornos (dev, qa, prod),
gestionando los valores exclusivamente desde ArgoCD.

## Parameters del Helm Chart

Todos estos se configuran en el ArgoCD Application YAML o desde la UI de ArgoCD.

### Imagen y registry

| Parameter | Tipo | DESA | PROD (ejemplo) |
|---|---|---|---|
| `image.repository` | Por-entorno | `CHANGE_ME_REGISTRY/osfatun-frontend-panel-usuario` | `CHANGE_ME_REGISTRY/osfatun-frontend-panel-usuario` |
| `image.tag` | Por-entorno | `latest` | `v1.0.0` |
| `imagePullSecret.dockerconfigjson` | **SENSIBLE** | (ArgoCD UI) | (ArgoCD UI) |

### Ingress y acceso

| Parameter | Tipo | DESA | PROD (ejemplo) |
|---|---|---|---|
| `ingress.host` | Por-entorno | `admin.desa.osfatun.com.ar` | `admin.osfatun.com.ar` |
| `ingress.policy` | Por-entorno | (ArgoCD UI) | (ArgoCD UI) |
| `ingress.passIdentityHeaders` | Default | `true` | `true` |

**`ingress.policy`** — JSON con la política de acceso de Pomerium. Restringe el acceso por grupo de entorno:

```json
// Desarrollo:
[{"allow":{"and":[{"claim/groups":"ENT-Desarrollo"}]}}]
// QA:
[{"allow":{"and":[{"claim/groups":"ENT-QA"}]}}]
```

> **Multi-entorno:** todos los entornos comparten el realm `osfatun`. La separación de acceso se logra con grupos de entorno. Ver `documentacion/multi-entorno.md`.

**`ingress.passIdentityHeaders`** — Cuando `true`, Pomerium reenvía `X-Pomerium-Jwt-Assertion` y otros headers de identidad.

### Variables de entorno del frontend (env.*)

Estas se inyectan como env vars → el entrypoint las usa para reemplazar placeholders.

| Parameter | Descripción | DESA | PROD (ejemplo) |
|---|---|---|---|
| `env.viteApiAddress` | URL del backend API | `https://backoffice-api.desa.osfatun.com.ar` | `https://backoffice-api.osfatun.com.ar` |
| `env.viteKcUrl` | URL pública de Keycloak | `https://auth.osfatun.com.ar` | `https://auth.osfatun.com.ar` |
| `env.viteKcRealm` | Realm de Keycloak | `osfatun` | `osfatun` |
| `env.viteKcClientId` | Client ID en Keycloak | `osfatun-admin` | `osfatun-admin` |

## Keycloak — Requisitos del client `osfatun-admin`

Para que el flujo de autenticación funcione correctamente:

1. El client `osfatun-admin` debe existir en el realm `osfatun` con **Access Type: public** y **Standard Flow Enabled**.
2. **Valid Redirect URIs** debe incluir la URL del frontend (ej: `https://admin.desa.osfatun.com.ar/*`).
3. **Web Origins** debe incluir la URL del frontend (ej: `https://admin.desa.osfatun.com.ar`).
4. El access token **debe incluir el claim `sub`** (UUID del usuario). Si falta, agregar un mapper "User Property" (`id` → `sub`) en los dedicated scopes del client. Ver paso 6.5 del README del cluster.

## Build de la imagen (CI)

La imagen se construye **sin build-args** — los placeholders están fijos en el Dockerfile:

```bash
docker build -f docker/Dockerfile.prod -t ghcr.io/org/osfatun-frontend-panel-usuario:v1.0.0 .
docker push ghcr.io/org/osfatun-frontend-panel-usuario:v1.0.0
```

Una sola imagen sirve para todos los entornos. Los valores se cambian desde ArgoCD.
