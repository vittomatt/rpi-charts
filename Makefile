NAMESPACE    := vittospace
KUBECTL      := sudo k3s kubectl
POSTGRES_POD := prode-postgres-0
BACKUP_DIR   := backups

DB_URL    := $(shell $(KUBECTL) get secret prode-secret -n $(NAMESPACE) -o jsonpath='{.data.DATABASE_URL}' | base64 -d 2>/dev/null)
APP_IMAGE := $(shell $(KUBECTL) get deployment prode-deployment -n $(NAMESPACE) -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)

.DEFAULT_GOAL := help
.PHONY: help init-db seed reset status db-shell backup restore list-backups seal

help:
	@echo ""
	@echo "Secrets (correr desde la Mac):"
	@echo "  make seal KEY=MI_VAR VALUE=mi_valor  Sella una var y la agrega al SealedSecret"
	@echo ""
	@echo "DB:"
	@echo "  make init-db              Borra todos los datos y corre las migraciones de Prisma"
	@echo "  make seed                 Carga equipos y partidos del Mundial 2026"
	@echo "  make reset                init-db + seed (DB limpia con datos listos)"
	@echo "  make db-shell             Shell psql interactivo contra la DB"
	@echo ""
	@echo "Backups:"
	@echo "  make backup               Genera un backup ahora en $(BACKUP_DIR)/"
	@echo "  make list-backups         Lista los backups disponibles"
	@echo "  make restore FILE=<name>  Restaura la DB desde un backup (ej: FILE=prode_2026-05-30_0800.sql)"
	@echo ""
	@echo "Estado:"
	@echo "  make status               Pods, services, PVCs y apps de ArgoCD"
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

# Genera un backup SQL del estado actual de la DB
backup:
	@mkdir -p $(BACKUP_DIR)
	@f="prode_$$(date +%F_%H%M).sql"; \
	echo "→ Generando $(BACKUP_DIR)/$$f ..."; \
	$(KUBECTL) exec -n $(NAMESPACE) $(POSTGRES_POD) -- pg_dump -U postgres -d postgres > $(BACKUP_DIR)/$$f; \
	echo "✓ Backup guardado: $(BACKUP_DIR)/$$f"

# Lista los backups disponibles
list-backups:
	@ls -lht $(BACKUP_DIR)/*.sql 2>/dev/null || echo "No hay backups en $(BACKUP_DIR)/"

# Restaura la DB desde un backup: make restore FILE=prode_2026-05-30_0800.sql
restore:
	@test -n "$(FILE)" || { echo "ERROR: especificá el archivo. Uso: make restore FILE=prode_2026-05-30_0800.sql"; exit 1; }
	@test -f "$(BACKUP_DIR)/$(FILE)" || { echo "ERROR: no existe $(BACKUP_DIR)/$(FILE)"; exit 1; }
	@echo "→ Restaurando $(FILE) (se borran los datos actuales)..."
	$(KUBECTL) exec -n $(NAMESPACE) $(POSTGRES_POD) -- \
		psql -U postgres -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
	cat $(BACKUP_DIR)/$(FILE) | $(KUBECTL) exec -i -n $(NAMESPACE) $(POSTGRES_POD) -- \
		psql -U postgres -d postgres
	@echo "✓ DB restaurada desde $(FILE)"

# Estado rápido de pods, services, PVCs y apps de ArgoCD
status:
	@echo "=== Pods / Services / PVCs ==="
	@$(KUBECTL) get pods,svc,pvc -n $(NAMESPACE) | grep -E "NAME|prode"
	@echo ""
	@echo "=== ArgoCD apps ==="
	@$(KUBECTL) get application -n argocd | grep -E "NAME|prode"

# Sella una nueva variable de entorno y la mergea al SealedSecret de prode.
# Requiere kubeseal (brew install kubeseal). Correr desde la Mac.
# Uso: make seal KEY=MI_API_KEY VALUE=mi_valor_secreto
seal:
	@test -n "$(KEY)"   || { echo "ERROR: Uso: make seal KEY=MI_VAR VALUE=mi_valor"; exit 1; }
	@test -n "$(VALUE)" || { echo "ERROR: Uso: make seal KEY=MI_VAR VALUE=mi_valor"; exit 1; }
	@command -v kubeseal >/dev/null || { echo "ERROR: falta kubeseal → brew install kubeseal"; exit 1; }
	@echo "→ Bajando cert del sealed-secrets controller..."
	@ssh rpi 'sudo k3s kubectl get secret -n sealed-secrets \
		-l sealedsecrets.bitnami.com/sealed-secrets-key \
		-o jsonpath="{.items[0].data.tls\.crt}" | base64 -d' > /tmp/ss-cert.pem
	@echo "→ Sellando $(KEY)..."
	@printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: prode-secret\n  namespace: vittospace\ntype: Opaque\nstringData:\n  %s: "%s"\n' \
		"$(KEY)" "$(VALUE)" \
		| kubeseal --cert /tmp/ss-cert.pem --format yaml \
		--merge-into secrets/prode/prode-sealed-secret.yaml
	@echo "✓ $(KEY) sellado en secrets/prode/prode-sealed-secret.yaml"
	@echo ""
	@echo "  Próximos pasos:"
	@echo "  1. Si es una var del deployment/cronjob, agregarla en deploy/templates/"
	@echo "  2. git add secrets/prode/prode-sealed-secret.yaml && git commit -m 'seal: add $(KEY)' && git push"

# Shell psql directo contra la DB
db-shell:
	$(KUBECTL) exec -it -n $(NAMESPACE) $(POSTGRES_POD) -- psql -U postgres
