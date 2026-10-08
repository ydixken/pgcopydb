FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh
COPY ./source.sql source.sql
COPY ./target.sql target.sql
COPY ./filters.ini filters.ini
COPY ./expected.txt expected.txt

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
