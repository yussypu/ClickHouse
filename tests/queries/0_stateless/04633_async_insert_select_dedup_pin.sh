#!/usr/bin/env bash

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# Regression test for the InterpreterInsertQuery.cpp fix that pins the INSERT ... SELECT
# deduplication decision so the async insert queue route and the synchronous fallback route
# cannot disagree about whether to deduplicate the same query.
#
# Trace this reproduces: with deduplicate_insert = 'backward_compatible_choice', isDeduplicationEnabledForInsert()
# resolves through insert_deduplicate for a synchronous insert and through async_insert_deduplicate for an
# async one. deduplicate_insert_select = 'enable_even_for_bad_queries' deliberately keeps deduplicating even
# when the SELECT is not provably stable, and (unlike 'enable_when_possible') its computed value equals
# isDeduplicationEnabledForInsert(/*is_async_insert=*/false, settings) unconditionally, so with
# insert_deduplicate = 1 the two happen to agree (both true) while async_insert_deduplicate = 0 makes the
# async default disagree (false). Before the fix, only the "does the SELECT-computed decision differ from the
# synchronous default" guard existed, so this exact combination looked consistent and the decision was never
# pinned: the async queue route's flush thread rebuilds its own dependency graph with is_async_insert=true and
# resolves async_insert_deduplicate = false, silently skipping deduplication that the synchronous route (or
# the same query forced onto the multi-block fallback) would have applied. A retried single-block
# INSERT ... SELECT then duplicated its rows.
#
# `deduplicate_insert = 'backward_compatible_choice'` is set directly rather than via the `compatibility`
# setting: an old-enough `compatibility` value reaches the same value for this one setting (it is the
# pre-"26.2" default, see SettingsChangesHistory.cpp), but it also reverts on the order of a hundred unrelated
# settings from every release between the target version and master, none of which this test needs or has
# audited for interaction with this code path. Setting the enum value directly reaches the identical Settings
# state for the two settings this bug depends on, without that risk.
#
# Every other setting that participates in the routing/eligibility decision (async_insert, max_insert_threads,
# max_threads, insert_quorum, implicit_transaction, parallel_distributed_insert_select,
# optimize_trivial_insert_select) is pinned in the query's own SETTINGS clause too, so the settings randomizer
# cannot rewrite any of them into a shape that changes which route is taken.
SHARED_SETTINGS="async_insert = 1, wait_for_async_insert = 1, insert_deduplicate = 1, async_insert_deduplicate = 0, deduplicate_insert = 'backward_compatible_choice', deduplicate_insert_select = 'enable_even_for_bad_queries', max_insert_threads = 1, max_threads = 1, insert_quorum = 0, implicit_transaction = 0, parallel_distributed_insert_select = 0, optimize_trivial_insert_select = 0"

# --- Queue route: a single-block SELECT (10 rows, max_block_size large enough to keep them in one
# block) is eligible for the async insert queue transform and actually takes it.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_dedup_queue_route"
${CLICKHOUSE_CLIENT} -q "
    CREATE TABLE test_04633_dedup_queue_route (id UInt64, data String)
    ENGINE = MergeTree ORDER BY id
    SETTINGS non_replicated_deduplication_window = 1000
"
for _ in 1 2; do
${CLICKHOUSE_CLIENT} -q "
    INSERT INTO test_04633_dedup_queue_route
    SELECT number AS id, toString(number) AS data FROM numbers(10)
    SETTINGS ${SHARED_SETTINGS}, max_block_size = 1000000
"
done
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM test_04633_dedup_queue_route"
# Only that the route was taken matters here, not how many flush cycles the two inserts landed in.
# The log element is queued for writing after the query returns, so one flush can miss it (see
# https://github.com/ClickHouse/ClickHouse/issues/84364); flush and re-check until it lands.
reached_queue=0
for _ in $(seq 1 60); do
    ${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS asynchronous_insert_log"
    reached_queue=$(${CLICKHOUSE_CLIENT} -q "
        SELECT count() > 0
        FROM system.asynchronous_insert_log
        WHERE event_date >= yesterday()
          AND event_time >= now() - 600
          AND database = currentDatabase()
          AND table = 'test_04633_dedup_queue_route'
    ")
    [ "$reached_queue" = 1 ] && break
    sleep 0.5
done
echo "$reached_queue"

# --- Synchronous fallback route: the identical query and the identical settings, except
# max_block_size = 1 forces the SELECT into 10 single-row blocks, so the multi-block fallback
# path is taken instead of the queue. Eligibility for the queue route is decided upfront from
# static guards only (async_insert enabled, MergeTree destination, no transaction, no
# non-parallel quorum, ...), independent of how many blocks the SELECT ends up producing, so the
# same deduplication pin applies here too; only the runtime routing differs.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_dedup_sync_route"
${CLICKHOUSE_CLIENT} -q "
    CREATE TABLE test_04633_dedup_sync_route (id UInt64, data String)
    ENGINE = MergeTree ORDER BY id
    SETTINGS non_replicated_deduplication_window = 1000
"
for _ in 1 2; do
${CLICKHOUSE_CLIENT} -q "
    INSERT INTO test_04633_dedup_sync_route
    SELECT number AS id, toString(number) AS data FROM numbers(10)
    SETTINGS ${SHARED_SETTINGS}, max_block_size = 1
"
done
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM test_04633_dedup_sync_route"
${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS asynchronous_insert_log"
${CLICKHOUSE_CLIENT} -q "
    SELECT count()
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday()
      AND event_time >= now() - 600
      AND database = currentDatabase()
      AND table = 'test_04633_dedup_sync_route'
"

# The two routes must agree on the deduplication decision for the same query and the same
# settings: retrying a duplicate INSERT ... SELECT must leave the same row count on both,
# regardless of which route actually ran it. If the pin in InterpreterInsertQuery.cpp regresses,
# this becomes 20 vs 10 and the equality check below returns 0.
${CLICKHOUSE_CLIENT} -q "
    SELECT (SELECT count() FROM test_04633_dedup_queue_route) = (SELECT count() FROM test_04633_dedup_sync_route)
"

${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_dedup_queue_route"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_dedup_sync_route"
