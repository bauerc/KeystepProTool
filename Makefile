# Convenience targets. The real work lives in scripts/ and in uv -- this file only gives the two
# things you do repeatedly a name short enough to remember.
#
# Deliberately not a console entry point in pyproject.toml: those ship inside the wheel, so an
# `install-app` command would land on every machine that installs this package, including the Linux
# ones with no Swift toolchain and no checkout to build from, and crash when run.

.DEFAULT_GOAL := help
.PHONY: help install app check test

help:  ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-8s %s\n", $$1, $$2}'

install:  ## Rebuild the macOS app and install it to /Applications
	@./scripts/bundle_app.sh --install

app:  ## Rebuild the macOS app, leaving it under swift/.build/app/
	@./scripts/bundle_app.sh

check:  ## Format, typecheck, test and parity-check both toolchains
	@./scripts/validate.sh

test:  ## The test suite as CI runs it, hardware tests deselected
	@uv run pytest -m "not hardware"
