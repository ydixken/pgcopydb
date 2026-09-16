FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh ./in-flight.gdb ./bootstrap.sh ./publication-retry.sql ./

USER docker
CMD ["bash", "/usr/src/pgcopydb/copydb.sh"]
