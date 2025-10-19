#!/bin/bash

echo "
==========================================
🧪 CDC Data Type Replication Test
==========================================

This script tests CDC replication accuracy for different data types:
- Strings (VARCHAR, TEXT)
- Integers (TINYINT, SMALLINT, INT)
- Floats (DECIMAL, FLOAT, DOUBLE)
- Arrays (comma-separated strings)
- Special characters and NULL values
"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"
MYSQL_USER="root"
MYSQL_PASS="rootpassword"
MYSQL_DB="imdb"

test_passed=0
test_failed=0

echo "
==========================================
PHASE 1: Insert Test Data into MySQL
==========================================
"

echo "📊 Inserting test data into title_ratings..."
mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB <<EOF 2>/dev/null
-- Clear any existing test data
DELETE FROM title_ratings WHERE tconst LIKE 'test%';

-- Insert test records with various data types
INSERT INTO title_ratings (tconst, averageRating, numVotes) VALUES
('test001', 8.5, 1000),           -- Normal float
('test002', 9.123456, 999999),    -- High precision float
('test003', 0.1, 1),              -- Small float
('test004', 10.0, 0),             -- Max rating, zero votes
('test005', 1.0, 2147483647);     -- Min rating, max int
EOF

if [ $? -eq 0 ]; then
    echo "✅ Inserted 5 test records into title_ratings"
else
    echo "❌ Failed to insert test data into title_ratings"
    exit 1
fi

echo "📊 Inserting test data into title_basics..."
mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB <<EOF 2>/dev/null
-- Clear any existing test data
DELETE FROM title_basics WHERE tconst LIKE 'test%';

-- Insert test records with various data types
INSERT INTO title_basics (tconst, titleType, primaryTitle, originalTitle, isAdult, startYear, endYear, runtimeMinutes, genres) VALUES
('test001', 'movie', 'Test Movie 1', 'Original Title 1', 0, 2020, 0, 120, 'Drama,Action'),
('test002', 'tvSeries', 'Test TV Show', 'Test TV Show', 0, 2021, 2023, 45, 'Comedy,Romance'),
('test003', 'short', 'Test Short', 'Test Short', 1, 1990, 0, 5, 'Documentary'),
('test004', 'movie', 'Special Chars: @#\$%', 'Spëcïål Çhārs', 0, 2024, 0, 90, 'Sci-Fi,Thriller'),
('test005', 'tvEpisode', 'Empty Genre Test', 'Empty Genre', 0, 2022, 0, 30, '');
EOF

if [ $? -eq 0 ]; then
    echo "✅ Inserted 5 test records into title_basics"
else
    echo "❌ Failed to insert test data into title_basics"
    exit 1
fi

echo "📊 Inserting test data into name_basics..."
mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB <<EOF 2>/dev/null
-- Clear any existing test data
DELETE FROM name_basics WHERE nconst LIKE 'test%';

-- Insert test records
INSERT INTO name_basics (nconst, primaryName, birthYear, deathYear, primaryProfession, knownForTitles) VALUES
('test001', 'John Doe', 1980, 0, 'actor,director', 'test001,test002'),
('test002', 'Jane Smith', 1990, 0, 'actress,producer', 'test003'),
('test003', 'Old Timer', 1920, 2000, 'actor', 'test004,test005'),
('test004', 'Spëcïål Ñåmé', 1985, 0, 'writer', ''),
('test005', 'No Profession', 2000, 0, '', 'test001');
EOF

if [ $? -eq 0 ]; then
    echo "✅ Inserted 5 test records into name_basics"
else
    echo "❌ Failed to insert test data into name_basics"
    exit 1
fi

echo "
==========================================
PHASE 2: Wait for CDC Replication
==========================================
"

echo "⏳ Waiting 10 seconds for CDC to process..."
sleep 10

echo "
==========================================
PHASE 3: Verify Replication Counts
==========================================
"

function check_count() {
    local table=$1
    local condition=$2

    mysql_count=$(mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB -N -e "SELECT COUNT(*) FROM $table WHERE $condition" 2>/dev/null)

    # For ClickHouse, use the active view to exclude any previously deleted records
    if docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT count() FROM system.tables WHERE database='imdb' AND name='${table}_active'" 2>/dev/null | grep -q "1"; then
        ch_count=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT COUNT(*) FROM imdb.${table}_active WHERE $condition" 2>/dev/null)
    else
        ch_count=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT COUNT(*) FROM imdb.$table WHERE $condition" 2>/dev/null)
    fi

    echo -n "   $table: MySQL=$mysql_count, ClickHouse=$ch_count ... "

    if [ "$mysql_count" = "$ch_count" ]; then
        echo -e "${GREEN}✅ PASS${NC}"
        ((test_passed++))
        return 0
    else
        echo -e "${RED}❌ FAIL (mismatch)${NC}"
        ((test_failed++))
        return 1
    fi
}

echo "📊 Checking record counts..."
check_count "title_ratings" "tconst LIKE 'test%'"
check_count "title_basics" "tconst LIKE 'test%'"
check_count "name_basics" "nconst LIKE 'test%'"

echo "
==========================================
PHASE 4: Verify Data Type Accuracy
==========================================
"

echo "📊 Testing title_ratings data types..."

# Test Float precision
mysql_rating=$(mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB -N -e "SELECT averageRating FROM title_ratings WHERE tconst='test002'" 2>/dev/null)
ch_rating=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT averageRating FROM imdb.title_ratings FINAL WHERE tconst='test002'" 2>/dev/null)

echo -n "   Float precision (test002): MySQL=$mysql_rating, ClickHouse=$ch_rating ... "
# Allow small floating point differences
mysql_int=$(echo "$mysql_rating * 100" | bc | cut -d. -f1)
ch_int=$(echo "$ch_rating * 100" | bc | cut -d. -f1)
diff=$((mysql_int - ch_int))
diff=${diff#-}  # absolute value

if [ $diff -lt 2 ]; then  # Allow 0.01 difference
    echo -e "${GREEN}✅ PASS${NC}"
    ((test_passed++))
else
    echo -e "${RED}❌ FAIL (precision loss: $diff)${NC}"
    ((test_failed++))
fi

# Test Large Integer
mysql_votes=$(mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB -N -e "SELECT numVotes FROM title_ratings WHERE tconst='test005'" 2>/dev/null)
ch_votes=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT numVotes FROM imdb.title_ratings FINAL WHERE tconst='test005'" 2>/dev/null)

echo -n "   Large integer (test005): MySQL=$mysql_votes, ClickHouse=$ch_votes ... "
if [ "$mysql_votes" = "$ch_votes" ]; then
    echo -e "${GREEN}✅ PASS${NC}"
    ((test_passed++))
else
    echo -e "${RED}❌ FAIL${NC}"
    ((test_failed++))
fi

echo "
📊 Testing title_basics data types..."

# Test String with special characters
mysql_title=$(mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB -N -e "SELECT primaryTitle FROM title_basics WHERE tconst='test004'" 2>/dev/null)
ch_title=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT primaryTitle FROM imdb.title_basics FINAL WHERE tconst='test004'" 2>/dev/null)

echo -n "   Special characters: "
if [ "$mysql_title" = "$ch_title" ]; then
    echo -e "${GREEN}✅ PASS${NC} (title matches)"
    ((test_passed++))
else
    echo -e "${RED}❌ FAIL${NC}"
    echo "     MySQL: $mysql_title"
    echo "     ClickHouse: $ch_title"
    ((test_failed++))
fi

# Test Array (genres)
mysql_genres=$(mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB -N -e "SELECT genres FROM title_basics WHERE tconst='test001'" 2>/dev/null)
ch_genres=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT arrayStringConcat(genres, ',') FROM imdb.title_basics FINAL WHERE tconst='test001'" 2>/dev/null)

echo -n "   Array/genres: MySQL=$mysql_genres, ClickHouse=$ch_genres ... "
if [ "$mysql_genres" = "$ch_genres" ]; then
    echo -e "${GREEN}✅ PASS${NC}"
    ((test_passed++))
else
    echo -e "${RED}❌ FAIL${NC}"
    ((test_failed++))
fi

# Test Empty array
ch_empty=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT length(genres) FROM imdb.title_basics FINAL WHERE tconst='test005'" 2>/dev/null)

echo -n "   Empty array (test005): Length=$ch_empty ... "
if [ "$ch_empty" = "0" ] || [ "$ch_empty" = "1" ]; then  # Empty array or array with one empty string
    echo -e "${GREEN}✅ PASS${NC}"
    ((test_passed++))
else
    echo -e "${RED}❌ FAIL (expected 0 or 1, got $ch_empty)${NC}"
    ((test_failed++))
fi

# Test UInt8 (boolean)
mysql_adult=$(mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB -N -e "SELECT isAdult FROM title_basics WHERE tconst='test003'" 2>/dev/null)
ch_adult=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT isAdult FROM imdb.title_basics FINAL WHERE tconst='test003'" 2>/dev/null)

echo -n "   UInt8/boolean: MySQL=$mysql_adult, ClickHouse=$ch_adult ... "
if [ "$mysql_adult" = "$ch_adult" ]; then
    echo -e "${GREEN}✅ PASS${NC}"
    ((test_passed++))
else
    echo -e "${RED}❌ FAIL${NC}"
    ((test_failed++))
fi

# Test Year ranges
mysql_years=$(mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB -N -e "SELECT startYear, endYear FROM title_basics WHERE tconst='test002'" 2>/dev/null)
ch_years=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT startYear, endYear FROM imdb.title_basics FINAL WHERE tconst='test002' FORMAT TabSeparated" 2>/dev/null)

echo -n "   Year range (test002): MySQL=\"$mysql_years\", ClickHouse=\"$ch_years\" ... "
if [ "$mysql_years" = "$ch_years" ]; then
    echo -e "${GREEN}✅ PASS${NC}"
    ((test_passed++))
else
    echo -e "${RED}❌ FAIL${NC}"
    ((test_failed++))
fi

echo "
📊 Testing name_basics data types..."

# Test year with historical dates
mysql_birth=$(mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB -N -e "SELECT birthYear, deathYear FROM name_basics WHERE nconst='test003'" 2>/dev/null)
ch_birth=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT birthYear, deathYear FROM imdb.name_basics FINAL WHERE nconst='test003' FORMAT TabSeparated" 2>/dev/null)

echo -n "   Historical years: MySQL=\"$mysql_birth\", ClickHouse=\"$ch_birth\" ... "
if [ "$mysql_birth" = "$ch_birth" ]; then
    echo -e "${GREEN}✅ PASS${NC}"
    ((test_passed++))
else
    echo -e "${RED}❌ FAIL${NC}"
    ((test_failed++))
fi

echo "
==========================================
PHASE 5: Detailed Comparison
==========================================
"

echo "📊 Fetching all test records from MySQL..."
echo ""
echo "MySQL title_ratings:"
mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB -e "SELECT * FROM title_ratings WHERE tconst LIKE 'test%' ORDER BY tconst" 2>/dev/null

echo ""
echo "ClickHouse title_ratings:"
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
SELECT tconst, averageRating, numVotes, cdc_operation
FROM imdb.title_ratings FINAL
WHERE tconst LIKE 'test%'
ORDER BY tconst
FORMAT Pretty" 2>/dev/null

echo ""
echo "MySQL title_basics:"
mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB -e "SELECT tconst, titleType, primaryTitle, isAdult, startYear, endYear, runtimeMinutes, genres FROM title_basics WHERE tconst LIKE 'test%' ORDER BY tconst" 2>/dev/null

echo ""
echo "ClickHouse title_basics:"
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
SELECT tconst, titleType, primaryTitle, isAdult, startYear, endYear, runtimeMinutes, arrayStringConcat(genres, ',') as genres, cdc_operation
FROM imdb.title_basics FINAL
WHERE tconst LIKE 'test%'
ORDER BY tconst
FORMAT Pretty" 2>/dev/null

echo "
==========================================
📊 TEST SUMMARY
==========================================
"

echo ""
echo -e "${GREEN}Tests Passed: $test_passed${NC}"
echo -e "${RED}Tests Failed: $test_failed${NC}"
echo ""

if [ $test_failed -eq 0 ]; then
    echo -e "${GREEN}✅ ALL TESTS PASSED!${NC}"
    echo ""
    echo "🎉 CDC pipeline is correctly replicating all data types!"
    exit_code=0
else
    echo -e "${RED}❌ SOME TESTS FAILED${NC}"
    echo ""
    echo "⚠️  Please review the failures above and check:"
    echo "   1. Debezium connector configuration (decimal.handling.mode)"
    echo "   2. ClickHouse table schemas match MySQL"
    echo "   3. Materialized view transformations"
    echo "   4. Data type mappings in CDC pipeline"
    exit_code=1
fi

echo "
==========================================
🧹 CLEANUP
==========================================
"

read -p "Do you want to clean up test data? (yes/no): " cleanup
if [ "$cleanup" = "yes" ]; then
    echo "🧹 Removing test data from MySQL..."
    mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASS $MYSQL_DB <<EOF 2>/dev/null
    DELETE FROM title_ratings WHERE tconst LIKE 'test%';
    DELETE FROM title_basics WHERE tconst LIKE 'test%';
    DELETE FROM name_basics WHERE nconst LIKE 'test%';
EOF
    echo "✅ Test data removed from MySQL"
    echo "ℹ️  ClickHouse records will be marked as deleted via CDC"
else
    echo "ℹ️  Test data preserved for further investigation"
fi

exit $exit_code
