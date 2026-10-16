FROM pagila

RUN apt-get update \
  && apt-get install -y --no-install-recommends iptables \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/pgcopydb
COPY ./copydb.sh copydb.sh

USER docker
CMD ["bash", "/usr/src/pgcopydb/copydb.sh"]
