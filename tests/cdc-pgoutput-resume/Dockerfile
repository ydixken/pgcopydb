FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh
COPY ./flush-order.gdb flush-order.gdb
COPY ./flush-order-raw.gdb flush-order-raw.gdb
COPY ./start-order.gdb start-order.gdb

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
