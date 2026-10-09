FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh
COPY ./hold-at-identify-system.gdb hold-at-identify-system.gdb

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
