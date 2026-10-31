ROOT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

.PHONY: all compile docker-compile local-compile \
        test docker-test local-test local-eunit local-ct \
        dialyzer docker-dialyzer local-dialyzer \
        shell docker-shell local-shell lint-secrets \
        lint-version-bump docker-build resolve-checkouts dev-upgrade clean

REBAR3 ?= rebar3
# Passed to Dockerfile.test so the container runs as the caller rather than
# root, keeping files it writes into the bind-mounted tree owned by the caller.
export HOST_UID ?= $(shell id -u)
export HOST_GID ?= $(shell id -g)
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
	@# docker-compose.test.yml mounts a named volume at /app/_build. If that
	@# directory does not already exist, Docker creates the mount target
	@# inside the bind-mounted project directory as root, and host-side
	@# targets such as `dev-upgrade' can then no longer write there. Creating
	@# it first means Docker finds it and leaves the ownership alone.
	@mkdir -p _build
	@# An earlier root container run leaves _build and the build_cache volume
	@# owned by root. The container now runs as the caller, so it can no
	@# longer delete those files, and rebar3 reports that as dozens of
	@# "Permission denied" lines while removing a dependency. Fail with the
	@# two commands that clear it instead.
	@if [ ! -w _build ]; then \
		echo "ERROR: _build is not writable by $$(id -un)." >&2; \
		echo "  A previous container run created it as root. Clear both the" >&2; \
		echo "  directory and the stale build volume, then re-run:" >&2; \
		echo "    sudo rm -rf _build" >&2; \
		echo "    docker volume rm $$(basename $(ROOT_DIR))_build_cache" >&2; \
		exit 1; \
	fi
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
# `unlock --all` is required, not optional: rebar3 REJECTS the bare
# `rebar3 unlock` form, so dropping the flag means nothing un-pins and
# the bump resolves against the refs already in rebar.lock.
# verify-erlang-lock then reports which refs actually MOVED, against the
# baseline snapshotted before the container runs -- a missing dep is
# fatal, an unchanged ref is not (a dep already at its tip correctly
# does not move).
dev-upgrade: resolve-checkouts
	@mkdir -p _build
	@sh scripts/verify-erlang-lock --snapshot > _build/rebar-lock.before
	@target='$(DEP)'; \
	if [ -z "$$target" ]; then \
		echo "Bumping all git deps to latest allowed refs..."; \
		unlock_cmd='rebar3 unlock --all'; \
		rm_cmd='rm -rf _build/default/lib _build/test/lib'; \
	else \
		echo "Bumping $$target..."; \
		unlock_cmd="rebar3 unlock $$target"; \
		rm_cmd="rm -rf _build/default/lib/$$target _build/test/lib/$$target"; \
	fi; \
	$(COMPOSE) run --rm test sh -c "$$unlock_cmd && $$rm_cmd && rebar3 deps && rebar3 lock"
	@rc=0; sh scripts/verify-erlang-lock --since _build/rebar-lock.before $(DEP) || rc=$$?; \
		rm -f _build/rebar-lock.before; \
		exit $$rc

clean:
	rm -rf _build $(CHECKOUTS_OVERRIDE)
