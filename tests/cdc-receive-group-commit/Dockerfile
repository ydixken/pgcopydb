FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh ./hold-batch.gdb ./

USER docker
CMD ["bash", "/usr/src/pgcopydb/copydb.sh"]
