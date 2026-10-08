FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh
COPY ./kill-at-commit.gdb kill-at-commit.gdb

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
