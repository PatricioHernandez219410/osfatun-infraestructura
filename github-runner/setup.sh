#!/bin/bash
# =============================================================================
# Setup de GitHub Actions Runner para K3s
# =============================================================================
# Uso: scp este archivo a la VPS y ejecutar: ./setup.sh
# =============================================================================
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║       GitHub Actions Runner Controller - Instalador           ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# -----------------------------------------------------------------------------
# Verificar K3s
# -----------------------------------------------------------------------------
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}❌ kubectl no encontrado. ¿Tenés K3s instalado?${NC}"
    exit 1
fi

# Para K3s, asegurar que usamos el kubeconfig correcto
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml 2>/dev/null || true

if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}❌ No puedo conectar al cluster K3s${NC}"
    echo "   Probá: export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
    exit 1
fi

echo -e "${GREEN}✅ Conectado a K3s${NC}"

# -----------------------------------------------------------------------------
# Instalar Helm si no existe
# -----------------------------------------------------------------------------
if ! command -v helm &> /dev/null; then
    echo -e "${YELLOW}📦 Instalando Helm...${NC}"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# -----------------------------------------------------------------------------
# Recolectar datos
# -----------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}📝 Configuración${NC}"
echo ""

# GitHub URL
read -p "URL de GitHub (ej: https://github.com/mi-org): " GITHUB_URL
while [[ ! "$GITHUB_URL" =~ ^https://github.com/ ]]; do
    echo -e "${RED}   URL inválida, debe empezar con https://github.com/${NC}"
    read -p "URL de GitHub: " GITHUB_URL
done

# Token
echo ""
echo "Necesitás un PAT (Personal Access Token) con estos permisos:"
echo "  - repo (Full control)"
echo "  - admin:org → manage_runners:org (si es para organización)"
echo ""
read -sp "Personal Access Token: " PAT_TOKEN
echo ""

if [ -z "$PAT_TOKEN" ]; then
    echo -e "${RED}❌ Token vacío${NC}"
    exit 1
fi

# Nombre del runner
echo ""
read -p "Nombre del runner [osfatun-runner]: " RUNNER_NAME
RUNNER_NAME=${RUNNER_NAME:-osfatun-runner}

# Max runners
read -p "Máximo de runners simultáneos [5]: " MAX_RUNNERS
MAX_RUNNERS=${MAX_RUNNERS:-5}

# -----------------------------------------------------------------------------
# Instalar
# -----------------------------------------------------------------------------
echo ""
echo -e "${YELLOW}🚀 Instalando...${NC}"

# Namespaces
kubectl create namespace arc-systems --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -

# Controller
echo -e "${YELLOW}   → Controller...${NC}"
helm upgrade --install arc \
    --namespace arc-systems \
    --wait \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
    2>/dev/null

# Secret
echo -e "${YELLOW}   → Credenciales...${NC}"
kubectl create secret generic github-secret \
    --namespace arc-runners \
    --from-literal=github_token="$PAT_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

# Runner Scale Set
echo -e "${YELLOW}   → Runners...${NC}"
helm upgrade --install "$RUNNER_NAME" \
    --namespace arc-runners \
    --set githubConfigUrl="$GITHUB_URL" \
    --set githubConfigSecret=github-secret \
    --set minRunners=0 \
    --set maxRunners="$MAX_RUNNERS" \
    --set containerMode.type="dind" \
    --wait \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
    2>/dev/null

# -----------------------------------------------------------------------------
# Listo
# -----------------------------------------------------------------------------
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗"
echo -e "║                    ✅ INSTALACIÓN COMPLETA                     ║"
echo -e "╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "En tus workflows de GitHub Actions usá:"
echo ""
echo -e "  ${YELLOW}runs-on: $RUNNER_NAME${NC}"
echo ""
echo "Comandos útiles:"
echo "  kubectl get pods -n arc-runners -w     # Ver runners"
echo "  kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller"
echo ""
