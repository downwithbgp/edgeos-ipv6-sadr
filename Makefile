SHELL := /bin/bash
.DEFAULT_GOAL := test

# Files that are part of the repository, excluding generated/build state.
REPO_FILES := $(shell find . -path ./.git -prune -o -path ./build -prune -o -type f -print)
SHELL_FILES := $(shell find . -path ./.git -prune -o -path ./build -prune -o -type f \( -name '*.sh' -o -name '*.bash' \) -print | sort)
PERL_FILES := $(shell find . -path ./.git -prune -o -path ./build -prune -o -type f \( -name '*.pl' -o -name '*.pm' \) -print | sort)

.PHONY: test test-all lint lint-shell lint-perl shellcheck test-unit test-netns clean

test: lint test-unit

test-all: test test-netns

lint: lint-shell lint-perl shellcheck

lint-shell:
	@set -e; \
	if [ -z "$(SHELL_FILES)" ]; then echo "lint-shell: no shell files"; exit 0; fi; \
	for f in $(SHELL_FILES); do echo "bash -n $$f"; bash -n "$$f"; done

lint-perl:
	@set -e; \
	if [ -z "$(PERL_FILES)" ]; then echo "lint-perl: no Perl files"; exit 0; fi; \
	for f in $(PERL_FILES); do echo "perl -c $$f"; perl -c "$$f" >/dev/null; done

shellcheck:
	@set -e; \
	if ! command -v shellcheck >/dev/null 2>&1; then echo "shellcheck: not installed; skipped"; exit 0; fi; \
	if [ -z "$(SHELL_FILES)" ]; then echo "shellcheck: no shell files"; exit 0; fi; \
	shellcheck -x $(SHELL_FILES)

test-unit:
	bash test/unit/run.sh

# Privileged container; generic Linux evidence only, not EdgeOS evidence.
test-netns:
	bash test/integration/run-in-docker.sh

clean:
	rm -rf build
