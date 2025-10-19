# DELETE Operation Support in CDC Pipeline

This document explains how DELETE operations are handled in the production CDC platform after migrating to ReplacingMergeTree.

## 🎯 Overview

The CDC platform now fully supports DELETE operations from MySQL, replicating them to ClickHouse using the **ReplacingMergeTree** engine with soft delete pattern.

### What Changed

| Before Migration | After Migration |
|-----------------|-----------------|
| MergeTree engine | ReplacingMergeTree engine |
| DELETE operations filtered out | DELETE operations replicated |
| No `is_deleted` column | Soft delete with `is_deleted` flag |
| No active data views | Auto-filtering active views |

## 🏗️ Architecture

### ReplacingMergeTree Pattern

```sql
ENGINE = ReplacingMergeTree(cdc_timestamp)
ORDER BY (primary_key)
```

- **Version Column**: `cdc_timestamp` - ClickHouse uses the latest timestamp to determine current version
- **Soft Delete**: `is_deleted = 1` marks deleted records
- **FINAL Modifier**: Deduplicates rows and returns the latest version

### Materialized Views

The materialized views now handle all CDC operations:

```sql
CREATE MATERIALIZED VIEW title_ratings_cdc_mv TO title_ratings AS
SELECT
    -- For DELETE ops, use 'before', otherwise use 'after'
    if(op = 'd', JSONExtractString(message, 'before', 'tconst'),
                 JSONExtractString(message, 'after', 'tconst')) as tconst,
    if(op = 'd', 0, JSONExtractFloat(message, 'after', 'averageRating')) as averageRating,
    if(op = 'd', 0, JSONExtractUInt(message, 'after', 'numVotes')) as numVotes,
    op as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp,
    if(op = 'd', 1, 0) as is_deleted -- Mark as deleted
FROM (
    SELECT message, JSONExtractString(message, 'op') as op
    FROM title_ratings_kafka
)
WHERE op IN ('c', 'u', 'r', 'd');  -- Now includes 'd' for DELETE
```

## 📊 Usage Examples

### 1. Query All Data (Including Deleted)

Use `FINAL` to get deduplicated data with latest versions:

```sql
SELECT tconst, averageRating, is_deleted, cdc_operation, cdc_timestamp
FROM imdb.title_ratings FINAL
ORDER BY cdc_timestamp DESC;
```

### 2. Query Only Active (Non-Deleted) Data

Use the `*_active` views for automatic filtering:

```sql
SELECT tconst, averageRating
FROM imdb.title_ratings_active;
```

Equivalent to:
```sql
SELECT tconst, averageRating
FROM imdb.title_ratings FINAL
WHERE is_deleted = 0;
```

### 3. Query Deleted Records Only

```sql
SELECT tconst, averageRating, cdc_timestamp
FROM imdb.title_ratings FINAL
WHERE is_deleted = 1
ORDER BY cdc_timestamp DESC;
```

### 4. Audit Trail - See All CDC Operations

```sql
SELECT
    tconst,
    cdc_operation,
    CASE
        WHEN cdc_operation = 'c' THEN 'Create'
        WHEN cdc_operation = 'u' THEN 'Update'
        WHEN cdc_operation = 'r' THEN 'Read (snapshot)'
        WHEN cdc_operation = 'd' THEN 'Delete'
    END as operation_type,
    is_deleted,
    cdc_timestamp
FROM imdb.title_ratings FINAL
ORDER BY cdc_timestamp DESC
LIMIT 100;
```

### 5. Track Record Lifecycle

```sql
-- See all versions of a specific record
SELECT
    tconst,
    averageRating,
    cdc_operation,
    is_deleted,
    cdc_timestamp,
    processing_time
FROM imdb.title_ratings
WHERE tconst = 'tt0000001'
ORDER BY cdc_timestamp;
```

## 🔄 CDC Operation Flow

### INSERT Operation
```
MySQL: INSERT INTO title_ratings VALUES ('tt0000001', 8.5, 100)
   ↓
Debezium: {"op": "c", "after": {"tconst": "tt0000001", "averageRating": 8.5, ...}}
   ↓
ClickHouse: tconst='tt0000001', cdc_operation='c', is_deleted=0
```

### UPDATE Operation
```
MySQL: UPDATE title_ratings SET averageRating = 9.0 WHERE tconst = 'tt0000001'
   ↓
Debezium: {"op": "u", "after": {"tconst": "tt0000001", "averageRating": 9.0, ...}}
   ↓
ClickHouse: New version with cdc_operation='u', is_deleted=0, latest cdc_timestamp
```

### DELETE Operation
```
MySQL: DELETE FROM title_ratings WHERE tconst = 'tt0000001'
   ↓
Debezium: {"op": "d", "before": {"tconst": "tt0000001", ...}, "after": null}
   ↓
ClickHouse: New version with cdc_operation='d', is_deleted=1, latest cdc_timestamp
```

**Key Point**: DELETE uses `before` data since `after` is null in Debezium delete events.

## 🎯 Active Data Views

All tables have corresponding active views that filter deleted records:

- `title_ratings_active`
- `title_basics_active`
- `name_basics_active`
- `title_crew_active`
- `title_episode_active`
- `title_akas_active`
- `title_principals_active`

### Benefits of Active Views

1. **Automatic Filtering**: No need to remember `WHERE is_deleted = 0`
2. **Performance**: ClickHouse optimizes view queries
3. **Backward Compatibility**: Applications can use views without code changes
4. **Clean Syntax**: `SELECT * FROM table_active` vs `SELECT * FROM table FINAL WHERE is_deleted = 0`

## ⚡ Performance Considerations

### The FINAL Modifier

`FINAL` triggers deduplication and merges:
- ✅ **Use FINAL when**: You need the latest version of each record
- ⚠️ **Avoid FINAL when**: Doing large aggregations on multi-million row tables

### Optimization Tips

1. **Use Active Views for Analytics**:
   ```sql
   -- Good: Let the view handle filtering
   SELECT COUNT(*) FROM imdb.title_ratings_active;

   -- Avoid: Manual filtering with FINAL on every query
   SELECT COUNT(*) FROM imdb.title_ratings FINAL WHERE is_deleted = 0;
   ```

2. **Partition by CDC Timestamp**:
   - Tables are partitioned by month: `PARTITION BY toYYYYMM(cdc_timestamp)`
   - Queries with date filters are faster
   - Old partitions can be archived

3. **Background Merges**:
   - ClickHouse automatically merges parts in the background
   - ReplacingMergeTree deduplicates during merges
   - `FINAL` forces immediate deduplication

## 🧪 Testing DELETE Operations

Run the comprehensive test suite:

```bash
./test-cdc.sh
```

The test verifies:
1. ✅ DELETE operations replicate from MySQL
2. ✅ `is_deleted` flag is set correctly
3. ✅ Active views filter deleted records
4. ✅ FINAL returns latest version

### Manual Testing

```bash
# Insert a test record
mysql -h127.0.0.1 -P3306 -uroot -prootpassword imdb -e "
INSERT INTO title_ratings VALUES ('tt9999999', 8.5, 100);"

# Wait for CDC
sleep 5

# Verify in ClickHouse
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
SELECT * FROM imdb.title_ratings_active WHERE tconst = 'tt9999999';"

# Delete from MySQL
mysql -h127.0.0.1 -P3306 -uroot -prootpassword imdb -e "
DELETE FROM title_ratings WHERE tconst = 'tt9999999';"

# Wait for CDC
sleep 5

# Verify deletion
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
SELECT tconst, is_deleted FROM imdb.title_ratings FINAL WHERE tconst = 'tt9999999';"
# Should show: is_deleted = 1

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
SELECT count() FROM imdb.title_ratings_active WHERE tconst = 'tt9999999';"
# Should show: 0 (filtered out)
```

## 🔧 Migration Guide

If you have an existing setup without DELETE support:

```bash
# Run the migration script
./migrate-to-replacingmergetree.sh
```

The script will:
1. ✅ Backup existing data
2. ✅ Drop and recreate tables with ReplacingMergeTree
3. ✅ Restore data from backups
4. ✅ Create new materialized views with DELETE support
5. ✅ Create active data views

**Migration Time**: ~2-5 minutes for empty tables, longer with data

## 📈 Monitoring DELETE Operations

### Check Recent Operations

```sql
SELECT
    cdc_operation,
    COUNT(*) as count
FROM imdb.title_ratings FINAL
WHERE cdc_timestamp >= now() - INTERVAL 1 HOUR
GROUP BY cdc_operation;
```

### Monitor Delete Rate

```sql
SELECT
    toStartOfMinute(cdc_timestamp) as minute,
    countIf(cdc_operation = 'd') as deletes,
    countIf(cdc_operation = 'c') as inserts,
    countIf(cdc_operation = 'u') as updates
FROM imdb.title_ratings
WHERE cdc_timestamp >= now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute DESC;
```

### Active vs Deleted Counts

```sql
SELECT
    'Total Records' as category,
    count() as count
FROM imdb.title_ratings FINAL

UNION ALL

SELECT
    'Active Records' as category,
    count() as count
FROM imdb.title_ratings_active

UNION ALL

SELECT
    'Deleted Records' as category,
    count() as count
FROM imdb.title_ratings FINAL
WHERE is_deleted = 1;
```

## 🚀 Production Best Practices

### 1. Use Active Views for Applications

```python
# Good: Query active data
query = "SELECT * FROM imdb.title_ratings_active WHERE tconst = ?"

# Avoid: Manually filtering deletes everywhere
query = "SELECT * FROM imdb.title_ratings FINAL WHERE tconst = ? AND is_deleted = 0"
```

### 2. Implement Data Retention Policies

```sql
-- Archive old deleted records (older than 90 days)
ALTER TABLE imdb.title_ratings
DROP PARTITION toYYYYMM(now() - INTERVAL 90 DAY)
WHERE is_deleted = 1;
```

### 3. Monitor Storage Growth

ReplacingMergeTree keeps historical versions until merge:
- Background merges happen automatically
- Force merges if needed: `OPTIMIZE TABLE title_ratings FINAL;`
- Monitor partition sizes: `SELECT * FROM system.parts WHERE table = 'title_ratings';`

### 4. Configure Merge Settings

```sql
-- Adjust merge frequency for high-delete workloads
ALTER TABLE imdb.title_ratings
MODIFY SETTING
    merge_with_ttl_timeout = 3600,  -- Merge more frequently
    min_bytes_for_wide_part = 0;     -- Use wide format earlier
```

## 🎓 Key Takeaways

1. ✅ **DELETE operations now replicate** from MySQL to ClickHouse
2. ✅ **Soft delete pattern** preserves audit trail with `is_deleted` flag
3. ✅ **ReplacingMergeTree** ensures latest version is queryable
4. ✅ **Active views** provide clean API for non-deleted data
5. ✅ **FINAL modifier** deduplicates and returns current state
6. ✅ **Partition management** controls storage growth

---

**Version**: 1.0
**Last Updated**: October 2025
**Related**: LESSONS_LEARNED.md, README.md
