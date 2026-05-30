NAMESPACE    := vittospace
KUBECTL      := sudo k3s kubectl
POSTGRES_POD := prode-postgres-0

DB_URL    := $(shell $(KUBECTL) get secret prode-secret -n $(NAMESPACE) -o jsonpath='{.data.DATABASE_URL}' | base64 -d 2>/dev/null)
APP_IMAGE := $(shell $(KUBECTL) get deployment prode-deployment -n $(NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)

.DEFAULT_GOAL := help
.PHONY: help init-db seed reset status db-shell

help:
	@echo ""
	@echo "Comandos disponibles:"
	@echo "  make init-db   Borra todos los datos y corre las migraciones de Prisma"
	@echo "  make seed      Carga equipos y partidos del Mundial 2026"
	@echo "  make reset     init-db + seed (DB limpia con datos listos)"
	@echo "  make status    Estado de pods, services y apps de ArgoCD"
	@echo "  make db-shell  Shell psql interactivo contra la DB"
	@echo ""

# Borra todos los datos y aplica las migraciones de Prisma desde cero
init-db:
	@echo "→ Borrando datos (schema public)..."
	$(KUBECTL) exec -n $(NAMESPACE) $(POSTGRES_POD) -- \
		psql -U postgres -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
	@echo "→ Corriendo migraciones Prisma ($(APP_IMAGE))..."
	$(KUBECTL) run prode-migrate-$$(date +%s) --rm -i --restart=Never \
		-n $(NAMESPACE) \
		--image=$(APP_IMAGE) \
		--image-pull-policy=IfNotPresent \
		--env="DATABASE_URL=$(DB_URL)" \
		--overrides='{"spec":{"imagePullSecrets":[{"name":"ghcr-secret"}]}}' \
		-- sh -c "node node_modules/.bin/prisma migrate deploy"
	@echo "✓ DB inicializada."

# Carga los datos del Mundial 2026: equipos y fixture
seed:
	@echo "→ Cargando equipos..."
	$(KUBECTL) run prode-seed-teams-$$(date +%s) --rm -i --restart=Never \
		-n $(NAMESPACE) \
		--image=$(APP_IMAGE) \
		--image-pull-policy=IfNotPresent \
		--env="DATABASE_URL=$(DB_URL)" \
		--overrides='{"spec":{"imagePullSecrets":[{"name":"ghcr-secret"}]}}' \
		-- node ./.dist/jobs/updateTeamsJob.js
	@echo "→ Cargando partidos..."
	$(KUBECTL) run prode-seed-matches-$$(date +%s) --rm -i --restart=Never \
		-n $(NAMESPACE) \
		--image=$(APP_IMAGE) \
		--image-pull-policy=IfNotPresent \
		--env="DATABASE_URL=$(DB_URL)" \
		--overrides='{"spec":{"imagePullSecrets":[{"name":"ghcr-secret"}]}}' \
		-- node ./.dist/jobs/updateMatchesJob.js
	@echo "✓ Seed completo."

# DB limpia + migraciones + seed: arranca desde cero
reset: init-db seed

# Estado rápido de pods, services, PVCs y apps de ArgoCD
status:
	@echo "=== Pods / Services / PVCs ==="
	@$(KUBECTL) get pods,svc,pvc -n $(NAMESPACE) | grep -E "NAME|prode"
	@echo ""
	@echo "=== ArgoCD apps ==="
	@$(KUBECTL) get application -n argocd | grep -E "NAME|prode"

# Shell psql directo contra la DB
db-shell:
	$(KUBECTL) exec -it -n $(NAMESPACE) $(POSTGRES_POD) -- psql -U postgres
