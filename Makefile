# Convenience targets. The real work lives in scripts/ -- this file only gives the things you do
# repeatedly a name short enough to remember.

.DEFAULT_GOAL := help
.PHONY: help install app check

help:  ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-8s %s\n", $$1, $$2}'

install:  ## Rebuild the macOS app and install it to /Applications
	@./scripts/bundle_app.sh --install

app:  ## Rebuild the macOS app, leaving it under swift/.build/app/
	@./scripts/bundle_app.sh

check:  ## Lint and test the Swift package
	@./scripts/validate.sh
