FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh
COPY ./apply-error.sh apply-error.sh
COPY ./shutdown.sh shutdown.sh
COPY ./apply-kill.gdb apply-kill.gdb
COPY ./dml.sql dml.sql
COPY ./ddl.sql ddl.sql
COPY ./special-dml.sql special-dml.sql
COPY ./special-ddl.sql special-ddl.sql
COPY ./stmt.sql stmt.sql
COPY ./output.pgout output.pgout

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
