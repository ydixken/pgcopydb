set pagination off
set confirm off
tbreak pgsql_replication_origin_xact_setup
run
set $apply = pgsql
if !pgsql_sync_pipeline($apply)
    echo FAIL: target DML did not complete\n
    quit 1
end
# PQTRANS_INTRANS = 2: the server has acknowledged an open transaction.
if (int) PQtransactionStatus($apply->connection) != 2
    echo FAIL: no target transaction to kill\n
    quit 1
end
echo Target DML confirmed inside transaction; killing before COMMIT\n
kill
quit 0
