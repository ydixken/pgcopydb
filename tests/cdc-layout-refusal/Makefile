# Copyright (c) 2021 The PostgreSQL Global Development Group.
# Licensed under the PostgreSQL License.

# The suite runs two binaries: the one of this checkout, and the one of
# 9d8b660, the commit the performance mode has to stay compatible with.
OLD = 9d8b660
OLD_VERSION = 0.18.159.g$(OLD)
PGVERSION ?= 16

test: down build
	@status=0; docker compose run --rm --remove-orphans test || status=$$?; \
	docker compose down -v --remove-orphans || exit 1; exit $$status

down:
	docker compose down -v --remove-orphans

build: pgcopydb-$(OLD)
	docker compose build --quiet

# git archive carries neither version nor GIT-VERSION-FILE, which the
# Dockerfile of that commit copies, so GIT-VERSION-GEN takes VERSION instead.
# The binary is compiled against the PostgreSQL of this run, so a local
# switch of PGVERSION needs make clean first.  A CI job starts without it.
pgcopydb-$(OLD):
	rm -rf old && mkdir old
	git -C ../.. archive $(OLD) | tar -x -C old
	cd old && VERSION=$(OLD_VERSION) $(MAKE) version
	cd old && docker build -q -t pgcopydb-old:$(OLD) \
	  --build-arg PGVERSION=$(PGVERSION) --target build .
	docker run --rm --entrypoint cat pgcopydb-old:$(OLD) \
	  /usr/lib/postgresql/$(PGVERSION)/bin/pgcopydb > $@.tmp
	chmod +x $@.tmp && mv $@.tmp $@
	rm -rf old

clean:
	rm -rf old pgcopydb-$(OLD)

.PHONY: test down build clean
