FROM pagila

RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh
COPY ./verify.py verify.py

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
