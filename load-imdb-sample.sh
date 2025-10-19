#!/bin/bash

echo "
==========================================
📊 IMDb Sample Dataset Loader with Validation
==========================================

This script loads a SAMPLE of IMDb data for testing:
- Selectable tables
- Configurable row limits (default: 100K per table)
- Full validation of data replication
- Much faster than full load (~5-10 minutes vs 30-60 minutes)
"

# Default configuration
DEFAULT_ROW_LIMIT=100000
ROW_LIMIT=${ROW_LIMIT:-$DEFAULT_ROW_LIMIT}

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if services are running
if ! docker compose ps | grep -q "Up"; then
    echo -e "${RED}❌ CDC Platform not running. Please run ./setup-production-cdc.sh first${NC}"
    exit 1
fi

echo -e "${GREEN}✅ CDC Platform detected as running${NC}"

echo "
==========================================
📋 Select Tables to Load
==========================================
"

echo "Available tables:"
echo "1. title_ratings (1.6M rows) - ⭐ Recommended for testing"
echo "2. title_basics (11M rows) - Movie/TV metadata"
echo "3. name_basics (14M rows) - People data"
echo "4. title_crew (11M rows) - Directors/writers"
echo "5. title_episode (8M rows) - Episode info"
echo ""

read -p "Enter table number to load (1-5): " selection

# Parse selection
case $selection in
    1)
        TABLE="title_ratings"
        FILE="title.ratings.tsv.gz"
        ;;
    2)
        TABLE="title_basics"
        FILE="title.basics.tsv.gz"
        ;;
    3)
        TABLE="name_basics"
        FILE="name.basics.tsv.gz"
        ;;
    4)
        TABLE="title_crew"
        FILE="title.crew.tsv.gz"
        ;;
    5)
        TABLE="title_episode"
        FILE="title.episode.tsv.gz"
        ;;
    *)
        echo -e "${RED}Invalid choice${NC}"
        exit 1
        ;;
esac

echo ""
read -p "How many rows? (default: $DEFAULT_ROW_LIMIT): " input_limit
ROW_LIMIT=${input_limit:-$DEFAULT_ROW_LIMIT}

echo ""
echo -e "${BLUE}Selected: $TABLE${NC}"
echo -e "${BLUE}Row limit: $ROW_LIMIT${NC}"
echo ""

read -p "Proceed? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "❌ Cancelled"
    exit 0
fi

echo "
==========================================
📥 Downloading IMDb Dataset
==========================================
"

mkdir -p ../init.db
cd ../init.db

if [ ! -f "$FILE" ]; then
    echo "  📥 Downloading $FILE..."
    curl -# -O "https://datasets.imdbws.com/$FILE"
else
    echo "  ✅ $FILE already exists"
fi

TSV_FILE="${FILE%.gz}"
if [ ! -f "$TSV_FILE" ]; then
    echo "🔄 Extracting..."
    gunzip -k "$FILE"
fi

echo "
==========================================
📤 Loading Sample Data
==========================================
"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}📊 Processing: $TABLE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Create sample file
SAMPLE_FILE="${TSV_FILE%.tsv}_sample_${ROW_LIMIT}.tsv"
echo "   📝 Creating sample file (first $ROW_LIMIT rows)..."
head -n $((ROW_LIMIT + 1)) "$TSV_FILE" > "$SAMPLE_FILE"

actual_rows=$(($(wc -l < "$SAMPLE_FILE") - 1))
echo "   ✅ Sample file ready: $actual_rows rows"

# Clear existing data
echo "   🧹 Clearing existing data from $TABLE..."
docker exec mysql-cdc mysql -u root -prootpassword imdb -e "DELETE FROM $TABLE;" 2>/dev/null
sleep 2

# Load into MySQL
echo "   📤 Loading into MySQL..."
start_time=$(date +%s)

docker exec mysql-cdc mysql -u root -prootpassword imdb -e "
LOAD DATA INFILE '/imdb-data/$SAMPLE_FILE'
INTO TABLE $TABLE
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS;" 2>&1

load_result=$?
end_time=$(date +%s)
duration=$((end_time - start_time))

if [ $load_result -ne 0 ]; then
    echo -e "   ${RED}❌ Failed to load data into MySQL${NC}"
    echo ""
    echo "Troubleshooting:"
    echo "  • Check if file exists: ls -la ../init.db/$SAMPLE_FILE"
    echo "  • Check MySQL permissions"
    echo "  • Try with fewer rows: ROW_LIMIT=1000 ./load-imdb-sample.sh"
    cd - > /dev/null
    exit 1
fi

# Get MySQL count
mysql_count=$(docker exec mysql-cdc mysql -u root -prootpassword imdb -N -e "SELECT COUNT(*) FROM $TABLE;" 2>/dev/null)
echo -e "   ${GREEN}✅ MySQL loaded: $mysql_count records in ${duration}s${NC}"

# Wait for CDC replication
echo "   ⏳ Waiting for CDC replication..."
cdc_success=false
for i in {1..12}; do
    sleep 5

    # Check ClickHouse count (use active view if available)
    ch_count=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
    SELECT count() FROM imdb.${TABLE}_active WHERE 1=1;" 2>/dev/null || \
    docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
    SELECT count() FROM imdb.$TABLE;" 2>/dev/null)

    if [ -n "$mysql_count" ] && [ "$mysql_count" -gt 0 ]; then
        percentage=$((ch_count * 100 / mysql_count))
        echo "      🔄 Attempt $i/12: ClickHouse has $ch_count/$mysql_count records ($percentage%)"

        if [ "$ch_count" -ge "$mysql_count" ]; then
            echo -e "   ${GREEN}✅ CDC replicated: $ch_count records${NC}"
            cdc_success=true
            break
        fi
    else
        echo "      🔄 Attempt $i/12: ClickHouse has $ch_count records"
    fi
done

if [ "$cdc_success" = "false" ]; then
    echo -e "   ${YELLOW}⚠️  CDC may still be processing ($ch_count/$mysql_count replicated)${NC}"
fi

echo "
==========================================
📊 Validation Results
==========================================
"

echo ""
echo -e "${BLUE}Record Counts:${NC}"
printf "%-20s MySQL: %10s  ClickHouse: %10s" "$TABLE" "$mysql_count" "$ch_count"

if [ "$mysql_count" -eq "$ch_count" ]; then
    echo -e "  ${GREEN}✅ MATCH${NC}"
    echo ""
    echo -e "${GREEN}✅ SUCCESS! All records replicated correctly via CDC${NC}"
else
    echo -e "  ${YELLOW}⚠️  MISMATCH${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  Counts don't match - CDC may still be processing${NC}"
fi

echo ""
echo "Sample data from MySQL:"
docker exec mysql-cdc mysql -u root -prootpassword imdb -e "SELECT * FROM $TABLE LIMIT 3;" 2>/dev/null

echo ""
echo "Sample data from ClickHouse:"
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
SELECT * FROM imdb.$TABLE FINAL LIMIT 3 FORMAT Pretty;" 2>/dev/null

echo "
==========================================
🎯 Next Steps
==========================================

• Test queries: mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 imdb -e \"SELECT COUNT(*) FROM $TABLE;\"
• Run full tests: ./test-cdc.sh
• Load more data: ROW_LIMIT=500000 ./load-imdb-sample.sh
• Clean up: We'll create a cleanup script next!
"

cd - > /dev/null
