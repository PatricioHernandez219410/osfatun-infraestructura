#!/bin/bash
# =============================================================================
# Entrypoint para GitHub Actions Self-Hosted Runner
# =============================================================================

set -e

# Variables requeridas
RUNNER_NAME=${RUNNER_NAME:-"docker-runner"}
RUNNER_WORKDIR=${RUNNER_WORKDIR:-"/home/runner/actions-runner/_work"}
RUNNER_LABELS=${RUNNER_LABELS:-"docker,linux,self-hosted"}

# Validar variables obligatorias
if [ -z "$GITHUB_URL" ]; then
    echo "❌ Error: GITHUB_URL no está definida"
    echo "   Ejemplo: https://github.com/usuario/repositorio"
    echo "   O para organización: https://github.com/organizacion"
    exit 1
fi

if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ Error: GITHUB_TOKEN no está definido"
    echo "   Obtener desde: Settings → Actions → Runners → New self-hosted runner"
    exit 1
fi

cd /home/runner/actions-runner

# Función para limpiar al salir
cleanup() {
    echo "🧹 Limpiando runner..."
    ./config.sh remove --token "${GITHUB_TOKEN}" || true
}

trap cleanup EXIT

# Configurar el runner si no está configurado
if [ ! -f ".runner" ]; then
    echo "⚙️  Configurando runner..."
    ./config.sh \
        --url "${GITHUB_URL}" \
        --token "${GITHUB_TOKEN}" \
        --name "${RUNNER_NAME}" \
        --labels "${RUNNER_LABELS}" \
        --work "${RUNNER_WORKDIR}" \
        --unattended \
        --replace
fi

echo "🚀 Iniciando runner: ${RUNNER_NAME}"
echo "   URL: ${GITHUB_URL}"
echo "   Labels: ${RUNNER_LABELS}"

# Ejecutar el runner
./run.sh
