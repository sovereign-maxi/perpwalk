.PHONY: help setup deps compile test credo dialyzer audit lint format check server console clean release

# Default target
help:
	@echo "PerpWalk - Anonymous prediction markets denominated in Monero"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Setup:"
	@echo "  setup      Install dependencies and prepare project"
	@echo "  deps       Fetch and compile dependencies"
	@echo ""
	@echo "Development:"
	@echo "  server     Start Phoenix server (http://localhost:4200)"
	@echo "  console    Start interactive Elixir shell with app loaded"
	@echo "  compile    Compile the project"
	@echo "  format     Format all Elixir code"
	@echo ""
	@echo "Quality:"
	@echo "  test       Run all tests"
	@echo "  credo      Run Credo static analysis"
	@echo "  dialyzer   Run Dialyzer type checking"
	@echo "  audit      Run Mix Audit dependency security check"
	@echo "  lint       Run all linters (credo + compile warnings + dialyzer)"
	@echo "  check      Run all checks (compile, test, lint, audit)"
	@echo ""
	@echo "Cleanup:"
	@echo "  clean      Remove build artifacts"
	@echo ""

# Setup
setup: deps
	@echo "Setup complete!"

deps:
	mix deps.get
	mix deps.compile

# Development
compile:
	mix compile --warnings-as-errors

server:
	iex -S mix phx.server

console:
	iex -S mix

format:
	mix format

# Quality
test:
	mix test

credo:
	mix credo --strict

dialyzer:
	mix dialyzer

audit:
	mix deps.audit

lint: compile credo dialyzer
	@echo "All lint checks passed!"

check: compile test credo dialyzer audit
	@echo ""
	@echo "All checks passed!"

# Cleanup
clean:
	rm -rf _build deps
	rm -rf data/wal/*
	rm -rf data/dets/*
	rm -rf data/backups/*

# Production
release:
	MIX_ENV=prod mix release

# Shortcuts
t: test
c: compile
s: server
l: lint
