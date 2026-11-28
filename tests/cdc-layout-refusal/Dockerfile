FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh
COPY --chmod=755 ./pgcopydb-9d8b660 /usr/local/bin/pgcopydb-9d8b660

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
