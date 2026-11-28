FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh
COPY ./schema.sql schema.sql
COPY ./generate.sql generate.sql
COPY ./sums.sql sums.sql
COPY ./filters.ini filters.ini

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
