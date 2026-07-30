#!/usr/bin/env bash
# Tags: no-object-storage, no-parallel, no-fasttest
# no-object-storage: object storage adds extra threads, throwing off the peak_threads_usage check
# no-parallel: peak_threads_usage can be lowered by other concurrently running queries

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# Coverage for the additive queue transform in InterpreterInsertQuery::addInsertToSelectPipeline:
# which result shapes reach the async queue and which pass through to the normal pipeline.
# Settings that decide a shape are passed per query, not per session, so the test settings
# randomizer cannot rewrite them. This includes every setting that governs how many chunks a
# SELECT (or a JOIN feeding it) hands to the transform, not only the ones that look size related:
# max_threads, max_insert_threads, max_block_size, max_joined_block_size_rows,
# joined_block_split_single_row, join_output_by_rowlist_perkey_rows_threshold,
# query_plan_join_swap_table and enable_lazy_columns_replication are all in
# tests/clickhouse-test's SettingsRandomizer, and any one of them turning a single-block result
# into two chunks, or a lazily replicated column into an eagerly materialized one, changes what a
# case here is actually exercising.

# Case 1: a bulk INSERT ... SELECT under async_insert=1 keeps the normal, parallel pipeline.
# The destination has no dependent view, so the transform is added and the second block is what
# makes it pass through. Before this change the fallback reused a dependency graph built with
# max_insert_threads hardcoded to 1, which serialized the insert regardless of the setting.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_bulk_dst"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_bulk_dst (n UInt64) ENGINE = MergeTree ORDER BY n"

QUERY_ID="test_04633_bulk_$RANDOM"
${CLICKHOUSE_CLIENT} --query_id="$QUERY_ID" -q "
    INSERT INTO test_04633_bulk_dst SELECT number FROM numbers_mt(200000)
    SETTINGS async_insert = 1, wait_for_async_insert = 1,
             max_threads = 8, max_insert_threads = 8, max_block_size = 10000
"
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM test_04633_bulk_dst"

${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS query_log, asynchronous_insert_log"
${CLICKHOUSE_CLIENT} -q "
    SELECT if(peak_threads_usage >= 2, 'parallel', 'serial')
    FROM system.query_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND current_database = currentDatabase()
      AND type = 'QueryFinish'
      AND query_id = '$QUERY_ID'
"
${CLICKHOUSE_CLIENT} -q "
    SELECT count()
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND database = currentDatabase()
      AND table = 'test_04633_bulk_dst'
"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_bulk_dst"

# Case 2: a destination with a dependent materialized view never reaches the queue, whatever the
# result shape, because a view target can be any engine. parallel_view_processing still applies.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_mv_dst"
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_mv_target"
${CLICKHOUSE_CLIENT} -q "DROP VIEW IF EXISTS test_04633_mv"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_mv_dst (n UInt64) ENGINE = MergeTree ORDER BY n"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_mv_target (n UInt64) ENGINE = MergeTree ORDER BY n"
${CLICKHOUSE_CLIENT} -q "
    CREATE MATERIALIZED VIEW test_04633_mv TO test_04633_mv_target AS
    SELECT n FROM test_04633_mv_dst
"
${CLICKHOUSE_CLIENT} -q "
    INSERT INTO test_04633_mv_dst SELECT number FROM numbers(3)
    SETTINGS async_insert = 1, wait_for_async_insert = 1, parallel_view_processing = 1
"
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM test_04633_mv_dst"
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM test_04633_mv_target"
${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS asynchronous_insert_log"
${CLICKHOUSE_CLIENT} -q "
    SELECT count()
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND database = currentDatabase()
      AND table = 'test_04633_mv_dst'
"
${CLICKHOUSE_CLIENT} -q "DROP VIEW test_04633_mv"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_mv_target"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_mv_dst"

# Case 3: a single small block goes through the async queue and the rows land.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_single"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_single (n UInt64) ENGINE = MergeTree ORDER BY n"
${CLICKHOUSE_CLIENT} -q "
    INSERT INTO test_04633_single SELECT number FROM numbers(3)
    SETTINGS async_insert = 1, wait_for_async_insert = 1,
             max_threads = 1, max_insert_threads = 1
"
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM test_04633_single"
# The log element is queued for writing after the query returns, so one flush can miss it (see
# https://github.com/ClickHouse/ClickHouse/issues/84364); flush and re-check until it lands. The
# other cases below assert an absent row, which nothing can wait for, so they flush once.
reached_queue=0
for _ in $(seq 1 60); do
    ${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS asynchronous_insert_log"
    reached_queue=$(${CLICKHOUSE_CLIENT} -q "
        SELECT count() >= 1
        FROM system.asynchronous_insert_log
        WHERE event_date >= yesterday() AND event_time >= now() - 600
          AND database = currentDatabase()
          AND table = 'test_04633_single'
    ")
    [ "$reached_queue" = 1 ] && break
    sleep 0.5
done
echo "$reached_queue"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_single"

# Case 4: a zero-row SELECT pushes nothing to the queue and creates no part.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_empty"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_empty (n UInt64) ENGINE = MergeTree ORDER BY n"
${CLICKHOUSE_CLIENT} -q "
    INSERT INTO test_04633_empty SELECT number FROM numbers(0)
    SETTINGS async_insert = 1, wait_for_async_insert = 1
"
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM test_04633_empty"
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM system.parts WHERE database = currentDatabase() AND table = 'test_04633_empty' AND active"
${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS asynchronous_insert_log"
${CLICKHOUSE_CLIENT} -q "
    SELECT count()
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND database = currentDatabase()
      AND table = 'test_04633_empty'
"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_empty"

# Cases 5 and 6: the const branch's old formula (byteSize() + byteSizeAt(0) * rows) double-counted a
# single large constant value, so the old cases 5/6 pinned that double count as "expected"; that
# defect is fixed now (estimateMaterializedBytes returns byteSizeAt(0) * rows for a const column,
# with no second wrapper term), so those cases would fail as written and are rebuilt here on a shape
# the estimator actually exists to catch: a sparse column read back from a table.
#
# A column whose values are overwhelmingly the type's default gets Sparse serialization on disk once
# the fraction of default values exceeds ratio_of_defaults_for_sparse_serialization (a MergeTree
# table setting; DataTypes/Serializations/SerializationInfo.cpp's chooseKindStack picks Sparse from
# it, confirmed observable below via system.parts_columns.serialization_kind). On read,
# SerializationSparse::deserializeBinaryBulkWithMultipleStreams (src/DataTypes/Serializations/
# SerializationSparse.cpp) builds a ColumnSparse, not a full column. A plain `INSERT INTO dest SELECT
# col FROM src` with matching source/destination types needs no cast: ActionsDAG::makeConvertingActions
# (src/Interpreters/ActionsDAG.cpp) reuses the same node when types already match, so no function call
# expands the column before AsyncInsertQueueTransform sees it; nothing between the MergeTree read and
# the transform (RemovingSparseTransform is only added for a destination that does not support sparse
# serialization, and this destination does: MergeTreeData::supportsSparseSerialization) removes it
# either. So the transform's pre-materialization estimate sees a real ColumnSparse here, with its own
# A sparse column read back from a table is the shape the estimator's sparse branch exists for:
# byteSize() stays tiny (a handful of non-default values) while the materialized block grows with the
# row count. The kept formula and the true size differ by a fixed 32 bytes regardless of the row
# count, so async_insert_max_data_size is set inside that gap: the correct estimate rejects, while a
# flat byteSize() estimate, blind to the row count, would admit the chunk to the queue.
#
# Shape-deciding settings are pinned per query (max_threads, max_insert_threads, max_block_size,
# preferred_block_size_bytes) and the row count stays below merge_tree_min_rows_for_concurrent_read
# (163840), so the read arrives as one chunk. That single-chunk assumption is unverified: nothing was
# executed to confirm it.

# Case 5: a sparse UInt64 column (fixed-width values, ColumnVector), read back and re-inserted.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_sparse_num_src"
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_sparse_num_dest"
${CLICKHOUSE_CLIENT} -q "
    CREATE TABLE test_04633_sparse_num_src (n UInt64) ENGINE = MergeTree ORDER BY tuple()
    SETTINGS ratio_of_defaults_for_sparse_serialization = 0.9
"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_sparse_num_dest (n UInt64) ENGINE = MergeTree ORDER BY tuple()"
${CLICKHOUSE_CLIENT} -q "
    INSERT INTO test_04633_sparse_num_src SELECT if(number = 25000, 123, 0) FROM numbers(50000)
    SETTINGS max_threads = 1, max_insert_threads = 1
"
${CLICKHOUSE_CLIENT} -q "
    SELECT serialization_kind FROM system.parts_columns
    WHERE database = currentDatabase() AND table = 'test_04633_sparse_num_src' AND column = 'n' AND active
"
${CLICKHOUSE_CLIENT} -q "
    SELECT count() FROM system.parts
    WHERE database = currentDatabase() AND table = 'test_04633_sparse_num_src' AND active
"
${CLICKHOUSE_CLIENT} -q "
    INSERT INTO test_04633_sparse_num_dest SELECT n FROM test_04633_sparse_num_src
    SETTINGS async_insert = 1, wait_for_async_insert = 1,
             async_insert_max_data_size = 400016,
             max_threads = 1, max_insert_threads = 1,
             max_block_size = 100000, preferred_block_size_bytes = 0
"
${CLICKHOUSE_CLIENT} -q "SELECT count(), sum(n) FROM test_04633_sparse_num_dest"
${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS asynchronous_insert_log"
${CLICKHOUSE_CLIENT} -q "
    SELECT count()
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND database = currentDatabase()
      AND table = 'test_04633_sparse_num_dest'
"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_sparse_num_src"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_sparse_num_dest"

# Case 6: the same shape as case 5, but a sparse String column (variable-width values, ColumnString),
# so the estimate also exercises ColumnString's own byteSize/byteSizeAt rather than ColumnVector's.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_sparse_str_src"
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_sparse_str_dest"
${CLICKHOUSE_CLIENT} -q "
    CREATE TABLE test_04633_sparse_str_src (s String) ENGINE = MergeTree ORDER BY tuple()
    SETTINGS ratio_of_defaults_for_sparse_serialization = 0.9
"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_sparse_str_dest (s String) ENGINE = MergeTree ORDER BY tuple()"
${CLICKHOUSE_CLIENT} -q "
    INSERT INTO test_04633_sparse_str_src SELECT if(number = 30000, repeat('a', 64), '') FROM numbers(50000)
    SETTINGS max_threads = 1, max_insert_threads = 1
"
${CLICKHOUSE_CLIENT} -q "
    SELECT serialization_kind FROM system.parts_columns
    WHERE database = currentDatabase() AND table = 'test_04633_sparse_str_src' AND column = 's' AND active
"
${CLICKHOUSE_CLIENT} -q "
    SELECT count() FROM system.parts
    WHERE database = currentDatabase() AND table = 'test_04633_sparse_str_src' AND active
"
${CLICKHOUSE_CLIENT} -q "
    INSERT INTO test_04633_sparse_str_dest SELECT s FROM test_04633_sparse_str_src
    SETTINGS async_insert = 1, wait_for_async_insert = 1,
             async_insert_max_data_size = 400080,
             max_threads = 1, max_insert_threads = 1,
             max_block_size = 100000, preferred_block_size_bytes = 0
"
${CLICKHOUSE_CLIENT} -q "SELECT count(), max(length(s)) FROM test_04633_sparse_str_dest"
${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS asynchronous_insert_log"
${CLICKHOUSE_CLIENT} -q "
    SELECT count()
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND database = currentDatabase()
      AND table = 'test_04633_sparse_str_dest'
"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_sparse_str_src"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_sparse_str_dest"

# Case 7: a large-margin check only. A JOIN cannot deliver a lazy ColumnReplicated here, because
# JoinCommon::materializeColumnsFromRightBlock materializes right-side columns first, so this case
# cannot discriminate between estimates. 10000 rows of a 1 KiB value must stay out of the queue and
# land through the fallback.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_join"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_join (s String) ENGINE = MergeTree ORDER BY tuple()"
${CLICKHOUSE_CLIENT} -q "
    INSERT INTO test_04633_join
    SELECT r.s FROM numbers(10000) AS l
    JOIN (SELECT 0 AS k, repeat('z', 1024) AS s) AS r ON l.number % 1 = r.k
    SETTINGS async_insert = 1, wait_for_async_insert = 1,
             async_insert_max_data_size = 100000, max_block_size = 100000,
             max_threads = 1, max_insert_threads = 1,
             max_joined_block_size_rows = 100000,
             joined_block_split_single_row = 0,
             join_output_by_rowlist_perkey_rows_threshold = 1000000,
             query_plan_join_swap_table = 'false',
             enable_lazy_columns_replication = 1
"
${CLICKHOUSE_CLIENT} -q "SELECT count(), any(length(s)) FROM test_04633_join"
${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS asynchronous_insert_log"
${CLICKHOUSE_CLIENT} -q "
    SELECT count()
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND database = currentDatabase()
      AND table = 'test_04633_join'
"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_join"

# Case 8: a skewed lazy replication. ARRAY JOIN references one 32 KiB row 64 times and 3000 tiny rows
# once, so an average-based estimate sees ~60 KB while the materialized block is above 2 MB. Both
# checks reject it, so only the logged reason shows the block was not expanded first.
# `repeat`/`range` lengths come from the row: a constant inside `if` is expanded for every row.
# preferred_block_size_bytes is pinned so the 32 KiB value does not split the result into chunks.
${CLICKHOUSE_CLIENT} -q "DROP TABLE IF EXISTS test_04633_skewed"
${CLICKHOUSE_CLIENT} -q "CREATE TABLE test_04633_skewed (s String) ENGINE = MergeTree ORDER BY tuple()"
CLICKHOUSE_CLIENT_DEBUG_LOGS=$(echo "${CLICKHOUSE_CLIENT}" | sed "s/--send_logs_level=${CLICKHOUSE_CLIENT_SERVER_LOGS_LEVEL}/--send_logs_level=debug/")
${CLICKHOUSE_CLIENT_DEBUG_LOGS} -q "
    INSERT INTO test_04633_skewed
    SELECT s FROM
    (
        SELECT
            repeat('x', if(number = 0, 32768, 1)) AS s,
            range(if(number = 0, 64, 1)) AS arr
        FROM numbers(3001)
    ) ARRAY JOIN arr
    SETTINGS async_insert = 1, wait_for_async_insert = 1,
             async_insert_max_data_size = 500000, max_block_size = 100000,
             preferred_block_size_bytes = 0, preferred_max_column_in_block_size_bytes = 0,
             max_threads = 1, max_insert_threads = 1,
             enable_lazy_columns_replication = 1
" 2>&1 >/dev/null | grep -oE "reason: (estimated|materialized) block size|reason: the result is not a single block" | head -1
${CLICKHOUSE_CLIENT} -q "SELECT count(), sum(length(s)) FROM test_04633_skewed"
${CLICKHOUSE_CLIENT} -q "SYSTEM FLUSH LOGS asynchronous_insert_log"
${CLICKHOUSE_CLIENT} -q "
    SELECT count()
    FROM system.asynchronous_insert_log
    WHERE event_date >= yesterday() AND event_time >= now() - 600
      AND database = currentDatabase()
      AND table = 'test_04633_skewed'
"
${CLICKHOUSE_CLIENT} -q "DROP TABLE test_04633_skewed"
