# Copyright (c) 2021 The PostgreSQL Global Development Group.
# Licensed under the PostgreSQL License.

test: down run lo-resume sysv-signals roles ;

run: build
	docker compose run --remove-orphans test

# make runs the down target once per invocation; this one needs new servers
lo-resume: build
	docker compose down --remove-orphans
	docker compose run --remove-orphans test /usr/src/pgcopydb/lo-resume.sh

# new servers as well: --all-databases copies every database the others left
sysv-signals: build
	docker compose down --remove-orphans
	docker compose run --remove-orphans test /usr/src/pgcopydb/sysv-signals.sh

# new servers again, for the same reason
roles: build
	docker compose down --remove-orphans
	docker compose run --remove-orphans test /usr/src/pgcopydb/roles.sh

down:
	docker compose down --remove-orphans

build:
	docker compose build --quiet

.PHONY: run lo-resume sysv-signals roles down build test
