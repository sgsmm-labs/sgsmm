# SGSMM backtest harness — convenience targets.

.PHONY: setup venv install test lint format clean jupyter

PY := python
VENV := .venv

setup: venv install ## Create venv + install deps + dev deps

venv: ## Create Python venv
	$(PY) -m venv $(VENV)
	@echo "Activate with: source $(VENV)/bin/activate (Unix) or .venv\\Scripts\\activate (Windows)"

install: ## Install runtime + dev dependencies
	$(VENV)/bin/pip install -U pip
	$(VENV)/bin/pip install -e ".[dev]"

test: ## Run unit tests
	$(VENV)/bin/pytest tests/ -v

lint: ## Run ruff lint
	$(VENV)/bin/ruff check src/ tests/

format: ## Auto-format with ruff
	$(VENV)/bin/ruff format src/ tests/

clean: ## Remove venv + caches
	rm -rf $(VENV) .pytest_cache .ruff_cache .mypy_cache __pycache__ src/__pycache__ tests/__pycache__

jupyter: ## Launch JupyterLab in the venv
	$(VENV)/bin/jupyter lab notebooks/
