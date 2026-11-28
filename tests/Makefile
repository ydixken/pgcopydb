# Copyright (c) 2021 The PostgreSQL Global Development Group.
# Licensed under the PostgreSQL License.

PGVERSION ?= 16
export PGVERSION
BUILD_ARGS = --build-arg PGVERSION=$(PGVERSION)

all: pagila pagila-multi-steps blobs unit filtering extensions \
	 partitioned-target all-databases \
	 cdc-wal2json cdc-test-decoding cdc-endpos-mid-txn cdc-low-level \
	 cdc-replica-identity-index cdc-replica-identity-full \
	 cdc-partitioned-target cdc-matview \
	 cdc-endpos-in-multi-wal-txn cdc-file-rotation cdc-file-rotation-live \
	 cdc-pgoutput cdc-pgoutput-resume cdc-keepalive cdc-filtering-pgoutput \
	 cdc-interleaved-commits cdc-resend-after-reconnect cdc-commit-order-resume \
	 cdc-truncate-multi cdc-copy-multi-insert cdc-origin-abort \
	 cdc-receive-drain-error cdc-receive-reconnect-dying-source \
	 cdc-receive-status-interval cdc-apply-wakeup catalog-stmt-cache \
	 cdc-receive-group-commit cdc-endpos-before-txn cdc-origin-source cdc-wal-workers \
	 cdc-wal-workers-endpos cdc-wal-workers-fk cdc-wal-workers-resume \
	 cdc-wal-workers-idle wal-workers-assign cdc-spool-format \
	 follow-wal2json follow-9.6 follow-data-only \
	 follow-pgoutput follow-filtering follow-resume-snapshot \
	 orphaned-target-backend split-table-resume \
	 all-databases-resume large-objects-resume json-logs \
	 defer-indexes defer-indexes-queue defer-indexes-all-databases \
	 cdc-pgoutput-performance cdc-low-level-performance \
	 cdc-filtering-pgoutput-performance cdc-replica-identity-full-performance \
	 cdc-truncate-multi-performance cdc-receive-drain-error-performance \
	 cdc-receive-reconnect-dying-source-performance cdc-receive-status-interval-performance \
	 cdc-origin-abort-performance cdc-apply-wakeup-performance \
	 follow-filtering-performance follow-resume-snapshot-performance \
	 cdc-replica-identity-index-performance cdc-partitioned-target-performance \
	 cdc-pgoutput-resume-performance \
	 cdc-commit-order-resume-performance cdc-copy-multi-insert-performance \
	 cdc-interleaved-commits-performance cdc-resend-after-reconnect-performance;

pagila: build
	$(MAKE) -C $@

pagila-multi-steps: build
	$(MAKE) -C $@

pagila-standby: build
	$(MAKE) -C $@

blobs: build
	$(MAKE) -C $@

unit: build
	$(MAKE) -C $@

filtering: build
	$(MAKE) -C $@

partitioned-target: build
	$(MAKE) -C $@

extensions: build
	$(MAKE) -C $@

cdc-wal2json: build
	$(MAKE) -C $@

cdc-test-decoding: build
	$(MAKE) -C $@

cdc-endpos-mid-txn: build
	$(MAKE) -C $@

cdc-low-level: build
	$(MAKE) -C $@

cdc-replica-identity-index: build
	$(MAKE) -C $@

cdc-replica-identity-full: build
	$(MAKE) -C $@

cdc-partitioned-target: build
	$(MAKE) -C $@

cdc-matview: build
	$(MAKE) -C $@

follow-wal2json: build
	$(MAKE) -C $@

follow-9.6: build
	$(MAKE) -C $@

follow-data-only: build
	$(MAKE) -C $@

cdc-endpos-in-multi-wal-txn: build
	$(MAKE) -C $@

cdc-file-rotation: build
	$(MAKE) -C $@

cdc-file-rotation-live: build
	$(MAKE) -C $@

cdc-pgoutput: build
	$(MAKE) -C $@

cdc-pgoutput-resume: build
	$(MAKE) -C $@

cdc-keepalive: build
	$(MAKE) -C $@

cdc-wal-workers: build
	$(MAKE) -C $@

cdc-wal-workers-endpos: build
	$(MAKE) -C $@

cdc-wal-workers-fk: build
	$(MAKE) -C $@

cdc-wal-workers-resume: build
	$(MAKE) -C $@

cdc-wal-workers-idle: build
	$(MAKE) -C $@

cdc-filtering-pgoutput: build
	$(MAKE) -C $@

cdc-interleaved-commits: build
	$(MAKE) -C $@

cdc-resend-after-reconnect: build
	$(MAKE) -C $@

cdc-commit-order-resume: build
	$(MAKE) -C $@

cdc-truncate-multi: build
	$(MAKE) -C $@

cdc-copy-multi-insert: build
	$(MAKE) -C $@

cdc-origin-abort: build
	$(MAKE) -C $@

cdc-receive-drain-error: build
	$(MAKE) -C $@

cdc-receive-reconnect-dying-source: build
	$(MAKE) -C $@

cdc-receive-status-interval: build
	$(MAKE) -C $@

cdc-apply-wakeup: build
	$(MAKE) -C $@

cdc-receive-group-commit: build
	$(MAKE) -C $@

cdc-endpos-before-txn: build
	$(MAKE) -C $@

cdc-origin-source: build
	$(MAKE) -C $@

# builds its own image from the build stage of the top-level Dockerfile
catalog-stmt-cache:
	$(MAKE) -C $@

# builds its own image from the build stage of the top-level Dockerfile
wal-workers-assign:
	$(MAKE) -C $@

# builds its own image from the build stage of the top-level Dockerfile
cdc-spool-format:
	$(MAKE) -C $@

cdc-parallel-crash: build
	$(MAKE) -C $@

follow-pgoutput: build
	$(MAKE) -C $@

follow-filtering: build
	$(MAKE) -C $@

follow-resume-snapshot: build
	$(MAKE) -C $@

orphaned-target-backend: build
	$(MAKE) -C $@

split-table-resume: build
	$(MAKE) -C $@

all-databases-resume: build
	$(MAKE) -C $@

large-objects-resume: build
	$(MAKE) -C $@

json-logs: build
	$(MAKE) -C $@

defer-indexes: build
	$(MAKE) -C $@

defer-indexes-queue: build
	$(MAKE) -C $@

defer-indexes-all-databases: build
	$(MAKE) -C $@

timescaledb: build
	$(MAKE) -C $@

citus: build
	$(MAKE) -C $@

# The performance pass of a kept suite: the same script, with the raw spool.
# The sqlite pass is the suite's own entry, which leaves the variable unset.
cdc-pgoutput-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-pgoutput

cdc-low-level-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-low-level

cdc-filtering-pgoutput-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-filtering-pgoutput

cdc-replica-identity-full-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-replica-identity-full

cdc-truncate-multi-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-truncate-multi

cdc-receive-drain-error-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-receive-drain-error

cdc-receive-reconnect-dying-source-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-receive-reconnect-dying-source

cdc-receive-status-interval-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-receive-status-interval

cdc-origin-abort-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-origin-abort

cdc-apply-wakeup-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-apply-wakeup

follow-filtering-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C follow-filtering

follow-resume-snapshot-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C follow-resume-snapshot

cdc-commit-order-resume-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-commit-order-resume

cdc-copy-multi-insert-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-copy-multi-insert

cdc-interleaved-commits-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-interleaved-commits

cdc-resend-after-reconnect-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-resend-after-reconnect

# These two suites run both plugins, and test_decoding has no performance mode
cdc-replica-identity-index-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-replica-identity-index down run-pgoutput down

cdc-partitioned-target-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-partitioned-target down run-pgoutput down

cdc-pgoutput-resume-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-pgoutput-resume

# Not in "all" and not in the CI lists: the group rule holds by a margin of a
# few hundred transactions on the raw spool, where sqlite mode commits 20001
# transactions in 6 batches. Run it by hand until that is settled.
cdc-receive-group-commit-performance: build
	PGCOPYDB_FOLLOW_MODE=performance $(MAKE) -C cdc-receive-group-commit

build:
	@docker image inspect pagila > /dev/null 2>&1 \
	  && echo "pagila image already present — skipping build (run 'make force-build' to rebuild)" \
	  || docker build $(BUILD_ARGS) -t pagila -f Dockerfile.pagila .

build-multi:
	@docker image inspect multi > /dev/null 2>&1 \
	  && echo "multi image already present — skipping build (run 'make force-build' to rebuild)" \
	  || docker build $(BUILD_ARGS) -t multi -f Dockerfile.multi .

# Force a full rebuild even when the images already exist locally
# (use after Dockerfile changes or when switching PGVERSION)
force-build:
	docker build $(BUILD_ARGS) -t pagila -f Dockerfile.pagila .
	docker build $(BUILD_ARGS) -t multi -f Dockerfile.multi .

all-databases: build-multi
	$(MAKE) -C $@

three-databases: build-multi
	$(MAKE) -C $@

# Remove the cached images so the next test starts from scratch
clean-images:
	-docker rmi pagila multi 2>/dev/null; true

.PHONY: all build build-pagila build-multi force-build clean-images
.PHONY: pagila pagila-multi-steps blobs unit filtering partitioned-target extensions
.PHONY: all-databases three-databases
.PHONY: cdc-wal2json cdc-test-decoding cdc-endpos-mid-txn cdc-low-level cdc-replica-identity-index cdc-partitioned-target
.PHONY: cdc-replica-identity-full
.PHONY: cdc-endpos-in-multi-wal-txn cdc-file-rotation cdc-file-rotation-live
.PHONY: cdc-pgoutput cdc-pgoutput-resume cdc-keepalive cdc-filtering-pgoutput follow-pgoutput follow-filtering
.PHONY: cdc-interleaved-commits cdc-resend-after-reconnect cdc-commit-order-resume
.PHONY: cdc-truncate-multi cdc-copy-multi-insert cdc-origin-abort cdc-receive-drain-error
.PHONY: cdc-receive-reconnect-dying-source cdc-receive-status-interval cdc-apply-wakeup
.PHONY: catalog-stmt-cache cdc-receive-group-commit cdc-endpos-before-txn cdc-origin-source cdc-wal-workers
.PHONY: cdc-wal-workers-endpos cdc-wal-workers-fk cdc-wal-workers-resume
.PHONY: cdc-wal-workers-idle wal-workers-assign cdc-spool-format cdc-parallel-crash
.PHONY: follow-wal2json follow-9.6 follow-resume-snapshot orphaned-target-backend split-table-resume
.PHONY: cdc-pgoutput-performance cdc-low-level-performance cdc-filtering-pgoutput-performance
.PHONY: cdc-replica-identity-full-performance cdc-truncate-multi-performance cdc-receive-drain-error-performance
.PHONY: cdc-receive-reconnect-dying-source-performance cdc-receive-status-interval-performance cdc-origin-abort-performance
.PHONY: cdc-apply-wakeup-performance follow-filtering-performance follow-resume-snapshot-performance
.PHONY: cdc-replica-identity-index-performance cdc-partitioned-target-performance
.PHONY: cdc-pgoutput-resume-performance cdc-receive-group-commit-performance
.PHONY: cdc-commit-order-resume-performance cdc-copy-multi-insert-performance
.PHONY: cdc-interleaved-commits-performance cdc-resend-after-reconnect-performance
.PHONY: all-databases-resume large-objects-resume json-logs
.PHONY: defer-indexes defer-indexes-queue defer-indexes-all-databases
.PHONY: timescaledb citus
