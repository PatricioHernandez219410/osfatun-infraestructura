# GitHub Actions Self-Hosted Runner

Runner de GitHub Actions dockerizado para ejecutar pipelines de CI/CD.

## Requisitos

- Docker y Docker Compose instalados en el servidor
- Acceso al repositorio de GitHub (Settings → Actions → Runners)

## Configuración Inicial

### 1. Crear archivo de configuración

```bash
make setup
```

### 2. Obtener token de GitHub

1. Ir a tu repositorio en GitHub
2. **Settings** → **Actions** → **Runners**
3. Click en **"New self-hosted runner"**
4. Copiar el token del comando `./config.sh --token XXXXXX`

### 3. Configurar .env

```bash
# Editar .env con tus valores
nano .env
```

Variables requeridas:

| Variable | Descripción | Ejemplo |
|----------|-------------|---------|
| `GITHUB_URL` | URL del repo u organización | `https://github.com/usuario/osfatun` |
| `GITHUB_TOKEN` | Token de registro | `AXXXXXXXXXXXX` |
| `RUNNER_NAME` | Nombre único del runner | `osfatun-runner` |
| `RUNNER_LABELS` | Labels separados por coma | `docker,linux,prod` |
| `DOCKER_GID` | GID del grupo docker | `999` |

Para obtener el DOCKER_GID:

```bash
make docker-gid
# o manualmente:
getent group docker | cut -d: -f3
```

### 4. Iniciar el runner

```bash
# Construir imagen
make build

# Iniciar
make up

# Ver logs
make logs
```

## Comandos Disponibles

```bash
make help       # Ver todos los comandos
make setup      # Crear .env desde ejemplo
make build      # Construir imagen
make up         # Iniciar runner
make down       # Detener runner
make logs       # Ver logs
make status     # Ver estado
make restart    # Reiniciar
make clean      # Limpiar todo
make shell      # Abrir shell en el contenedor
make token      # Instrucciones para obtener token
```

## Uso en Workflows

### Workflow básico

```yaml
name: CI/CD

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: self-hosted
    # O con labels específicos:
    # runs-on: [self-hosted, osfatun, docker]
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Build Docker image
        run: docker build -t myapp .
      
      - name: Deploy
        run: docker compose up -d
```

### Workflow con labels

```yaml
jobs:
  deploy-prod:
    runs-on: [self-hosted, osfatun, prod]
    steps:
      - name: Deploy to production
        run: ./deploy.sh
```

## Arquitectura

```
┌─────────────────────────────────────────────────────────┐
│                      GitHub                              │
│                         │                                │
│                    Push/PR/etc                           │
│                         ↓                                │
│                  GitHub Actions                          │
│                         │                                │
│                    Trigger Job                           │
│                         ↓                                │
└─────────────────────────────────────────────────────────┘
                          │
                          ↓
┌─────────────────────────────────────────────────────────┐
│                    Tu Servidor                           │
│  ┌───────────────────────────────────────────────────┐  │
│  │           Docker Container (Runner)                │  │
│  │                                                    │  │
│  │   - Escucha jobs de GitHub                        │  │
│  │   - Ejecuta steps del workflow                    │  │
│  │   - Tiene acceso a Docker del host                │  │
│  │                                                    │  │
│  └────────────────────┬──────────────────────────────┘  │
│                       │                                  │
│                       ↓ (docker.sock)                   │
│  ┌────────────────────────────────────────────────────┐ │
│  │                 Docker Host                         │ │
│  │   - Construye imágenes                             │ │
│  │   - Ejecuta contenedores                           │ │
│  │   - Deploy de aplicaciones                         │ │
│  └────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Características

- **Docker-in-Docker**: El runner puede ejecutar comandos Docker
- **Persistencia**: El workspace se mantiene entre reinicios
- **Auto-registro**: Se registra automáticamente en GitHub al iniciar
- **Auto-limpieza**: Se desregistra al detenerse
- **Labels personalizados**: Para seleccionar runners específicos

## Troubleshooting

### El runner no aparece en GitHub

1. Verificar que el token de registro no haya expirado (dura 1 hora)
   - **Nota**: El token solo se usa para el registro inicial
   - Una vez registrado, el runner funciona indefinidamente
2. Si el token expiró, regenerar en GitHub y actualizar `.env`
3. Reiniciar: `make restart`

### Error de permisos de Docker

```bash
# Verificar DOCKER_GID
make docker-gid

# Actualizar en .env y reiniciar
make down
make up
```

### Ver logs detallados

```bash
make logs
# o
docker compose logs -f github-runner
```

### Limpiar y empezar de cero

```bash
make clean
make setup
# Editar .env
make build
make up
```

## Seguridad

- El runner tiene acceso al Docker socket del host
- Solo usar en servidores de confianza
- El token de registro solo se usa una vez (expira en 1 hora si no se usa)
- Una vez registrado, el runner funciona indefinidamente
- Usar labels para restringir qué workflows pueden usar el runner

## Múltiples Runners

Para ejecutar múltiples runners (paralelismo):

```bash
# Copiar carpeta
cp -r github-runner github-runner-2

# Editar .env con nombre diferente
cd github-runner-2
nano .env  # Cambiar RUNNER_NAME=osfatun-runner-2

# Iniciar
make up
```
