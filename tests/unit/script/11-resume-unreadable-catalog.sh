#! /bin/bash

set -x
set -e

# This script expects the following environment variables to be set:
#
#  - PGCOPYDB_SOURCE_PGURI
#  - PGCOPYDB_TARGET_PGURI

# A --resume --not-consistent run that cannot read its source catalog (here
# not a database; on a full disk an I/O error) must report the read failure
# rather than ask for the --not-consistent it was given.

WORKDIR=/tmp/resume-unreadable-catalog

mkdir -p ${WORKDIR}/schema
echo "not a database" > ${WORKDIR}/schema/source.db

pgcopydb clone --dir ${WORKDIR} --resume --not-consistent \
  > ${WORKDIR}/clone.log 2>&1 || true

grep -c "requires option --not-consistent" ${WORKDIR}/clone.log || true
grep -o "file is not a database" ${WORKDIR}/clone.log | head -1
grep -o "Failed to check options against the previous run" ${WORKDIR}/clone.log
