FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh ./

USER docker
CMD ["bash", "/usr/src/pgcopydb/copydb.sh"]
