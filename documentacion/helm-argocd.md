# Helm + ArgoCD — Guía de uso en el cluster OSFATUN

## Qué es Helm

Helm es el gestor de paquetes de Kubernetes. Permite definir la configuración de un servicio como un **chart** (carpeta con templates YAML + un archivo de valores), de forma que un mismo chart se puede desplegar en distintos ambientes simplemente cambiando los valores.

Componentes de un chart:

| Archivo | Función |
|---------|---------|
| `Chart.yaml` | Metadata: nombre, versión, descripción |
| `values.yaml` | Valores por defecto (configuración del servicio) |
| `templates/` | Manifiestos K8s con variables `{{ .Values.xxx }}` que Helm reemplaza al desplegar |
| `templates/_helpers.tpl` | Funciones reutilizables (labels, nombres, etc.) |

Comando básico para desplegar un chart manualmente:

```bash
helm install <nombre-release> <ruta-chart> \
  --namespace <namespace> \
  --create-namespace \
  -f values-production.yaml
```

## Qué es ArgoCD

ArgoCD es una herramienta de **GitOps** para Kubernetes. Automatiza el despliegue observando un repositorio Git:

1. Detecta cambios en los manifiestos o charts de Git.
2. Renderiza los templates (si es Helm) con los values configurados.
3. Aplica los cambios al cluster automáticamente.
4. Monitorea el estado y reconcilia si alguien modifica algo manualmente.

ArgoCD se instala en el cluster como un conjunto de pods en el namespace `argocd` y provee una UI web para visualizar el estado de todas las aplicaciones.

## Instalación de ArgoCD

```bash
# Crear namespace e instalar ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s

# Obtener la contraseña inicial del admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Para acceder a la UI de ArgoCD se puede usar port-forward o un Ingress:

```bash
# Port-forward (acceso local)
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Abrir https://localhost:8080 (usuario: admin, password: el obtenido arriba)
```

Para exponer ArgoCD via Pomerium, aplicar el manifiesto `argocd-ingress.yaml` que configura:

1. **ConfigMap `argocd-cmd-params-cm`** — pone ArgoCD en modo HTTP interno (`server.insecure: true`), ya que TLS lo termina Pomerium.
2. **Issuer `letsencrypt-prod`** — emisión automática de certificados en el namespace `argocd`.
3. **Ingress** — expone la UI en `argo.osfatun.ticksar.com.ar` con acceso restringido al grupo `admin` de Keycloak.

```bash
kubectl apply -f argocd-ingress.yaml
kubectl rollout restart deployment/argocd-server -n argocd
```

El restart es necesario para que ArgoCD tome el cambio del ConfigMap. Ver `README.md` Paso 8 para el procedimiento completo (DNS, verificación, etc.).

## Instalación de Helm (solo CLI)

Helm es solo una herramienta de línea de comandos. No requiere instalar nada en el cluster.

```bash
# macOS
brew install helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verificar
helm version
```

## Estructura del proyecto

```
kubernetes/
├── charts/                         # Helm charts de servicios
│   └── osfatun-backend/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── namespace.yaml
│           ├── secret-registry.yaml
│           ├── secret-db.yaml
│           ├── secret-config.yaml
│           ├── redis-deployment.yaml
│           ├── redis-service.yaml
│           ├── pvc-media.yaml
│           ├── backend-deployment.yaml
│           ├── backend-service.yaml
│           ├── celery-worker-deployment.yaml
│           ├── celery-beat-deployment.yaml
│           ├── issuer.yaml
│           └── ingress.yaml
│
├── argocd/                         # Application CRDs para ArgoCD
│   └── osfatun-backend.yaml
│
├── cloudnativepg.yaml              # Infraestructura base (manifiestos planos)
├── keycloak.yaml
├── issuer.yaml
├── ...etc
```

## Despliegue del backend con Helm (manual, sin ArgoCD)

Útil para pruebas o si ArgoCD aún no está instalado:

```bash
# Previsualizar los manifiestos renderizados (dry-run)
helm template osfatun-backend charts/osfatun-backend \
  --namespace osfatun-backend \
  -f charts/osfatun-backend/values.yaml

# Instalar el chart
helm install osfatun-backend charts/osfatun-backend \
  --namespace osfatun-backend \
  --create-namespace \
  --set db.password=<PASSWORD_REAL> \
  --set django.secretKey=<SECRET_KEY_REAL> \
  --set image.repository=registry.gitlab.com/org/osfatun-backend \
  --set image.tag=v1.0.0 \
  --set imagePullSecret.dockerconfigjson=<BASE64_CONFIG>

# Actualizar valores (después de cambiar values.yaml)
helm upgrade osfatun-backend charts/osfatun-backend \
  --namespace osfatun-backend \
  --reuse-values \
  --set image.tag=v1.1.0

# Rollback a la versión anterior
helm rollback osfatun-backend 1 --namespace osfatun-backend

# Desinstalar
helm uninstall osfatun-backend --namespace osfatun-backend
```

## Despliegue del backend con ArgoCD

### Configuración inicial

1. Editar `argocd/osfatun-backend.yaml`:
   - `repoURL`: URL del repositorio Git.
   - `parameters`: sobreescribir los valores sensibles (secrets).

2. Registrar el repositorio en ArgoCD (si es privado):
   ```bash
   argocd repo add <REPO_URL> --username <USER> --password <TOKEN>
   ```

3. Aplicar la Application:
   ```bash
   kubectl apply -f argocd/osfatun-backend.yaml
   ```

ArgoCD comenzará a sincronizar automáticamente. Cualquier cambio pusheado a Git se aplicará al cluster.

### Actualizar la imagen del backend

Simplemente editar `values.yaml` (o el parameter en la Application de ArgoCD) con el nuevo tag:

```yaml
image:
  tag: v1.1.0
```

Pushear a Git → ArgoCD detecta el cambio → rolling update automático.

### Escalar réplicas

Editar `values.yaml`:

```yaml
backend:
  replicas: 3

celeryWorker:
  replicas: 2
```

Pushear a Git → ArgoCD aplica el cambio.

**Recordar:** `celeryBeat` SIEMPRE debe quedar en 1 réplica (hardcodeado en el template).

## Gestión de secrets

Los valores sensibles (passwords, API keys) **no deben commitearse a Git** en texto plano. Opciones:

### Opción 1 — ArgoCD parameter overrides (actual)

Los secrets se definen como `parameters` en la Application CRD de ArgoCD. ArgoCD los almacena como un Secret en su propio namespace. Es la opción más simple para empezar.

### Opción 2 — Sealed Secrets (recomendado a futuro)

Instalar el controlador de Sealed Secrets en el cluster. Los secrets se encriptan con una clave pública y se commitean a Git cifrados. Solo el cluster puede descifrarlos.

```bash
# Instalar Sealed Secrets
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm install sealed-secrets sealed-secrets/sealed-secrets -n kube-system

# Cifrar un secret
kubeseal --format=yaml < secret.yaml > sealed-secret.yaml
# sealed-secret.yaml se puede commitear a Git con seguridad
```

### Opción 3 — External Secrets Operator

Sincroniza secrets desde un vault externo (AWS Secrets Manager, HashiCorp Vault) directamente al cluster. Ideal si ya se usa un gestor de secrets corporativo.

## Comandos útiles

```bash
# ArgoCD: ver estado de las aplicaciones
argocd app list
argocd app get osfatun-backend

# ArgoCD: forzar sincronización
argocd app sync osfatun-backend

# ArgoCD: ver diff entre Git y cluster
argocd app diff osfatun-backend

# Helm: listar releases instalados
helm list -A

# Helm: ver valores actuales de un release
helm get values osfatun-backend -n osfatun-backend

# Helm: ver manifiestos renderizados de un release
helm get manifest osfatun-backend -n osfatun-backend

# Helm: historial de revisiones
helm history osfatun-backend -n osfatun-backend
```
