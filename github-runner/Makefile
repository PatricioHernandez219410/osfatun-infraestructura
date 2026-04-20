# =============================================================================
# Makefile para GitHub Actions Self-Hosted Runner
# =============================================================================

.PHONY: help setup build up down logs status restart clean token

# Colores para output
YELLOW := \033[1;33m
GREEN := \033[1;32m
RED := \033[1;31m
NC := \033[0m

help: ## Mostrar esta ayuda
	@echo "$(GREEN)GitHub Actions Self-Hosted Runner:$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-15s$(NC) %s\n", $$1, $$2}'

# =============================================================================
# SETUP
# =============================================================================

setup: ## Configuración inicial (crear .env desde ejemplo)
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "$(GREEN)✅ Archivo .env creado$(NC)"; \
		echo "$(YELLOW)⚠️  Editar .env con tus valores de GitHub$(NC)"; \
	else \
		echo "$(YELLOW)⚠️  El archivo .env ya existe$(NC)"; \
	fi

docker-gid: ## Mostrar el GID del grupo docker (para configurar DOCKER_GID)
	@echo "$(GREEN)Docker GID:$(NC) $$(getent group docker | cut -d: -f3)"
	@echo "Agregar este valor a DOCKER_GID en .env"

# =============================================================================
# SERVICIOS
# =============================================================================

build: ## Construir imagen del runner
	docker compose build
	@echo "$(GREEN)✅ Imagen construida$(NC)"

up: ## Iniciar el runner
	@if [ ! -f .env ]; then \
		echo "$(RED)❌ Error: .env no existe. Ejecutar 'make setup' primero$(NC)"; \
		exit 1; \
	fi
	docker compose up -d
	@echo "$(GREEN)✅ Runner iniciado$(NC)"
	@echo "   Ver en GitHub: Settings → Actions → Runners"

down: ## Detener el runner
	docker compose down
	@echo "$(GREEN)✅ Runner detenido$(NC)"

restart: ## Reiniciar el runner
	docker compose restart
	@echo "$(GREEN)✅ Runner reiniciado$(NC)"

logs: ## Ver logs del runner
	docker compose logs -f

status: ## Ver estado del runner
	@docker compose ps
	@echo ""
	@echo "$(GREEN)Verificar en GitHub:$(NC) Settings → Actions → Runners"

# =============================================================================
# MANTENIMIENTO
# =============================================================================

clean: ## Detener y eliminar todo (imagen, volúmenes)
	docker compose down -v --rmi local
	@echo "$(GREEN)✅ Runner limpiado$(NC)"

shell: ## Abrir shell en el contenedor del runner
	docker compose exec github-runner bash

# =============================================================================
# UTILIDADES
# =============================================================================

token: ## Instrucciones para obtener el token
	@echo "$(GREEN)Para obtener el token de registro:$(NC)"
	@echo ""
	@echo "1. Ir a tu repositorio en GitHub"
	@echo "2. Settings → Actions → Runners"
	@echo "3. Click en 'New self-hosted runner'"
	@echo "4. Copiar el token del comando ./config.sh"
	@echo ""
	@echo "$(YELLOW)Nota: El token expira después de 1 hora$(NC)"

test: ## Verificar que el runner puede conectar con Docker
	docker compose exec github-runner docker version
