FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh
COPY ./hold-at-endpos.gdb hold-at-endpos.gdb

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
