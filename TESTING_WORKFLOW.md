# Testing Workflow & Data Management

This document covers the complete testing workflow for the CDC platform, including sample data loading, validation, and cleanup strategies.

## 🎯 Overview

The testing workflow provides:
- **Sample data loading** - Load configurable subsets of IMDb data for testing
- **Data validation** - Verify data integrity between MySQL and ClickHouse
- **Cleanup strategies** - Multiple cleanup modes for different use cases
- **Automated testing** - Run tests with automatic cleanup on success

## 📊 Testing Scripts

### 1. Data Type Testing: `test-data-types.sh`

Tests CDC replication accuracy for different data types with small, controlled datasets.

```bash
./test-data-types.sh
```

**What it tests:**
- ✅ Float precision (9.123456)
- ✅ Large integers (2,147,483,647)
- ✅ Special characters (@#$%)
- ✅ Arrays (comma-separated strings)
- ✅ Empty arrays
- ✅ UInt8/boolean values
- ✅ Year ranges and historical dates

**Test Results:**
- Inserts 5 test records per table (15 total)
- Validates each data type
- Compares MySQL vs ClickHouse values
- Cleans up after completion

**Use case:** Quick validation that CDC is working correctly for all data types.

---

### 2. Sample Data Loader: `load-imdb-sample.sh`

Loads configurable subsets of real IMDb data for realistic testing.

```bash
# Interactive mode
./load-imdb-sample.sh

# Quick test with 1,000 rows
echo "1
1000
yes" | ./load-imdb-sample.sh

# Larger test with 100,000 rows (default)
echo "1
100000
yes" | ./load-imdb-sample.sh

# Custom row limit via environment variable
ROW_LIMIT=50000 ./load-imdb-sample.sh
```

**Features:**
- 📋 Interactive table selection (1-5 available tables)
- 🎚️ Configurable row limits (1K to 1M+)
- ⏱️ Fast loading (1K rows = ~10 seconds, 100K rows = ~2 minutes)
- ✅ Built-in validation and CDC monitoring
- 📊 Side-by-side MySQL/ClickHouse comparison

**Available Tables:**
1. `title_ratings` (1.6M total) - ⭐ Recommended for quick tests
2. `title_basics` (11M total) - Movie/TV metadata
3. `name_basics` (14M total) - People data
4. `title_crew` (11M total) - Directors/writers
5. `title_episode` (8M total) - Episode information

**Comparison vs Full Load:**

| Aspect | load-imdb-data.sh | load-imdb-sample.sh |
|--------|-------------------|---------------------|
| Rows | 194M (full) | 1K-1M (configurable) |
| Time | 30-60 minutes | 10 seconds - 5 minutes |
| Tables | All 7 tables | Select 1-5 tables |
| Validation | Basic counts | Full data comparison |
| Use case | Production data | Testing, development |

---

### 3. Comprehensive CDC Tests: `test-cdc.sh`

Full CDC pipeline validation including all operations and routing.

```bash
./test-cdc.sh
```

**What it tests:**
- ✅ Service health (MySQL, ClickHouse, ProxySQL, Debezium)
- ✅ CDC INSERT operations (via ProxySQL and direct MySQL)
- ✅ CDC UPDATE operations (with timing)
- ✅ CDC DELETE operations (soft delete with ReplacingMergeTree)
- ✅ OLAP query routing (COUNT, SUM, AVG, MAX/MIN)
- ✅ OLTP query routing (SELECT, INSERT)
- ✅ Performance comparison (MySQL vs ClickHouse)
- ✅ ProxySQL routing statistics

**Test Data:**
- Creates 2 test records with known values
- Tests all CRUD operations
- Validates replication timing (typically 3-6 seconds)
- Cleans up via DELETE (marks as `is_deleted=1` in ClickHouse)

**Exit codes:**
- `0` - All tests passed
- `1` - One or more tests failed

---

## 🧹 Cleanup Strategies

### Understanding Cleanup with DELETE Support

With ReplacingMergeTree, there are two types of cleanup:

#### **Soft Cleanup (DELETE from MySQL)**
```sql
DELETE FROM title_ratings WHERE tconst LIKE 'test%';
```

- ✅ Propagates via CDC to ClickHouse
- ✅ Records marked as `is_deleted=1`
- ✅ Filtered from `*_active` views
- ✅ Preserves audit trail
- ❌ Data still physically in ClickHouse

**Use case:** When you need audit trail or want to use CDC properly.

#### **Hard Cleanup (TRUNCATE both databases)**
```sql
-- Pause CDC
TRUNCATE TABLE title_ratings;  -- MySQL
TRUNCATE TABLE title_ratings;  -- ClickHouse
-- Resume CDC
```

- ✅ Completely removes all data
- ✅ Fast (instant)
- ✅ Clears deleted records too
- ❌ Requires pausing CDC
- ❌ No audit trail

**Use case:** Testing cycles, complete reset between test runs.

---

### Cleanup Script: `cleanup-test-data.sh`

Provides hard cleanup for test data with proper CDC handling.

```bash
# Interactive mode (asks for confirmation)
./cleanup-test-data.sh

# Force mode (no confirmation)
./cleanup-test-data.sh --force

# With Kafka offset reset
./cleanup-test-data.sh --force --reset-kafka
```

**What it does:**

1. **Shows current data counts** - Preview what will be deleted
2. **Pauses CDC connectors** - Prevents replication issues
3. **Truncates MySQL tables** - Removes all data
4. **Truncates ClickHouse tables** - Removes all data (including soft deletes)
5. **Optionally resets Kafka offsets** - Fresh start for consumer groups
6. **Resumes CDC connectors** - Ready for next test
7. **Verifies cleanup** - Confirms all tables are empty

**Safety features:**
- ✅ Shows what will be deleted before proceeding
- ✅ Requires confirmation (unless `--force`)
- ✅ Handles CDC properly (pause/resume)
- ✅ Verifies cleanup completed
- ✅ Can be run multiple times safely

**Output example:**
```
==========================================
📊 Current Data Status
==========================================

MySQL record counts:
  title_ratings           1000 rows
  title_basics               0 rows
  ...

ClickHouse record counts (active data):
  title_ratings           1000 rows
  title_basics               0 rows
  ...

⚠️  Proceed with cleanup? This will delete ALL data! (yes/no):
```

---

### Test Wrapper: `run-test-with-cleanup.sh`

Automated testing with intelligent cleanup.

```bash
./run-test-with-cleanup.sh
```

**Workflow:**
1. Runs `test-cdc.sh`
2. **If tests pass** → Automatically runs `cleanup-test-data.sh --force`
3. **If tests fail** → Preserves data for troubleshooting

**Use case:** Continuous testing with no data drift.

**Example output:**
```bash
# Tests pass
✅ ALL TESTS PASSED!
🧹 Cleaning up test data...
✅ Cleanup completed successfully
🎉 Ready for next test run!

# Tests fail
❌ TESTS FAILED
💡 Test data has been PRESERVED for troubleshooting
```

---

## 📋 Testing Workflows

### Workflow 1: Quick Validation (Recommended)

**Goal:** Verify CDC is working correctly

```bash
# 1. Run data type tests
./test-data-types.sh

# 2. Run comprehensive CDC tests
./test-cdc.sh

# 3. Clean up
./cleanup-test-data.sh --force
```

**Time:** ~2 minutes
**Data:** ~15 test records

---

### Workflow 2: Realistic Load Testing

**Goal:** Test with real data at scale

```bash
# 1. Load sample data (10K rows)
echo "1
10000
yes" | ./load-imdb-sample.sh

# 2. Run tests
./test-cdc.sh

# 3. Clean up
./cleanup-test-data.sh --force
```

**Time:** ~5 minutes
**Data:** 10,000 real IMDb records

---

### Workflow 3: Automated Testing (CI/CD)

**Goal:** Run tests automatically with cleanup

```bash
# Single command - auto cleanup on success
./run-test-with-cleanup.sh
```

**Time:** ~2 minutes
**Data:** Test records only (cleaned up automatically)

---

### Workflow 4: Development/Debugging

**Goal:** Iterate on features with persistent data

```bash
# 1. Load sample data once
./load-imdb-sample.sh

# 2. Develop/test features (keeps data)
./test-cdc.sh  # Can run multiple times

# 3. Manual cleanup when done
./cleanup-test-data.sh
```

**Time:** Variable
**Data:** Persists until manual cleanup

---

## 🔍 Data Validation

### Manual Data Comparison

Compare random records between MySQL and ClickHouse:

```bash
# Get random IDs
ids=$(docker exec mysql-cdc mysql -u root -prootpassword imdb -N -e \
  "SELECT tconst FROM title_ratings ORDER BY RAND() LIMIT 5;" 2>/dev/null)

# Compare each record
for id in $ids; do
    echo "Record: $id"
    echo "MySQL:"
    docker exec mysql-cdc mysql -u root -prootpassword imdb -e \
      "SELECT * FROM title_ratings WHERE tconst='$id'" 2>/dev/null

    echo "ClickHouse:"
    docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query \
      "SELECT * FROM imdb.title_ratings FINAL WHERE tconst='$id' FORMAT Pretty" 2>/dev/null
done
```

### Validation Queries

**Check counts match:**
```bash
# MySQL count
mysql -h127.0.0.1 -P3306 -uroot -prootpassword imdb -N -e \
  "SELECT COUNT(*) FROM title_ratings;"

# ClickHouse active count
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query \
  "SELECT count() FROM imdb.title_ratings_active;"
```

**Check for deleted records:**
```bash
# Count soft-deleted records in ClickHouse
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query \
  "SELECT count() FROM imdb.title_ratings FINAL WHERE is_deleted=1;"
```

**Check CDC operations:**
```bash
# See recent CDC operations
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
SELECT
    cdc_operation,
    COUNT(*) as count
FROM imdb.title_ratings FINAL
WHERE cdc_timestamp >= now() - INTERVAL 1 HOUR
GROUP BY cdc_operation
ORDER BY cdc_operation;"
```

---

## 🎓 Best Practices

### 1. Test Data Isolation

**DO:**
- ✅ Use `test-data-types.sh` for quick validation
- ✅ Use `load-imdb-sample.sh` for realistic testing
- ✅ Clean up after successful tests
- ✅ Use prefixed IDs for test data (`test001`, etc.)

**DON'T:**
- ❌ Mix test data with production data
- ❌ Leave test data accumulating
- ❌ Skip cleanup between test runs

### 2. CDC-Friendly Testing

**DO:**
- ✅ Use `cleanup-test-data.sh` which handles CDC properly
- ✅ Pause CDC before TRUNCATE operations
- ✅ Wait for CDC replication before validation
- ✅ Monitor CDC lag during large loads

**DON'T:**
- ❌ TRUNCATE without pausing CDC
- ❌ Assume immediate replication (wait 5-10s)
- ❌ Reset Kafka offsets unnecessarily

### 3. Troubleshooting Failed Tests

When tests fail:

1. **Don't clean up immediately** - Data is preserved for debugging
2. **Check the error messages** - Look at test output
3. **Verify CDC is working:**
   ```bash
   ./monitor-cdc-lag.sh
   curl -s http://localhost:8083/connectors/imdb-title-ratings-cdc/status | jq
   ```
4. **Inspect the data:**
   ```bash
   mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 imdb
   ```
5. **Check ClickHouse:**
   ```bash
   docker exec clickhouse-cdc clickhouse-client --password clickhouse123
   ```
6. **Clean up when done:**
   ```bash
   ./cleanup-test-data.sh
   ```

---

## 📊 Performance Benchmarks

### Sample Data Loading (MacBook Pro M2)

| Rows | Time | Rate |
|------|------|------|
| 1,000 | 10s | 100 rows/s |
| 10,000 | 1m | 167 rows/s |
| 100,000 | 10m | 167 rows/s |
| 1,000,000 | ~90m | 185 rows/s |

### CDC Replication Latency

| Operation | Typical Latency |
|-----------|----------------|
| INSERT | 3-5 seconds |
| UPDATE | 3-6 seconds |
| DELETE | 3-5 seconds |

### Cleanup Performance

| Operation | Time |
|-----------|------|
| Pause CDC | 5 seconds |
| TRUNCATE MySQL | <1 second |
| TRUNCATE ClickHouse | <1 second |
| Resume CDC | 2-5 seconds |
| **Total** | **~10 seconds** |

---

## 🚀 Advanced Topics

### Custom Test Data

Create your own test data files:

```bash
cd ../init.db

# Create custom TSV file
cat > custom_ratings.tsv << 'EOF'
tconst	averageRating	numVotes
custom001	9.9	999999
custom002	1.0	1
EOF

# Load via MySQL
docker exec mysql-cdc mysql -u root -prootpassword imdb -e "
LOAD DATA INFILE '/imdb-data/custom_ratings.tsv'
INTO TABLE title_ratings
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;"

# Wait for CDC and verify
sleep 10
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query \
  "SELECT * FROM imdb.title_ratings_active WHERE tconst LIKE 'custom%';"
```

### Selective Cleanup

Clean specific tables only:

```bash
# Clean only title_ratings
docker exec mysql-cdc mysql -u root -prootpassword imdb -e "TRUNCATE TABLE title_ratings;"
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "TRUNCATE TABLE imdb.title_ratings;"
```

### Kafka Offset Management

```bash
# Check current offsets
docker exec redpanda-cdc rpk group describe clickhouse-cdc-group

# Reset to beginning (reprocess all messages)
docker exec redpanda-cdc rpk group seek clickhouse-cdc-group --to start

# Reset to end (skip all messages)
docker exec redpanda-cdc rpk group seek clickhouse-cdc-group --to end
```

---

## 📝 Quick Reference

### Common Commands

```bash
# Quick validation
./test-data-types.sh && ./cleanup-test-data.sh --force

# Load and test 10K rows
echo "1\n10000\nyes" | ./load-imdb-sample.sh && ./test-cdc.sh

# Automated test with cleanup
./run-test-with-cleanup.sh

# Manual cleanup
./cleanup-test-data.sh --force

# Full reset including Kafka
./cleanup-test-data.sh --force --reset-kafka
```

### Troubleshooting

```bash
# Check service health
docker compose ps

# Monitor CDC lag
./monitor-cdc-lag.sh

# Check connector status
curl -s http://localhost:8083/connectors | jq

# View ClickHouse data
docker exec clickhouse-cdc clickhouse-client --password clickhouse123

# View MySQL data
mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 imdb
```

---

**Version**: 1.0
**Last Updated**: October 2025
**Related Docs**: README.md, DELETE_SUPPORT.md, LESSONS_LEARNED.md
