# Copyright (c) 2021 The PostgreSQL Global Development Group.
# Licensed under the PostgreSQL License.

test: down run down ;

run: build
	docker compose run --remove-orphans test

down:
	docker compose down --remove-orphans

build:
	docker compose build --quiet

.PHONY: run down build test

# the same scenario through pgoutput, on a new source and target
test: run-pgoutput

run-pgoutput: build
	docker compose down --remove-orphans
	docker compose run --remove-orphans -e PGCOPYDB_OUTPUT_PLUGIN=pgoutput test

.PHONY: run-pgoutput
