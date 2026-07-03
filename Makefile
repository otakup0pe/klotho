ROOT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

.PHONY: all compile docker-compile local-compile \
        test docker-test local-test local-eunit local-ct \
        dialyzer docker-dialyzer local-dialyzer \
        shell docker-shell local-shell \
        docker-build resolve-checkouts dev-upgrade clean

REBAR3 ?= rebar3
CHECKOUTS_OVERRIDE = docker-compose.checkouts.yml
COMPOSE ?= docker compose -f docker-compose.test.yml -f $(CHECKOUTS_OVERRIDE)

export BUILDX_BUILDER ?= default

all: compile

compile: docker-compile
test: docker-test
dialyzer: docker-dialyzer
shell: docker-shell

resolve-checkouts:
	@sh scripts/resolve-checkouts > $(CHECKOUTS_OVERRIDE)

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

# `make dev-upgrade`             -- bump every git dep to latest branch tip
# `make dev-upgrade DEP=erl_mcp` -- bump just that dep
# Runs the reliable unlock + rm + deps + lock sequence inside the test
# container, then verifies rebar.lock was actually rewritten on the host.
# `rebar3 upgrade` alone has been observed to silently no-op for git
# branch deps. See: memory://workflow/erlang-dep-management
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
