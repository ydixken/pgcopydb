FROM pagila

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh ./kill-at.gdb ./flush-sync.gdb ./

USER docker
CMD ["bash", "/usr/src/pgcopydb/copydb.sh"]
