.PHONY: run run-pfizer test lint coverage docker-build docker-run template clean help

# Default target
help:
	@echo ""
	@echo "tool-corporate-research-analytics"
	@echo "──────────────────────────────────"
	@echo "  make run          Run pipeline with Eli Lilly example"
	@echo "  make run-pfizer   Run pipeline with Pfizer example"
	@echo "  make test         Run full test suite"
	@echo "  make lint         Run black + flake8"
	@echo "  make coverage     Run tests with coverage report"
	@echo "  make template     Print empty JSON input template"
	@echo "  make docker-build Build production Docker image"
	@echo "  make docker-run   Run pipeline in Docker (Eli Lilly)"
	@echo "  make clean        Remove __pycache__ and .coverage"
	@echo ""

run:
	python -m src.main \
		--name "Eli Lilly and Company" \
		--url  "lilly.com" \
		--input examples/eli_lilly.json

run-pfizer:
	python -m src.main \
		--name "Pfizer Inc." \
		--url  "pfizer.com" \
		--input examples/pfizer.json

run-json:
	python -m src.main \
		--name "Eli Lilly and Company" \
		--url  "lilly.com" \
		--input examples/eli_lilly.json \
		--format json \
		--output output/eli_lilly.json

test:
	pytest tests/ -v

lint:
	black --check src/ tests/
	flake8 src/ tests/ --max-line-length 88

coverage:
	pytest tests/ --cov=src --cov-report=term-missing

template:
	python -m src.main --name dummy --url dummy --template

docker-build:
	docker build -t corp-analytics-tool .

docker-run:
	docker run --rm \
		--env-file .env \
		-v "$(PWD)/examples:/app/examples:ro" \
		-v "$(PWD)/output:/app/output" \
		corp-analytics-tool \
		--name "Eli Lilly and Company" \
		--url  "lilly.com" \
		--input examples/eli_lilly.json \
		--output output/eli_lilly_docker.md

clean:
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	rm -f .coverage
	rm -f output/*.md output/*.json
