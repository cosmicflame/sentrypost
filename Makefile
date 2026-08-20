# Makefile for the sentrypost project

.PHONY: lint
lint:
	@echo "Running shellcheck on sentrypost.sh…"
	@shellcheck sentrypost.sh
