SHELL := /bin/bash
.DEFAULT_GOAL := test

# Files that are part of the repository, excluding generated/build state.
SHELL_FILES := $(shell find . -path ./.git -prune -o -path ./build -prune -o -type f \( -name '*.sh' -o -name '*.bash' \) -print | sort)
PERL_FILES := $(shell find . -path ./.git -prune -o -path ./build -prune -o -type f \( -name '*.pl' -o -name '*.pm' \) -print | sort)
PYTHON_FILES := $(shell find . -path ./.git -prune -o -path ./build -prune -o -type f -name '*.py' -print | sort)

.PHONY: test test-all lint lint-shell lint-perl lint-python shellcheck test-unit test-netns test-package clean

test: lint test-unit

test-all: test test-netns

lint: lint-shell lint-perl lint-python shellcheck

lint-shell:
	@set -e; \
	if [ -z "$(SHELL_FILES)" ]; then echo "lint-shell: no shell files"; exit 0; fi; \
	for f in $(SHELL_FILES); do echo "bash -n $$f"; bash -n "$$f"; done

lint-perl:
	@set -e; \
	if [ -z "$(PERL_FILES)" ]; then echo "lint-perl: no Perl files"; exit 0; fi; \
	for f in $(PERL_FILES); do echo "perl -c $$f"; perl -c "$$f" >/dev/null; done

lint-python:
	@set -e; \
	if [ -z "$(PYTHON_FILES)" ]; then echo "lint-python: no Python files"; exit 0; fi; \
	for f in $(PYTHON_FILES); do echo "py_compile $$f"; python3 -m py_compile "$$f"; done

shellcheck:
	@set -e; \
	if ! command -v shellcheck >/dev/null 2>&1; then echo "shellcheck: not installed; skipped"; exit 0; fi; \
	if [ -z "$(SHELL_FILES)" ]; then echo "shellcheck: no shell files"; exit 0; fi; \
	shellcheck -x $(SHELL_FILES)

test-unit:
	bash test/unit/run.sh

test-package:
	bash test/package/lifecycle.sh

# Privileged container; generic Linux evidence only, not EdgeOS evidence.
test-netns:
	REQUIRE_NETNS_TEST=1 bash test/integration/run-in-docker.sh

clean:
	rm -rf build
