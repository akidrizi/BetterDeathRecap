# BetterDeathRecap — developer shortcuts.
# Thin wrappers over package.sh (the single source of truth for what ships)
# and luacheck. Run from the project root, e.g. `make deploy`.

.PHONY: help lint build deploy clean

# Override the deploy destination:  make deploy DEST="/d/WoW/_retail_/Interface/AddOns"
DEST ?=

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
		| awk -F':.*## ' '{printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'

lint: ## Lint all Lua source with luacheck
	luacheck src/

build: ## Build the release zip -> dist/<version>.zip
	bash package.sh

package: build ## Alias for build

deploy: ## Deploy to the live WoW client (DEST=... to override the AddOns dir)
	bash package.sh --deploy $(if $(DEST),--dest "$(DEST)",)

clean: ## Remove build output
	rm -rf dist
