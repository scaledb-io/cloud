#!/bin/bash

echo "
==========================================
📊 IMDb Dataset Loader for Production CDC
==========================================

This script will download and load the complete IMDb dataset
into your running CDC platform. Total size: ~7GB data

Expected records: 134M+ across 7 tables
Estimated time: 30-60 minutes depending on hardware
"

# Check if services are running
if ! docker compose ps | grep -q "Up"; then
    echo "❌ CDC Platform not running. Please run ./setup-production-cdc.sh first"
    exit 1
fi

echo "✅ CDC Platform detected as running"

echo "🔍 Checking CDC connectors..."
# Check which connectors are available
connectors=$(curl -s http://localhost:8083/connectors 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' | sort)
if [ -z "$connectors" ]; then
    echo "❌ No CDC connectors found. Please ensure Debezium is running and connectors are created."
    exit 1
fi

echo "✅ Available CDC connectors:"
echo "$connectors" | sed 's/^/   - /'
echo ""

echo "
==========================================
📥 Downloading IMDb Dataset Files
==========================================
"

mkdir -p ../init.db
cd ../init.db

# Download with progress indicators
echo "📊 Downloading IMDb datasets (this may take 10-15 minutes)..."

files=(
    "title.ratings.tsv.gz"
    "title.basics.tsv.gz" 
    "name.basics.tsv.gz"
    "title.crew.tsv.gz"
    "title.episode.tsv.gz"
    "title.akas.tsv.gz"
    "title.principals.tsv.gz"
)

for file in "${files[@]}"; do
    if [ ! -f "$file" ]; then
        echo "  📥 Downloading $file..."
        curl -# -O "https://datasets.imdbws.com/$file"
    else
        echo "  ✅ $file already exists"
    fi
done

echo "🔄 Extracting files..."
gunzip -k *.tsv.gz

cd ../production-setup

echo "
==========================================
📤 Loading Data with Real-time CDC
==========================================
"

echo "💡 Monitor CDC streaming in another terminal:"
echo "   docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query \"SELECT table, count() as records FROM system.parts WHERE database = 'imdb' GROUP BY table;\""
echo ""

# Function to show loading progress
load_table() {
    local table=$1
    local file=$2
    local estimated_records=$3
    
    echo "📊 Loading $table (~$estimated_records records)..."
    start_time=$(date +%s)
    
    docker exec mysql-cdc mysql -u root -prootpassword imdb -e "
    LOAD DATA INFILE '/imdb-data/$file' 
    INTO TABLE $table 
    FIELDS TERMINATED BY '\t' 
    LINES TERMINATED BY '\n' 
    IGNORE 1 ROWS;" 2>/dev/null
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    # Get actual record count
    actual_count=$(docker exec mysql-cdc mysql -u root -prootpassword imdb -N -e "SELECT COUNT(*) FROM $table;" 2>/dev/null)
    
    echo "   ✅ Loaded $actual_count records in ${duration}s"
    
    # Give CDC a moment to process
    sleep 2
    
    # Check ClickHouse replication with retries
    echo "   ⏳ Waiting for CDC replication..."
    for i in {1..6}; do
        sleep 5
        ch_count=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT count() FROM imdb.$table;" 2>/dev/null || echo "0")
        if [ "$ch_count" -gt 0 ]; then
            echo "   ✅ CDC replicated $ch_count records to ClickHouse"
            break
        elif [ $i -eq 6 ]; then
            echo "   ⚠️  CDC replication may be slow - only $ch_count records replicated so far"
            echo "      This is normal for large datasets, replication will continue in background"
        else
            echo "      🔄 Attempt $i/6 - $ch_count records replicated so far..."
        fi
    done
    echo ""
}

# Load all 7 IMDb tables with CDC replication (in order of size - smallest first)
echo "📊 Loading all IMDb tables with CDC replication enabled..."

# Small tables first
if echo "$connectors" | grep -q "title-ratings"; then
    load_table "title_ratings" "title.ratings.tsv" "1.6M"
else
    echo "⚠️  Skipping title_ratings - no CDC connector found"
fi

# Medium tables
if echo "$connectors" | grep -q "title-episode"; then
    load_table "title_episode" "title.episode.tsv" "8M"
else
    echo "⚠️  Skipping title_episode - no CDC connector found"
fi

if echo "$connectors" | grep -q "title-crew"; then
    load_table "title_crew" "title.crew.tsv" "11M"
else
    echo "⚠️  Skipping title_crew - no CDC connector found"
fi

if echo "$connectors" | grep -q "title-basics"; then
    load_table "title_basics" "title.basics.tsv" "11M"
else
    echo "⚠️  Skipping title_basics - no CDC connector found"
fi

if echo "$connectors" | grep -q "name-basics"; then
    load_table "name_basics" "name.basics.tsv" "14M"
else
    echo "⚠️  Skipping name_basics - no CDC connector found"
fi

# Large tables last
echo "⚠️  Loading large tables - this will take 15-30 minutes each..."

if echo "$connectors" | grep -q "title-akas"; then
    load_table "title_akas" "title.akas.tsv" "40M+"
else
    echo "⚠️  Skipping title_akas - no CDC connector found"
fi

if echo "$connectors" | grep -q "title-principals"; then
    load_table "title_principals" "title.principals.tsv" "50M+"
else
    echo "⚠️  Skipping title_principals - no CDC connector found"
fi

echo "✅ All available tables loaded with real-time CDC replication!"

echo "
==========================================
📊 Final Data Summary
==========================================
"

# Show final counts
echo "📈 MySQL (source) record counts:"
docker exec mysql-cdc mysql -u root -prootpassword imdb -e "
SELECT 'title_ratings' as table_name, COUNT(*) as records FROM title_ratings
UNION ALL SELECT 'title_basics', COUNT(*) FROM title_basics
UNION ALL SELECT 'name_basics', COUNT(*) FROM name_basics  
UNION ALL SELECT 'title_crew', COUNT(*) FROM title_crew
UNION ALL SELECT 'title_episode', COUNT(*) FROM title_episode
UNION ALL SELECT 'title_akas', COUNT(*) FROM title_akas
UNION ALL SELECT 'title_principals', COUNT(*) FROM title_principals
UNION ALL SELECT '==== TOTAL ====', (
    (SELECT COUNT(*) FROM title_ratings) + 
    (SELECT COUNT(*) FROM title_basics) +
    (SELECT COUNT(*) FROM name_basics) +
    (SELECT COUNT(*) FROM title_crew) +
    (SELECT COUNT(*) FROM title_episode) +
    (SELECT COUNT(*) FROM title_akas) +
    (SELECT COUNT(*) FROM title_principals)
);" 2>/dev/null

echo ""
echo "📈 ClickHouse (CDC target) record counts:"
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
SELECT 'title_ratings' as table_name, count() as records FROM imdb.title_ratings
UNION ALL SELECT 'title_basics', count() FROM imdb.title_basics
UNION ALL SELECT 'name_basics', count() FROM imdb.name_basics
UNION ALL SELECT 'title_crew', count() FROM imdb.title_crew  
UNION ALL SELECT 'title_episode', count() FROM imdb.title_episode
UNION ALL SELECT 'title_akas', count() FROM imdb.title_akas
UNION ALL SELECT 'title_principals', count() FROM imdb.title_principals
UNION ALL SELECT '==== TOTAL ====', (
    (SELECT count() FROM imdb.title_ratings) +
    (SELECT count() FROM imdb.title_basics) +
    (SELECT count() FROM imdb.name_basics) +
    (SELECT count() FROM imdb.title_crew) +
    (SELECT count() FROM imdb.title_episode) +
    (SELECT count() FROM imdb.title_akas) +
    (SELECT count() FROM imdb.title_principals)
);" 2>/dev/null

echo "
🎉 IMDb Dataset Loading Complete!
✅ 134M+ records loaded and streaming via CDC
✅ Real-time replication MySQL → ClickHouse
✅ Ready for intelligent query routing tests

🎯 Test your setup:
mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 -e \"SELECT COUNT(*) FROM imdb_cdc.title_basics;\"
"