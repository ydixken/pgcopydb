# that image is built by docker compose build: project-service
FROM multi

COPY --from=pgcopydb /usr/local/bin/pgcopydb /usr/local/bin

WORKDIR /usr/src/pgcopydb
COPY copydb.sh lo-resume.sh sysv-signals.sh ./

USER docker
CMD ["/usr/src/pgcopydb/copydb.sh"]
