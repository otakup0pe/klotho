ROOT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

.PHONY: all compile docker-compile local-compile \
        test docker-test local-test local-eunit local-ct \
        dialyzer docker-dialyzer local-dialyzer \
        shell docker-shell local-shell lint-secrets \
        lint-version-bump docker-build resolve-checkouts dev-upgrade clean

REBAR3 ?= rebar3
CHECKOUTS_OVERRIDE = docker-compose.checkouts.yml
CHECKOUTS_DIR ?=
COMPOSE ?= docker compose -f docker-compose.test.yml -f $(CHECKOUTS_OVERRIDE)
GITLEAKS_IMAGE ?= ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f
GITLEAKS_MODE ?= git
GITLEAKS_SOURCE ?= .

export BUILDX_BUILDER ?= default

all: compile

compile: docker-compile
test: docker-test
dialyzer: docker-dialyzer
shell: docker-shell

resolve-checkouts:
	@sh scripts/resolve-checkouts "$(CHECKOUTS_DIR)" > $(CHECKOUTS_OVERRIDE)

docker-build: resolve-checkouts
	$(COMPOSE) build

docker-compile: docker-build
	$(COMPOSE) run --rm test make local-compile

docker-test: docker-build
	$(COMPOSE) run --rm test

docker-dialyzer: docker-build
	$(COMPOSE) run --rm test make local-dialyzer

docker-shell: docker-build
	$(COMPOSE) run --rm test make local-shell

local-compile:
	$(REBAR3) compile

local-test: local-eunit local-ct local-dialyzer
	$(REBAR3) cover

local-eunit:
	$(REBAR3) eunit --sys_config conf/klotho-test.config

local-ct:
	$(REBAR3) ct --sys_config conf/klotho-test.config

local-dialyzer:
	$(REBAR3) dialyzer

local-shell:
	$(REBAR3) shell

lint-version-bump:
	@test "$$(printf 'fix parser #patch\n' | sh scripts/version-bump-part)" = patch
	@test "$$(printf 'add tool BUMP:minor\n' | sh scripts/version-bump-part)" = minor
	@test "$$(printf 'break API bump:major\n' | sh scripts/version-bump-part)" = major
	@test "$$(printf 'major wins #patch #major\n' | sh scripts/version-bump-part)" = major
	@test -z "$$(printf 'ordinary commit\n' | sh scripts/version-bump-part)"

lint-secrets:
	docker run --rm \
		--user "$$(id -u):$$(id -g)" \
		--network none \
		--read-only \
		--cap-drop=ALL \
		--tmpfs /tmp:rw,noexec,nosuid,size=16m \
		-v "$(ROOT_DIR):/repo:ro" \
		-w /repo \
		$(GITLEAKS_IMAGE) $(GITLEAKS_MODE) $(GITLEAKS_SOURCE) --redact --no-banner --verbose

# Unlock before resolving because rebar3 upgrade can leave git branch
# dependencies pinned to stale refs while still exiting successfully.
dev-upgrade: resolve-checkouts
	@target='$(DEP)'; \
	if [ -z "$$target" ]; then \
		echo "Bumping all git deps to latest allowed refs..."; \
		unlock_cmd='rebar3 unlock'; \
		rm_cmd='rm -rf _build/default/lib _build/test/lib'; \
	else \
		echo "Bumping $$target..."; \
		unlock_cmd="rebar3 unlock $$target"; \
		rm_cmd="rm -rf _build/default/lib/$$target _build/test/lib/$$target"; \
	fi; \
	$(COMPOSE) run --rm test sh -c "$$unlock_cmd && $$rm_cmd && rebar3 deps && rebar3 lock"
	@sh scripts/verify-erlang-lock $(DEP)

clean:
	rm -rf _build $(CHECKOUTS_OVERRIDE)
