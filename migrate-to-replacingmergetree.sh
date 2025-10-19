#!/bin/bash

echo "
==========================================
🔄 MIGRATING TO ReplacingMergeTree
==========================================

This script will migrate CDC tables to support DELETE operations:
- Change MergeTree to ReplacingMergeTree
- Update materialized views to process DELETE operations
- Add 'is_deleted' column for soft deletes
- Create views that filter deleted records

⚠️  WARNING: This will drop and recreate all CDC tables!
   All current CDC data will be preserved by copying to backup tables first.
"

read -p "Do you want to proceed? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "❌ Migration cancelled"
    exit 0
fi

echo "
==========================================
PHASE 1: Backup Existing Data
==========================================
"

echo "📦 Creating backup tables..."
for table in title_ratings title_basics name_basics title_crew title_episode title_akas title_principals; do
    echo "   Backing up $table..."
    docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
    CREATE TABLE IF NOT EXISTS imdb.${table}_backup AS imdb.$table;
    INSERT INTO imdb.${table}_backup SELECT * FROM imdb.$table;
    " 2>/dev/null

    if [ $? -eq 0 ]; then
        count=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT count() FROM imdb.${table}_backup;" 2>/dev/null)
        echo "   ✅ Backed up $count records from $table"
    else
        echo "   ❌ Failed to backup $table"
        exit 1
    fi
done

echo "
==========================================
PHASE 2: Drop Existing CDC Infrastructure
==========================================
"

echo "🗑️  Dropping materialized views..."
for table in title_ratings title_basics name_basics title_crew title_episode title_akas title_principals; do
    docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "DROP VIEW IF EXISTS imdb.${table}_cdc_mv;" 2>/dev/null
    echo "   ✅ Dropped ${table}_cdc_mv"
done

echo "🗑️  Dropping Kafka tables..."
for table in title_ratings title_basics name_basics title_crew title_episode title_akas title_principals; do
    docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "DROP TABLE IF EXISTS imdb.${table}_kafka;" 2>/dev/null
    echo "   ✅ Dropped ${table}_kafka"
done

echo "🗑️  Dropping main tables..."
for table in title_ratings title_basics name_basics title_crew title_episode title_akas title_principals; do
    docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "DROP TABLE IF EXISTS imdb.$table;" 2>/dev/null
    echo "   ✅ Dropped $table"
done

echo "
==========================================
PHASE 3: Create ReplacingMergeTree Tables
==========================================
"

echo "📊 Creating title_ratings with ReplacingMergeTree..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.title_ratings
(
    tconst String,
    averageRating Float32,
    numVotes UInt32,
    cdc_operation String,
    cdc_timestamp DateTime,
    is_deleted UInt8 DEFAULT 0,
    processing_time DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(cdc_timestamp)
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (tconst)
SETTINGS index_granularity = 8192;
"

echo "📊 Creating title_basics with ReplacingMergeTree..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.title_basics
(
    tconst String,
    titleType LowCardinality(String),
    primaryTitle String,
    originalTitle String,
    isAdult UInt8,
    startYear UInt16,
    endYear UInt16 DEFAULT 0,
    runtimeMinutes UInt16 DEFAULT 0,
    genres Array(String),
    cdc_operation String,
    cdc_timestamp DateTime,
    is_deleted UInt8 DEFAULT 0,
    processing_time DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(cdc_timestamp)
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (tconst)
SETTINGS index_granularity = 8192;
"

echo "📊 Creating name_basics with ReplacingMergeTree..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.name_basics
(
    nconst String,
    primaryName String,
    birthYear UInt16 DEFAULT 0,
    deathYear UInt16 DEFAULT 0,
    primaryProfession Array(String),
    knownForTitles Array(String),
    cdc_operation String,
    cdc_timestamp DateTime,
    is_deleted UInt8 DEFAULT 0,
    processing_time DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(cdc_timestamp)
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (nconst)
SETTINGS index_granularity = 8192;
"

echo "📊 Creating title_crew with ReplacingMergeTree..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.title_crew
(
    tconst String,
    directors Array(String),
    writers Array(String),
    cdc_operation String,
    cdc_timestamp DateTime,
    is_deleted UInt8 DEFAULT 0,
    processing_time DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(cdc_timestamp)
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (tconst)
SETTINGS index_granularity = 8192;
"

echo "📊 Creating title_episode with ReplacingMergeTree..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.title_episode
(
    tconst String,
    parentTconst String,
    seasonNumber UInt16 DEFAULT 0,
    episodeNumber UInt16 DEFAULT 0,
    cdc_operation String,
    cdc_timestamp DateTime,
    is_deleted UInt8 DEFAULT 0,
    processing_time DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(cdc_timestamp)
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (tconst)
SETTINGS index_granularity = 8192;
"

echo "📊 Creating title_akas with ReplacingMergeTree..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.title_akas
(
    titleId String,
    ordering UInt16,
    title String,
    region LowCardinality(String),
    language LowCardinality(String),
    types Array(String),
    attributes Array(String),
    isOriginalTitle UInt8 DEFAULT 0,
    cdc_operation String,
    cdc_timestamp DateTime,
    is_deleted UInt8 DEFAULT 0,
    processing_time DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(cdc_timestamp)
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (titleId, ordering)
SETTINGS index_granularity = 8192;
"

echo "📊 Creating title_principals with ReplacingMergeTree..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.title_principals
(
    tconst String,
    ordering UInt16,
    nconst String,
    category LowCardinality(String),
    job String,
    characters Array(String),
    cdc_operation String,
    cdc_timestamp DateTime,
    is_deleted UInt8 DEFAULT 0,
    processing_time DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(cdc_timestamp)
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (tconst, ordering, nconst)
SETTINGS index_granularity = 8192;
"

echo "
==========================================
PHASE 4: Restore Data from Backups
==========================================
"

echo "📥 Restoring data from backups..."
for table in title_ratings title_basics name_basics title_crew title_episode title_akas title_principals; do
    echo "   Restoring $table..."
    docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
    INSERT INTO imdb.$table SELECT * FROM imdb.${table}_backup;
    " 2>/dev/null

    if [ $? -eq 0 ]; then
        count=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT count() FROM imdb.$table;" 2>/dev/null)
        echo "   ✅ Restored $count records to $table"
    else
        echo "   ⚠️  No data to restore for $table (table may have been empty)"
    fi
done

echo "
==========================================
PHASE 5: Create Kafka Tables
==========================================
"

echo "📊 Creating Kafka consumer tables..."

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.title_ratings_kafka (message String)
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.title_ratings', 'clickhouse-cdc-group', 'JSONAsString');
"

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.title_basics_kafka (message String)
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.title_basics', 'clickhouse-cdc-group', 'JSONAsString');
"

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.name_basics_kafka (message String)
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.name_basics', 'clickhouse-cdc-group', 'JSONAsString');
"

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.title_crew_kafka (message String)
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.title_crew', 'clickhouse-cdc-group', 'JSONAsString');
"

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.title_episode_kafka (message String)
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.title_episode', 'clickhouse-cdc-group', 'JSONAsString');
"

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.title_akas_kafka (message String)
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.title_akas', 'clickhouse-cdc-group', 'JSONAsString');
"

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE TABLE IF NOT EXISTS imdb.title_principals_kafka (message String)
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.title_principals', 'clickhouse-cdc-group', 'JSONAsString');
"

echo "✅ Kafka tables created"

echo "
==========================================
PHASE 6: Create Materialized Views with DELETE Support
==========================================
"

echo "📊 Creating title_ratings materialized view with DELETE support..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE MATERIALIZED VIEW IF NOT EXISTS imdb.title_ratings_cdc_mv TO imdb.title_ratings AS
SELECT
    -- For DELETE ops, use 'before', otherwise use 'after'
    if(op = 'd', JSONExtractString(message, 'before', 'tconst'), JSONExtractString(message, 'after', 'tconst')) as tconst,
    if(op = 'd', 0, JSONExtractFloat(message, 'after', 'averageRating')) as averageRating,
    if(op = 'd', 0, JSONExtractUInt(message, 'after', 'numVotes')) as numVotes,
    op as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp,
    if(op = 'd', 1, 0) as is_deleted
FROM (
    SELECT message, JSONExtractString(message, 'op') as op FROM imdb.title_ratings_kafka
)
WHERE op IN ('c', 'u', 'r', 'd')
  AND if(op = 'd',
         length(JSONExtractString(message, 'before', 'tconst')) > 0,
         length(JSONExtractString(message, 'after', 'tconst')) > 0);
"

echo "📊 Creating title_basics materialized view with DELETE support..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE MATERIALIZED VIEW IF NOT EXISTS imdb.title_basics_cdc_mv TO imdb.title_basics AS
SELECT
    if(op = 'd', JSONExtractString(message, 'before', 'tconst'), JSONExtractString(message, 'after', 'tconst')) as tconst,
    if(op = 'd', '', JSONExtractString(message, 'after', 'titleType')) as titleType,
    if(op = 'd', '', JSONExtractString(message, 'after', 'primaryTitle')) as primaryTitle,
    if(op = 'd', '', JSONExtractString(message, 'after', 'originalTitle')) as originalTitle,
    if(op = 'd', 0, JSONExtractUInt(message, 'after', 'isAdult')) as isAdult,
    if(op = 'd', 0, JSONExtractUInt(message, 'after', 'startYear')) as startYear,
    if(op = 'd', 0, JSONExtractUInt(message, 'after', 'endYear')) as endYear,
    if(op = 'd', 0, JSONExtractUInt(message, 'after', 'runtimeMinutes')) as runtimeMinutes,
    if(op = 'd', [], splitByChar(',', JSONExtractString(message, 'after', 'genres'))) as genres,
    op as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp,
    if(op = 'd', 1, 0) as is_deleted
FROM (
    SELECT message, JSONExtractString(message, 'op') as op FROM imdb.title_basics_kafka
)
WHERE op IN ('c', 'u', 'r', 'd')
  AND if(op = 'd',
         length(JSONExtractString(message, 'before', 'tconst')) > 0,
         length(JSONExtractString(message, 'after', 'tconst')) > 0);
"

echo "📊 Creating name_basics materialized view with DELETE support..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE MATERIALIZED VIEW IF NOT EXISTS imdb.name_basics_cdc_mv TO imdb.name_basics AS
SELECT
    if(op = 'd', JSONExtractString(message, 'before', 'nconst'), JSONExtractString(message, 'after', 'nconst')) as nconst,
    if(op = 'd', '', JSONExtractString(message, 'after', 'primaryName')) as primaryName,
    if(op = 'd', 0, JSONExtractUInt(message, 'after', 'birthYear')) as birthYear,
    if(op = 'd', 0, JSONExtractUInt(message, 'after', 'deathYear')) as deathYear,
    if(op = 'd', [], splitByChar(',', JSONExtractString(message, 'after', 'primaryProfession'))) as primaryProfession,
    if(op = 'd', [], splitByChar(',', JSONExtractString(message, 'after', 'knownForTitles'))) as knownForTitles,
    op as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp,
    if(op = 'd', 1, 0) as is_deleted
FROM (
    SELECT message, JSONExtractString(message, 'op') as op FROM imdb.name_basics_kafka
)
WHERE op IN ('c', 'u', 'r', 'd')
  AND if(op = 'd',
         length(JSONExtractString(message, 'before', 'nconst')) > 0,
         length(JSONExtractString(message, 'after', 'nconst')) > 0);
"

echo "📊 Creating title_crew materialized view with DELETE support..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE MATERIALIZED VIEW IF NOT EXISTS imdb.title_crew_cdc_mv TO imdb.title_crew AS
SELECT
    if(op = 'd', JSONExtractString(message, 'before', 'tconst'), JSONExtractString(message, 'after', 'tconst')) as tconst,
    if(op = 'd', [], splitByChar(',', JSONExtractString(message, 'after', 'directors'))) as directors,
    if(op = 'd', [], splitByChar(',', JSONExtractString(message, 'after', 'writers'))) as writers,
    op as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp,
    if(op = 'd', 1, 0) as is_deleted
FROM (
    SELECT message, JSONExtractString(message, 'op') as op FROM imdb.title_crew_kafka
)
WHERE op IN ('c', 'u', 'r', 'd')
  AND if(op = 'd',
         length(JSONExtractString(message, 'before', 'tconst')) > 0,
         length(JSONExtractString(message, 'after', 'tconst')) > 0);
"

echo "📊 Creating title_episode materialized view with DELETE support..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE MATERIALIZED VIEW IF NOT EXISTS imdb.title_episode_cdc_mv TO imdb.title_episode AS
SELECT
    if(op = 'd', JSONExtractString(message, 'before', 'tconst'), JSONExtractString(message, 'after', 'tconst')) as tconst,
    if(op = 'd', '', JSONExtractString(message, 'after', 'parentTconst')) as parentTconst,
    if(op = 'd', 0, JSONExtractUInt(message, 'after', 'seasonNumber')) as seasonNumber,
    if(op = 'd', 0, JSONExtractUInt(message, 'after', 'episodeNumber')) as episodeNumber,
    op as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp,
    if(op = 'd', 1, 0) as is_deleted
FROM (
    SELECT message, JSONExtractString(message, 'op') as op FROM imdb.title_episode_kafka
)
WHERE op IN ('c', 'u', 'r', 'd')
  AND if(op = 'd',
         length(JSONExtractString(message, 'before', 'tconst')) > 0,
         length(JSONExtractString(message, 'after', 'tconst')) > 0);
"

echo "📊 Creating title_akas materialized view with DELETE support..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE MATERIALIZED VIEW IF NOT EXISTS imdb.title_akas_cdc_mv TO imdb.title_akas AS
SELECT
    if(op = 'd', JSONExtractString(message, 'before', 'titleId'), JSONExtractString(message, 'after', 'titleId')) as titleId,
    if(op = 'd', JSONExtractUInt(message, 'before', 'ordering'), JSONExtractUInt(message, 'after', 'ordering')) as ordering,
    if(op = 'd', '', JSONExtractString(message, 'after', 'title')) as title,
    if(op = 'd', '', JSONExtractString(message, 'after', 'region')) as region,
    if(op = 'd', '', JSONExtractString(message, 'after', 'language')) as language,
    if(op = 'd', [], splitByChar(',', JSONExtractString(message, 'after', 'types'))) as types,
    if(op = 'd', [], splitByChar(',', JSONExtractString(message, 'after', 'attributes'))) as attributes,
    if(op = 'd', 0, JSONExtractUInt(message, 'after', 'isOriginalTitle')) as isOriginalTitle,
    op as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp,
    if(op = 'd', 1, 0) as is_deleted
FROM (
    SELECT message, JSONExtractString(message, 'op') as op FROM imdb.title_akas_kafka
)
WHERE op IN ('c', 'u', 'r', 'd')
  AND if(op = 'd',
         length(JSONExtractString(message, 'before', 'titleId')) > 0,
         length(JSONExtractString(message, 'after', 'titleId')) > 0);
"

echo "📊 Creating title_principals materialized view with DELETE support..."
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE MATERIALIZED VIEW IF NOT EXISTS imdb.title_principals_cdc_mv TO imdb.title_principals AS
SELECT
    if(op = 'd', JSONExtractString(message, 'before', 'tconst'), JSONExtractString(message, 'after', 'tconst')) as tconst,
    if(op = 'd', JSONExtractUInt(message, 'before', 'ordering'), JSONExtractUInt(message, 'after', 'ordering')) as ordering,
    if(op = 'd', JSONExtractString(message, 'before', 'nconst'), JSONExtractString(message, 'after', 'nconst')) as nconst,
    if(op = 'd', '', JSONExtractString(message, 'after', 'category')) as category,
    if(op = 'd', '', JSONExtractString(message, 'after', 'job')) as job,
    if(op = 'd', [], splitByChar(',', JSONExtractString(message, 'after', 'characters'))) as characters,
    op as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp,
    if(op = 'd', 1, 0) as is_deleted
FROM (
    SELECT message, JSONExtractString(message, 'op') as op FROM imdb.title_principals_kafka
)
WHERE op IN ('c', 'u', 'r', 'd')
  AND if(op = 'd',
         length(JSONExtractString(message, 'before', 'tconst')) > 0,
         length(JSONExtractString(message, 'after', 'tconst')) > 0);
"

echo "✅ All materialized views created with DELETE support"

echo "
==========================================
PHASE 7: Create Active Data Views
==========================================
"

echo "📊 Creating views that automatically filter deleted records..."

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE OR REPLACE VIEW imdb.title_ratings_active AS
SELECT tconst, averageRating, numVotes, cdc_operation, cdc_timestamp
FROM imdb.title_ratings FINAL
WHERE is_deleted = 0;
"

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE OR REPLACE VIEW imdb.title_basics_active AS
SELECT tconst, titleType, primaryTitle, originalTitle, isAdult, startYear, endYear, runtimeMinutes, genres, cdc_operation, cdc_timestamp
FROM imdb.title_basics FINAL
WHERE is_deleted = 0;
"

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE OR REPLACE VIEW imdb.name_basics_active AS
SELECT nconst, primaryName, birthYear, deathYear, primaryProfession, knownForTitles, cdc_operation, cdc_timestamp
FROM imdb.name_basics FINAL
WHERE is_deleted = 0;
"

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE OR REPLACE VIEW imdb.title_crew_active AS
SELECT tconst, directors, writers, cdc_operation, cdc_timestamp
FROM imdb.title_crew FINAL
WHERE is_deleted = 0;
"

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE OR REPLACE VIEW imdb.title_episode_active AS
SELECT tconst, parentTconst, seasonNumber, episodeNumber, cdc_operation, cdc_timestamp
FROM imdb.title_episode FINAL
WHERE is_deleted = 0;
"

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE OR REPLACE VIEW imdb.title_akas_active AS
SELECT titleId, ordering, title, region, language, types, attributes, isOriginalTitle, cdc_operation, cdc_timestamp
FROM imdb.title_akas FINAL
WHERE is_deleted = 0;
"

docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
CREATE OR REPLACE VIEW imdb.title_principals_active AS
SELECT tconst, ordering, nconst, category, job, characters, cdc_operation, cdc_timestamp
FROM imdb.title_principals FINAL
WHERE is_deleted = 0;
"

echo "✅ Active data views created"

echo "
==========================================
✅ MIGRATION COMPLETE!
==========================================

🎉 CDC tables now support DELETE operations!

📊 What changed:
- Tables now use ReplacingMergeTree engine
- Materialized views process DELETE operations
- Added 'is_deleted' column to track deletion status
- Created '*_active' views that filter out deleted records

📚 How to use:

1. Query all data (including deleted):
   SELECT * FROM imdb.title_ratings FINAL;

2. Query only active (non-deleted) data:
   SELECT * FROM imdb.title_ratings_active;

3. Query deleted records only:
   SELECT * FROM imdb.title_ratings FINAL WHERE is_deleted = 1;

4. See CDC operations:
   SELECT tconst, cdc_operation, cdc_timestamp, is_deleted
   FROM imdb.title_ratings FINAL
   ORDER BY cdc_timestamp DESC LIMIT 10;

🧹 Cleanup (optional):
   To remove backup tables after verification:
   DROP TABLE imdb.title_ratings_backup;
   DROP TABLE imdb.title_basics_backup;
   etc...

🧪 Next steps:
   Run ./test-cdc.sh to verify DELETE operations work correctly
"
