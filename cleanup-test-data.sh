#!/bin/bash

echo "
==========================================
🧹 Test Data Cleanup Script
==========================================

This script provides a clean slate for testing by:
- Pausing CDC connectors
- Truncating all test tables in MySQL and ClickHouse
- Resuming CDC connectors
- Verifying cleanup completed

⚠️  WARNING: This will delete ALL data from test tables!
"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
FORCE=false
RESET_KAFKA=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE=true
            shift
            ;;
        --reset-kafka)
            RESET_KAFKA=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--force] [--reset-kafka]"
            exit 1
            ;;
    esac
done

# Check if services are running
if ! docker compose ps | grep -q "Up"; then
    echo -e "${RED}❌ CDC Platform not running${NC}"
    exit 1
fi

echo -e "${GREEN}✅ CDC Platform is running${NC}"
echo ""

# Tables to clean
TABLES=("title_ratings" "title_basics" "name_basics" "title_crew" "title_episode" "title_akas" "title_principals")

echo "
==========================================
📊 Current Data Status
==========================================
"

echo "MySQL record counts:"
for table in "${TABLES[@]}"; do
    count=$(docker exec mysql-cdc mysql -u root -prootpassword imdb -N -e "SELECT COUNT(*) FROM $table;" 2>/dev/null || echo "0")
    printf "  %-20s %10s rows\n" "$table" "$count"
done

echo ""
echo "ClickHouse record counts (active data):"
for table in "${TABLES[@]}"; do
    # Try active view first, fall back to main table
    count=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
    SELECT count() FROM imdb.${table}_active;" 2>/dev/null || \
    docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
    SELECT count() FROM imdb.$table;" 2>/dev/null || echo "0")
    printf "  %-20s %10s rows\n" "$table" "$count"
done

echo ""

# Confirmation
if [ "$FORCE" = false ]; then
    read -p "⚠️  Proceed with cleanup? This will delete ALL data! (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}❌ Cleanup cancelled${NC}"
        exit 0
    fi
fi

echo ""
echo -e "${BLUE}Starting cleanup process...${NC}"

# Step 1: Pause CDC connectors
echo "
==========================================
STEP 1: Pausing CDC Connectors
==========================================
"

echo "📊 Getting list of connectors..."
connectors=$(curl -s http://localhost:8083/connectors 2>/dev/null | grep -o '"[^"]*"' | tr -d '"')

if [ -z "$connectors" ]; then
    echo -e "${YELLOW}⚠️  No connectors found${NC}"
else
    echo "Found connectors:"
    echo "$connectors" | sed 's/^/  - /'
    echo ""

    for connector in $connectors; do
        echo "  ⏸️  Pausing $connector..."
        curl -s -X PUT http://localhost:8083/connectors/$connector/pause 2>/dev/null > /dev/null

        # Verify paused
        status=$(curl -s http://localhost:8083/connectors/$connector/status 2>/dev/null | grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ "$status" = "PAUSED" ]; then
            echo -e "     ${GREEN}✅ Paused${NC}"
        else
            echo -e "     ${YELLOW}⚠️  Status: $status${NC}"
        fi
    done
fi

echo ""
echo "⏳ Waiting 5 seconds for in-flight messages to process..."
sleep 5

# Step 2: Truncate MySQL tables
echo "
==========================================
STEP 2: Truncating MySQL Tables
==========================================
"

for table in "${TABLES[@]}"; do
    echo "  🗑️  Truncating $table..."
    docker exec mysql-cdc mysql -u root -prootpassword imdb -e "TRUNCATE TABLE $table;" 2>/dev/null

    if [ $? -eq 0 ]; then
        count=$(docker exec mysql-cdc mysql -u root -prootpassword imdb -N -e "SELECT COUNT(*) FROM $table;" 2>/dev/null)
        if [ "$count" = "0" ]; then
            echo -e "     ${GREEN}✅ Truncated (0 rows)${NC}"
        else
            echo -e "     ${YELLOW}⚠️  Still has $count rows${NC}"
        fi
    else
        echo -e "     ${RED}❌ Failed to truncate${NC}"
    fi
done

# Step 3: Truncate ClickHouse tables
echo "
==========================================
STEP 3: Truncating ClickHouse Tables
==========================================
"

for table in "${TABLES[@]}"; do
    echo "  🗑️  Truncating $table..."
    docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "TRUNCATE TABLE imdb.$table;" 2>/dev/null

    if [ $? -eq 0 ]; then
        count=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT count() FROM imdb.$table;" 2>/dev/null)
        if [ "$count" = "0" ]; then
            echo -e "     ${GREEN}✅ Truncated (0 rows)${NC}"
        else
            echo -e "     ${YELLOW}⚠️  Still has $count rows${NC}"
        fi
    else
        echo -e "     ${RED}❌ Failed to truncate${NC}"
    fi
done

# Step 4: Reset Kafka offsets (optional)
if [ "$RESET_KAFKA" = true ]; then
    echo "
==========================================
STEP 4: Resetting Kafka Consumer Offsets
==========================================
"

    echo "  🔄 Resetting consumer group offsets..."

    # Get list of topics
    topics=$(docker exec redpanda-cdc rpk topic list 2>/dev/null | grep "cdc.imdb" | awk '{print $1}')

    for topic in $topics; do
        echo "     Resetting offset for $topic..."
        docker exec redpanda-cdc rpk group seek clickhouse-cdc-group --to start --topics $topic 2>/dev/null
    done

    echo -e "  ${GREEN}✅ Kafka offsets reset${NC}"
fi

# Step 5: Resume CDC connectors
echo "
==========================================
STEP 5: Resuming CDC Connectors
==========================================
"

if [ -n "$connectors" ]; then
    for connector in $connectors; do
        echo "  ▶️  Resuming $connector..."
        curl -s -X PUT http://localhost:8083/connectors/$connector/resume 2>/dev/null > /dev/null

        # Give it a moment to start
        sleep 2

        # Verify running
        status=$(curl -s http://localhost:8083/connectors/$connector/status 2>/dev/null | grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4)
        if [ "$status" = "RUNNING" ]; then
            echo -e "     ${GREEN}✅ Running${NC}"
        else
            echo -e "     ${YELLOW}⚠️  Status: $status${NC}"
        fi
    done
fi

# Step 6: Verification
echo "
==========================================
STEP 6: Verification
==========================================
"

echo ""
echo "Final data counts:"
echo ""

mysql_total=0
ch_total=0
all_clean=true

for table in "${TABLES[@]}"; do
    mysql_count=$(docker exec mysql-cdc mysql -u root -prootpassword imdb -N -e "SELECT COUNT(*) FROM $table;" 2>/dev/null || echo "0")
    ch_count=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT count() FROM imdb.$table;" 2>/dev/null || echo "0")

    mysql_total=$((mysql_total + mysql_count))
    ch_total=$((ch_total + ch_count))

    status="✅"
    if [ "$mysql_count" != "0" ] || [ "$ch_count" != "0" ]; then
        status="⚠️ "
        all_clean=false
    fi

    printf "  %-20s MySQL: %5s  ClickHouse: %5s  %s\n" "$table" "$mysql_count" "$ch_count" "$status"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  %-20s MySQL: %5s  ClickHouse: %5s\n" "TOTAL" "$mysql_total" "$ch_total"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
if [ "$all_clean" = true ]; then
    echo -e "${GREEN}✅ SUCCESS! All tables cleaned${NC}"
    echo ""
    echo "🎉 Ready for fresh test run!"
    exit 0
else
    echo -e "${YELLOW}⚠️  Some tables still have data${NC}"
    echo ""
    echo "💡 You may need to:"
    echo "   • Wait a moment and check again"
    echo "   • Check for errors above"
    echo "   • Run with --reset-kafka flag"
    exit 1
fi
