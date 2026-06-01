# SGSMM backtest harness — convenience targets.

.PHONY: setup venv install test lint format clean jupyter

PY := python
VENV := .venv

# OS-aware venv binary directory: Scripts on Windows, bin on Unix/macOS
ifeq ($(OS),Windows_NT)
  VENV_BIN := $(VENV)/Scripts
else
  VENV_BIN := $(VENV)/bin
endif

setup: venv install ## Create venv + install deps + dev deps

venv: ## Create Python venv
	$(PY) -m venv $(VENV)
	@echo "Activate with: source $(VENV)/bin/activate (Unix) or .venv\\Scripts\\activate (Windows)"

install: ## Install runtime + dev dependencies
	$(VENV_BIN)/pip install -U pip
	$(VENV_BIN)/pip install -e ".[dev]"

test: ## Run unit tests
	$(VENV_BIN)/pytest tests/ -v

lint: ## Run ruff lint
	$(VENV_BIN)/ruff check src/ tests/

format: ## Auto-format with ruff
	$(VENV_BIN)/ruff format src/ tests/

clean: ## Remove venv + caches
	rm -rf $(VENV) .pytest_cache .ruff_cache .mypy_cache __pycache__ src/__pycache__ tests/__pycache__

jupyter: ## Launch JupyterLab in the venv
	$(VENV_BIN)/jupyter lab notebooks/
