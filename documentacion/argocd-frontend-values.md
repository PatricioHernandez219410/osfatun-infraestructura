# ArgoCD Parameters — OSFATUN Frontend (Panel Central)

Planilla de referencia para configurar los parameters de cada entorno del
frontend en ArgoCD.

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
| `image.repository` | Por-entorno | `CHANGE_ME_REGISTRY/osfatun-frontend` | `CHANGE_ME_REGISTRY/osfatun-frontend` |
| `image.tag` | Por-entorno | `latest` | `v1.0.0` |
| `imagePullSecret.dockerconfigjson` | **SENSIBLE** | (ArgoCD UI) | (ArgoCD UI) |

### Ingress y acceso

| Parameter | Tipo | DESA | PROD (ejemplo) |
|---|---|---|---|
| `ingress.host` | Por-entorno | `empleados.desa.osfatun.com.ar` | `empleados.osfatun.com.ar` |
| `ingress.policy` | Por-entorno | (ArgoCD UI) | (ArgoCD UI) |
| `ingress.passIdentityHeaders` | Default | `true` | `true` |

**`ingress.policy`** — JSON con la política de acceso de Pomerium. Ejemplo para restringir al grupo `osfatun`:

```json
[{"allow":{"and":[{"claim/groups":"osfatun"}]}}]
```

**`ingress.passIdentityHeaders`** — Cuando `true`, Pomerium reenvía `X-Pomerium-Jwt-Assertion` y otros headers de identidad. El SPA puede consultar `/.pomerium/jwt` para obtener la identidad del usuario autenticado.

### Variables de entorno del frontend (env.*)

Estas se inyectan como env vars → el entrypoint las usa para reemplazar placeholders.

| Parameter | Descripción | DESA | PROD (ejemplo) |
|---|---|---|---|
| `env.viteApiAddress` | URL del backend API | `https://api.desa.osfatun.com.ar/api` | `https://api.osfatun.com.ar/api` |
| `env.viteAppName` | Nombre de la aplicación | `Osfatun` | `Osfatun` |
| `env.viteAppEnv` | Entorno | `development` | `production` |
| `env.viteDebug` | Debug mode | `true` | `false` |
| `env.viteKcUrl` | URL pública de Keycloak | `https://auth.osfatun.com.ar` | `https://auth.osfatun.com.ar` |
| `env.viteKcRealm` | Realm de Keycloak | `osfatun` | `osfatun` |
| `env.viteKcClientId` | Client ID en Keycloak | `osfatun-frontend` | `osfatun-frontend` |
| `env.viteAdminUrl` | URL del panel admin | `https://admin.desa.osfatun.com.ar` | `https://admin.osfatun.com.ar` |

## Build de la imagen (CI)

La imagen se construye **sin build-args** — los placeholders están fijos en el Dockerfile:

```bash
docker build -f docker/Dockerfile.prod -t ghcr.io/org/osfatun-frontend:v1.0.0 .
docker push ghcr.io/org/osfatun-frontend:v1.0.0
```

Una sola imagen sirve para todos los entornos. Los valores se cambian desde ArgoCD.
