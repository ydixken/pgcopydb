#! /bin/bash
set -eu

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
normalizer=$(dirname "$0")/normalize.sql

normalize() {
    sqlite3 -init /dev/null -json :memory: \
        -cmd ".parameter set @input '$1'" < "$normalizer"
}

cat > "$work/input.json" <<'JSON'
[{"action":"B","message":"{\"action\":\"B\",\"xid\":91}"},
 {"action":"I","message":"{\"action\":\"I\",\"value\":9007199254740993,\"float8\":14.949999999999999}"},
 {"action":"C","message":"{\"action\":\"C\",\"xid\":91}"},
 {"action":"B","message":"{\"action\":\"B\",\"xid\":7}"},
 {"action":"I","message":"{\"action\":\"I\",\"xid\":7,\"value\":42,\"float8\":14.949999999999999,\"bigint\":9007199254740993}"},
 {"action":"C","message":"{\"action\":\"C\",\"xid\":7}"},
 {"action":"B","message":"{\"action\":\"B\",\"xid\":91}"},
 {"action":"C","message":"{\"action\":\"C\",\"xid\":91}"}]
JSON

normalize "$work/input.json" > "$work/expected.json"
jq -e '[.[].message | fromjson | .xid] == [1,null,1,2,2,2,1,1]' "$work/expected.json"
jq -e '.[1].message == "{\"action\":\"I\",\"value\":9007199254740993,\"float8\":14.949999999999999}"' "$work/expected.json"
jq -e '.[4].message == "{\"action\":\"I\",\"xid\":2,\"value\":42,\"float8\":14.949999999999999,\"bigint\":9007199254740993}"' "$work/expected.json"

jq 'map(.message |= (sub("\"xid\":91"; "\"xid\":3") | sub("\"xid\":7"; "\"xid\":200")))' \
    "$work/input.json" > "$work/renamed.json"
normalize "$work/renamed.json" > "$work/actual.json"
diff "$work/expected.json" "$work/actual.json"

for mutation in \
    '.[2].message |= sub("\"xid\":91"; "\"xid\":7")' \
    'map(.message |= sub("\"xid\":7"; "\"xid\":91"))' \
    '.[4].message |= sub("42"; "43")' \
    'reverse'; do
    jq "$mutation" "$work/input.json" > "$work/changed.json"
    normalize "$work/changed.json" > "$work/actual.json"
    if cmp -s "$work/expected.json" "$work/actual.json"; then
        echo "Normalization hid a change: $mutation" >&2
        exit 1
    fi
done

printf '[]\n' > "$work/empty.json"
touch "$work/blank.json"
for input in empty blank missing; do
    if normalize "$work/$input.json" > /dev/null 2>&1; then
        echo "Normalization accepted $input input" >&2
        exit 1
    fi
done
echo 'PASS: XID identity, first-seen order, absent XIDs, content, precision, and empty input'
