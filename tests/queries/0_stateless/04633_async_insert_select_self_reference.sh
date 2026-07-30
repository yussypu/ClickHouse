#!/usr/bin/env bash
# No tags needed: this only checks whether a table name shows up in asynchronous_insert_log, not
# thread counts or cluster topology, so it needs no no-parallel/no-object-storage exclusions.

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# A self referencing INSERT ... SELECT must not take the asynchronous insert queue route: the SELECT
# side's own lockForShare is captured into the pipeline's resources and would outlive the queue's
# flush wait, letting a concurrent exclusive lock request wedge the pair until it times out. This
# pins that a query which otherwise qualifies does not take the route once it reads its own
# destination, and that the same query against another source still does.
#
# Routing settings are pinned per query so the settings randomizer cannot turn a single block into
# several: max_threads and max_insert_threads to 1, max_block_size and preferred_block_size_bytes
# so a MergeTree read of a handful of rows arrives as one chunk (mirrors
# 04633_async_insert_select_queue_shape.sh's case 3 and cases 5/6).
#
# What a compiler or a CI run must still confirm: whether a single threaded MergeTree read of one
# small part is always exactly one chunk end to end (the same open question the sibling test's
# cases 5/6 note); and that async_insert_max_data_size's default is well above the few rows used
# here, so a route this guard allows actually reaches asynchronous_insert_log rather than being
# turned away by a size guard for an unrelated reason. Both are read from code, not from a run.

# Case 1: a self referencing INSERT ... SELECT must not reach the async queue, even though the
# shape (MergeTree destination, one small block, no views) would otherwise qualify.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_self"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_self (n UInt64) ENGINE = MergeTree ORDER BY n"
${CLICKHOUSE_CLIENT} -q "INSERT INTO test_04633_self VALUES (1), (2), (3)"
${CLICKHOUSE_CLIENT} -q "
    INSERT INTO test_04633_self SELECT n FROM test_04633_self
    SETTINGS async_insert = 1, wait_for_async_insert = 1,
             max_threads = 1, max_insert_threads = 1,
             max_block_size = 1000, preferred_block_size_bytes = 0
"
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM test_04633_self"
${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS asynchronous_insert_log"
${CLICKHOUSE_CLIENT} -q "
    SELECT count() = 0
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND database = currentDatabase()
      AND table = 'test_04633_self'
"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_self"

# Case 2: the identical query shape against a different source table is not self referencing, so
# it does take the async queue route. This is the positive control for case 1: it shows this
# shape would have reached the queue if not for the self reference.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_other_dst"
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_other_src"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_other_dst (n UInt64) ENGINE = MergeTree ORDER BY n"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_other_src (n UInt64) ENGINE = MergeTree ORDER BY n"
${CLICKHOUSE_CLIENT} -q "INSERT INTO test_04633_other_src VALUES (1), (2), (3)"
${CLICKHOUSE_CLIENT} -q "
    INSERT INTO test_04633_other_dst SELECT n FROM test_04633_other_src
    SETTINGS async_insert = 1, wait_for_async_insert = 1,
             max_threads = 1, max_insert_threads = 1,
             max_block_size = 1000, preferred_block_size_bytes = 0
"
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM test_04633_other_dst"
# The log element is queued for writing after the query returns, so one flush can miss it (see
# https://github.com/ClickHouse/ClickHouse/issues/84364). Flush and re-check until it lands; the
# loop is bounded so a real failure prints 0 instead of hanging until the test timeout.
reached_queue=0
for _ in $(seq 1 60); do
    ${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS asynchronous_insert_log"
    reached_queue=$(${CLICKHOUSE_CLIENT} -q "
        SELECT count() >= 1
        FROM system.asynchronous_insert_log
        WHERE event_date >= yesterday() AND event_time >= now() - 600
          AND database = currentDatabase()
          AND table = 'test_04633_other_dst'
    ")
    [ "$reached_queue" = 1 ] && break
    sleep 0.5
done
echo "$reached_queue"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_other_dst"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_other_src"
