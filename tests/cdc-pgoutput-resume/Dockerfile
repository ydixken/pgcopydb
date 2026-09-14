FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh
COPY ./flush-order.gdb flush-order.gdb

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
