#!/usr/bin/env bash
# No tags needed: every case here checks accounting numbers of its own queries, by query id and by
# quota name, so a concurrent test cannot shift them.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# Write-side accounting of the async insert queue route of INSERT ... SELECT
# (InterpreterInsertQuery::addInsertToSelectPipeline plus AsyncInsertQueueTransform).
#
# The block diverted to the queue is written by the flush, not by this query's own pipeline, so it
# must be counted exactly once, by the flush, and only after the flush succeeded. The queue
# transform sits upstream of the query's `CountingTransform` for that reason: counting the diverted
# block here as well would double the write in `system.query_log`, in `X-ClickHouse-Summary` and in
# the `WRITTEN_BYTES` quota, and would charge a write that a failing flush never performed.
#
# Every case pins the shape-deciding settings per query (max_threads, max_insert_threads), because
# tests/clickhouse-test's SettingsRandomizer can otherwise split a small result into two chunks,
# which takes the synchronous route and makes the case check nothing.

# A system log element is queued for writing after the query returns to the client, so a single
# SYSTEM FLUSH LOGS right after the query can flush a log that does not hold the element yet (see
# https://github.com/ClickHouse/ClickHouse/issues/84364). Flush and re-check until the expected
# rows are there. The loop is bounded so a real failure prints a diff instead of running into the
# test timeout. The count reached is published in `LOG_ROW_COUNT`, so a case whose assertion is the
# count itself prints that instead of repeating the query.
wait_for_log_rows()
{
    local log_table=$1 && shift
    local expected=$1 && shift
    local count_query=$1 && shift

    LOG_ROW_COUNT=0
    for _ in $(seq 1 60); do
        ${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS ${log_table}"
        LOG_ROW_COUNT=$(${CLICKHOUSE_CLIENT} -q "${count_query}")
        [ "$LOG_ROW_COUNT" -ge "$expected" ] && return
        sleep 0.5
    done
    echo "timed out waiting for ${expected} rows in system.${log_table}, got ${LOG_ROW_COUNT}"
}

# Case 1: the routed insert and the same insert on the synchronous route report the same write.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_acc"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_acc (n UInt64) ENGINE = MergeTree ORDER BY n"

QUEUED_ID="test_04633_queued_$RANDOM"
SYNC_ID="test_04633_sync_$RANDOM"
${CLICKHOUSE_CLIENT} --query_id="$QUEUED_ID" -q "
    INSERT INTO test_04633_acc SELECT number FROM numbers(3)
    SETTINGS async_insert = 1, wait_for_async_insert = 1, max_threads = 1, max_insert_threads = 1
"
${CLICKHOUSE_CLIENT} --query_id="$SYNC_ID" -q "
    INSERT INTO test_04633_acc SELECT number FROM numbers(3)
    SETTINGS async_insert = 0, max_threads = 1, max_insert_threads = 1
"
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM test_04633_acc"

# Only the first insert reached the queue, so the numbers below really do compare the two routes.
wait_for_log_rows asynchronous_insert_log 1 "
    SELECT count()
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND database = currentDatabase() AND table = 'test_04633_acc'
"
echo "$LOG_ROW_COUNT"
wait_for_log_rows query_log 2 "
    SELECT count()
    FROM system.query_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND current_database = currentDatabase() AND type = 'QueryFinish'
      AND query_id IN ('$QUEUED_ID', '$SYNC_ID')
"
# written_rows must be 3, not 6, on both routes, and the two routes must report the same bytes.
${CLICKHOUSE_CLIENT} -q "
    SELECT
        anyIf(written_rows, query_id = '$QUEUED_ID'),
        anyIf(written_rows, query_id = '$SYNC_ID'),
        anyIf(written_bytes, query_id = '$QUEUED_ID') = anyIf(written_bytes, query_id = '$SYNC_ID')
    FROM system.query_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND current_database = currentDatabase() AND type = 'QueryFinish'
      AND query_id IN ('$QUEUED_ID', '$SYNC_ID')
"
# The write-side ProfileEvents of the routed insert belong to the flush query, so this query has none.
${CLICKHOUSE_CLIENT} -q "
    SELECT
        anyIf(ProfileEvents['InsertedRows'], query_id = '$QUEUED_ID'),
        anyIf(ProfileEvents['InsertedRows'], query_id = '$SYNC_ID')
    FROM system.query_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND current_database = currentDatabase() AND type = 'QueryFinish'
      AND query_id IN ('$QUEUED_ID', '$SYNC_ID')
"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_acc"

# Case 2: the same numbers as seen by an HTTP client in X-ClickHouse-Summary.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_summary"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_summary (n UInt64) ENGINE = MergeTree ORDER BY n"
${CLICKHOUSE_CURL} -sS -v "${CLICKHOUSE_URL}&http_wait_end_of_query=1&async_insert=1&wait_for_async_insert=1&max_threads=1&max_insert_threads=1" \
    -d "INSERT INTO test_04633_summary SELECT number FROM numbers(3)" 2>&1 \
    | grep -o '"written_rows":"[0-9]*","written_bytes":"[0-9]*"'
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM test_04633_summary"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_summary"

# Case 3: a flush that fails must report no write at all. The constraint is checked by the flush's
# own sink chain, so the exception travels back through the future, after the block was queued.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_failing"
${CLICKHOUSE_CLIENT} -q "
    CREATE TABLE test_04633_failing (n UInt64, CONSTRAINT c_small CHECK n < 100)
    ENGINE = MergeTree ORDER BY n
"
FAILED_ID="test_04633_failed_$RANDOM"
${CLICKHOUSE_CLIENT} --query_id="$FAILED_ID" -q "
    INSERT INTO test_04633_failing SELECT 1000 + number FROM numbers(3)
    SETTINGS async_insert = 1, wait_for_async_insert = 1, max_threads = 1, max_insert_threads = 1
" 2>&1 | grep -m1 -o VIOLATED_CONSTRAINT
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM test_04633_failing"

wait_for_log_rows asynchronous_insert_log 1 "
    SELECT count()
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND database = currentDatabase() AND table = 'test_04633_failing'
"
wait_for_log_rows query_log 1 "
    SELECT count()
    FROM system.query_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND current_database = currentDatabase() AND type = 'ExceptionWhileProcessing'
      AND query_id = '$FAILED_ID'
"
${CLICKHOUSE_CLIENT} -q "
    SELECT status
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND database = currentDatabase() AND table = 'test_04633_failing'
"
${CLICKHOUSE_CLIENT} -q "
    SELECT written_rows, written_bytes
    FROM system.query_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND current_database = currentDatabase() AND type = 'ExceptionWhileProcessing'
      AND query_id = '$FAILED_ID'
"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_failing"

# Case 4: the WRITTEN_BYTES quota is charged once per route, by the flush on the queue route.
ROLE="r_${CLICKHOUSE_TEST_UNIQUE_NAME}"
USER="u_${CLICKHOUSE_TEST_UNIQUE_NAME}"
QUOTA="q_${CLICKHOUSE_TEST_UNIQUE_NAME}"

${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_quota"
${CLICKHOUSE_CLIENT} -q "DROP ROLE IF EXISTS ${ROLE}"
${CLICKHOUSE_CLIENT} -q "DROP USER IF EXISTS ${USER}"
${CLICKHOUSE_CLIENT} -q "DROP QUOTA IF EXISTS ${QUOTA}"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_quota (n UInt64) ENGINE = MergeTree ORDER BY n"
${CLICKHOUSE_CLIENT} -q "CREATE ROLE ${ROLE}"
${CLICKHOUSE_CLIENT} -q "CREATE USER ${USER}"
${CLICKHOUSE_CLIENT} -q "GRANT ALL ON *.* TO ${ROLE}"
${CLICKHOUSE_CLIENT} -q "GRANT ${ROLE} TO ${USER}"
${CLICKHOUSE_CLIENT} -q "CREATE QUOTA ${QUOTA} FOR INTERVAL 100 YEAR MAX WRITTEN BYTES = 1000000 TO ${ROLE}"

${CLICKHOUSE_CLIENT} --user "${USER}" -q "
    INSERT INTO ${CLICKHOUSE_DATABASE}.test_04633_quota SELECT number FROM numbers(3)
    SETTINGS async_insert = 1, wait_for_async_insert = 1, max_threads = 1, max_insert_threads = 1
"
QUEUED_BYTES=$(${CLICKHOUSE_CLIENT} -q "SELECT sum(written_bytes) FROM system.quotas_usage WHERE quota_name = '${QUOTA}'")
${CLICKHOUSE_CLIENT} --user "${USER}" -q "
    INSERT INTO ${CLICKHOUSE_DATABASE}.test_04633_quota SELECT number FROM numbers(3)
    SETTINGS async_insert = 0, max_threads = 1, max_insert_threads = 1
"
TOTAL_BYTES=$(${CLICKHOUSE_CLIENT} -q "SELECT sum(written_bytes) FROM system.quotas_usage WHERE quota_name = '${QUOTA}'")

wait_for_log_rows asynchronous_insert_log 1 "
    SELECT count()
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND database = currentDatabase() AND table = 'test_04633_quota'
"
echo "$LOG_ROW_COUNT"
# The routed insert charged something, and it charged exactly as much as the synchronous one.
if [[ "$QUEUED_BYTES" -gt 0 && $((TOTAL_BYTES - QUEUED_BYTES)) -eq "$QUEUED_BYTES" ]]; then
    echo "quota charged once per route"
else
    echo "quota mismatch: queued=$QUEUED_BYTES total=$TOTAL_BYTES"
fi

${CLICKHOUSE_CLIENT} -q "DROP QUOTA ${QUOTA}"
${CLICKHOUSE_CLIENT} -q "DROP USER ${USER}"
${CLICKHOUSE_CLIENT} -q "DROP ROLE ${ROLE}"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_quota"

# Case 5: max_execution_time with timeout_overflow_mode = 'break' must not cut short the wait for the
# flush. The busy timeout is pinned well above max_execution_time (and the adaptive algorithm is off,
# so it stays there), so the limit certainly elapses while the query is still waiting. Breaking out
# there would report a successful INSERT for a flush that had not been attempted yet, so the query
# keeps waiting and returns only after the busy timeout.
#
# What the flush then does with the same deadline is deliberately not asserted. The flush is a
# separate query that inherits max_execution_time with a fresh stopwatch, and under 'break' a flush
# that outruns it stops without committing while still reporting success. That is the documented
# behaviour of 'break', so the row count here depends on how fast the flush is, and pinning it would
# only make this test fail on a loaded machine.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_break"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_break (n UInt64) ENGINE = MergeTree ORDER BY n"
BREAK_ID="test_04633_break_$RANDOM"
${CLICKHOUSE_CLIENT} --query_id="$BREAK_ID" -q "
    INSERT INTO test_04633_break SELECT number FROM numbers(3)
    SETTINGS async_insert = 1, wait_for_async_insert = 1,
             async_insert_use_adaptive_busy_timeout = 0,
             async_insert_busy_timeout_min_ms = 2000, async_insert_busy_timeout_max_ms = 2000,
             max_execution_time = 1, timeout_overflow_mode = 'break',
             max_threads = 1, max_insert_threads = 1
"
wait_for_log_rows query_log 1 "
    SELECT count()
    FROM system.query_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND current_database = currentDatabase() AND type = 'QueryFinish'
      AND query_id = '$BREAK_ID'
"
# The query's own duration, as the server recorded it. Only a lower bound, so a slow machine can
# never make this fail: breaking out on the 1000 ms limit ends the query at about that point, while
# waiting for the flush cannot end it before the 2000 ms busy timeout.
${CLICKHOUSE_CLIENT} -q "
    SELECT if(query_duration_ms >= 1500,
              'waited for the flush',
              concat('returned early after ', toString(query_duration_ms), ' ms'))
    FROM system.query_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND current_database = currentDatabase() AND type = 'QueryFinish'
      AND query_id = '$BREAK_ID'
"

wait_for_log_rows asynchronous_insert_log 1 "
    SELECT count()
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND database = currentDatabase() AND table = 'test_04633_break'
"
echo "$LOG_ROW_COUNT"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_break"
