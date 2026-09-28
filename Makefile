.PHONY: dbt-dev dbt-build dbt-test

DBT_DEVELOPER_NAME ?= alice

dbt-dev:
	bash scripts/dev_build.sh

dbt-build:
	bash scripts/dev_build.sh $(MODEL)

dbt-test:
	bash scripts/dev_test.sh $(MODEL)