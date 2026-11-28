# Copyright (c) 2021 The PostgreSQL Global Development Group.
# Licensed under the PostgreSQL License.

test: down build
	@status=0; docker compose run --rm --remove-orphans test || status=$$?; \
	docker compose down -v --remove-orphans || exit 1; exit $$status

down:
	docker compose down -v --remove-orphans

build:
	docker compose build --quiet

.PHONY: test down build
