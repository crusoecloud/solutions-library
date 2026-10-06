.PHONY: all lint format tests integration_tests spell_check spell_fix

all: lint tests

######################
# TESTING
######################

tests:
	poetry run pytest tests/unit_tests

integration_tests:
	poetry run pytest tests/integration_tests

######################
# LINTING AND FORMATTING
######################

lint:
	poetry run ruff check .
	poetry run ruff format . --diff
	poetry run mypy .

lint_diff:
	git diff --name-only --diff-filter=ACMR HEAD | xargs poetry run ruff check
	git diff --name-only --diff-filter=ACMR HEAD | xargs poetry run ruff format --diff

format:
	poetry run ruff format .
	poetry run ruff check --fix .

format_diff:
	git diff --name-only --diff-filter=ACMR HEAD | xargs poetry run ruff format
	git diff --name-only --diff-filter=ACMR HEAD | xargs poetry run ruff check --fix

spell_check:
	poetry run codespell --toml pyproject.toml

spell_fix:
	poetry run codespell --toml pyproject.toml -w
