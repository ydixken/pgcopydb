FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh ./ddl.sql ./followed.sql ./tail.sql ./

USER docker
CMD ["bash", "/usr/src/pgcopydb/copydb.sh"]
