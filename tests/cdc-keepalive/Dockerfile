FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh ./in-flight.gdb ./

USER docker
CMD ["bash", "/usr/src/pgcopydb/copydb.sh"]
