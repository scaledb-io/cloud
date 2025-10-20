#!/bin/bash

echo "
==========================================
📊 IMDb Unified Data Loader with CDC
==========================================

This script loads IMDb datasets in 5M-row chunks to prevent
massive CDC lag spikes. Works for all table sizes.

Prerequisites: Run ./load-imdb-data.sh first to download files
"

# Configuration (can be overridden via environment variables)
CHUNK_SIZE=${CHUNK_SIZE:-5000000}  # 5M rows per chunk by default
WAIT_FOR_CDC=${WAIT_FOR_CDC:-false}  # Wait for CDC to catch up between chunks
LAG_THRESHOLD=${LAG_THRESHOLD:-1000000}  # Max acceptable lag before waiting
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${DATA_DIR:-$SCRIPT_DIR/init.db}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check if services are running
if ! docker compose ps | grep -q "Up"; then
    echo -e "${RED}❌ CDC Platform not running. Please run ./setup-production-cdc.sh first${NC}"
    exit 1
fi

echo -e "${GREEN}✅ CDC Platform is running${NC}"
echo ""

# Configuration summary
echo -e "${BLUE}Configuration:${NC}"
echo "  Chunk size: $(printf "%'.0f" $CHUNK_SIZE) rows"
echo "  Wait for CDC: $WAIT_FOR_CDC"
if [ "$WAIT_FOR_CDC" = "true" ]; then
    echo "  Lag threshold: $(printf "%'.0f" $LAG_THRESHOLD) messages"
fi
echo ""

# Function to get CDC lag for a specific topic
get_cdc_lag() {
    local topic=$1
    lag=$(curl -s http://localhost:8080/api/consumer-groups 2>/dev/null | \
          jq -r ".consumerGroups[0].topicOffsets[] | select(.topic == \"cdc.imdb.$topic\") | .summedLag" 2>/dev/null || echo "0")
    echo "$lag"
}

# Function to wait for CDC lag to drop below threshold
wait_for_cdc_lag() {
    local table=$1
    local max_wait=${2:-300}  # Max 5 minutes wait

    if [ "$WAIT_FOR_CDC" != "true" ]; then
        return 0
    fi

    echo -e "   ${CYAN}⏳ Checking CDC lag for $table...${NC}"

    local waited=0
    while [ $waited -lt $max_wait ]; do
        local lag=$(get_cdc_lag "$table")

        if [ "$lag" = "0" ] || [ -z "$lag" ]; then
            echo -e "   ${GREEN}✅ CDC lag cleared${NC}"
            return 0
        fi

        if [ "$lag" -lt "$LAG_THRESHOLD" ]; then
            echo -e "   ${GREEN}✅ CDC lag acceptable: $(printf "%'.0f" $lag) messages${NC}"
            return 0
        fi

        echo -e "   ${YELLOW}⏳ CDC lag: $(printf "%'.0f" $lag) messages (waiting for < $(printf "%'.0f" $LAG_THRESHOLD))${NC}"
        sleep 5
        waited=$((waited + 5))
    done

    echo -e "   ${YELLOW}⚠️  Timeout waiting for CDC lag to clear (current: $(printf "%'.0f" $lag))${NC}"
    echo -e "   ${YELLOW}⚠️  Continuing anyway...${NC}"
    return 1
}

# Function to check if table has data
check_table_status() {
    local table=$1
    local count=$(docker exec mysql-cdc mysql -u root -prootpassword imdb -N -e "SELECT COUNT(*) FROM $table;" 2>/dev/null || echo "0")
    echo "$count"
}

# Function to split a file into chunks
split_file() {
    local file=$1
    local table=$2
    local total_lines=$3

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}📂 Splitting $file${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    local num_chunks=$(( (total_lines + CHUNK_SIZE - 1) / CHUNK_SIZE ))
    echo "   Total lines: $(printf "%'.0f" $total_lines)"
    echo "   Chunk size: $(printf "%'.0f" $CHUNK_SIZE) lines"
    echo "   Number of chunks: $num_chunks"
    echo ""

    # Check if chunks already exist
    if ls ${table}_chunk_*.tsv 1> /dev/null 2>&1; then
        echo -e "   ${YELLOW}⚠️  Chunks already exist. Skipping split.${NC}"
        echo -e "   ${YELLOW}💡 Delete ${table}_chunk_*.tsv to re-split${NC}"
        return 0
    fi

    echo "   🔪 Splitting file (this may take a few minutes)..."

    # Extract header
    head -n 1 "$file" > "${table}_header.tsv"

    # Split the file (excluding header) - macOS compatible syntax
    tail -n +2 "$file" | split -l $CHUNK_SIZE -a 3 - "${table}_chunk_"

    # Rename chunks to add .tsv extension and add header
    for chunk in ${table}_chunk_*; do
        if [ -f "$chunk" ]; then
            cat "${table}_header.tsv" "$chunk" > "${chunk}.tsv"
            rm "$chunk"
        fi
    done

    # Clean up header file
    rm "${table}_header.tsv"

    local actual_chunks=$(ls ${table}_chunk_*.tsv 2>/dev/null | wc -l | tr -d ' ')
    echo -e "   ${GREEN}✅ Created $actual_chunks chunks${NC}"
    echo ""
}

# Function to load a single chunk
load_chunk() {
    local table=$1
    local chunk_file=$2
    local chunk_num=$3
    local total_chunks=$4
    local total_records=$5

    local records_so_far=$(( (chunk_num - 1) * CHUNK_SIZE ))
    local percentage=0
    if [ $total_records -gt 0 ]; then
        percentage=$(( records_so_far * 100 / total_records ))
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}📤 Loading chunk $chunk_num/$total_chunks ($percentage% complete)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "   Table: $table"
    echo "   File: $chunk_file"
    echo "   Progress: $(printf "%'.0f" $records_so_far) / $(printf "%'.0f" $total_records) records"
    echo ""

    # Load chunk into MySQL
    local start_time=$(date +%s)

    docker exec mysql-cdc mysql -u root -prootpassword imdb -e "
    LOAD DATA INFILE '/imdb-data/$chunk_file'
    INTO TABLE $table
    FIELDS TERMINATED BY '\t'
    LINES TERMINATED BY '\n'
    IGNORE 1 ROWS;" 2>&1 | grep -v "Warning: Using a password on the command line"

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo -e "   ${RED}❌ Failed to load chunk${NC}"
        return 1
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Get current MySQL count
    mysql_count=$(docker exec mysql-cdc mysql -u root -prootpassword imdb -N -e "SELECT COUNT(*) FROM $table;" 2>/dev/null)

    echo -e "   ${GREEN}✅ Chunk loaded in ${duration}s${NC}"
    echo -e "   ${GREEN}📊 MySQL now has $(printf "%'.0f" $mysql_count) records${NC}"

    # Wait for CDC if configured
    wait_for_cdc_lag "$table"

    echo ""
}

# Function to load table in chunks
load_table_chunked() {
    local table=$1
    local file=$2
    local file_path="$DATA_DIR/$file"

    # Check if file exists
    if [ ! -f "$file_path" ]; then
        echo -e "${RED}❌ File not found: $file_path${NC}"
        echo -e "${YELLOW}💡 Run ./load-imdb-data.sh first to download files${NC}"
        return 1
    fi

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}🚀 Loading $table${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo ""

    cd "$DATA_DIR"

    # Get actual line count
    local total_lines=$(wc -l < "$file")
    local data_lines=$((total_lines - 1))  # Exclude header

    echo "   File: $file"
    echo "   Total lines: $(printf "%'.0f" $total_lines) (including header)"
    echo "   Data rows: $(printf "%'.0f" $data_lines)"
    echo ""

    # Split file
    split_file "$file" "$table" "$total_lines"

    # Count chunks
    local chunks=(${table}_chunk_*.tsv)
    local total_chunks=${#chunks[@]}

    if [ $total_chunks -eq 0 ]; then
        echo -e "${RED}❌ No chunks found for $table${NC}"
        cd - > /dev/null
        return 1
    fi

    echo -e "${BLUE}📊 Loading $total_chunks chunks...${NC}"
    echo ""

    # Load each chunk
    local chunk_num=1
    local overall_start=$(date +%s)

    for chunk in "${chunks[@]}"; do
        load_chunk "$table" "$chunk" "$chunk_num" "$total_chunks" "$data_lines"
        if [ $? -ne 0 ]; then
            echo -e "${RED}❌ Failed to load $chunk${NC}"
            cd - > /dev/null
            return 1
        fi
        chunk_num=$((chunk_num + 1))
    done

    local overall_end=$(date +%s)
    local overall_duration=$((overall_end - overall_start))
    local minutes=$((overall_duration / 60))
    local seconds=$((overall_duration % 60))

    # Get final counts
    mysql_final=$(docker exec mysql-cdc mysql -u root -prootpassword imdb -N -e "SELECT COUNT(*) FROM $table;" 2>/dev/null)

    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${GREEN}✅ $table complete!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════${NC}"
    echo "   Total time: ${minutes}m ${seconds}s"
    echo "   MySQL records: $(printf "%'.0f" $mysql_final)"
    echo ""

    # Final CDC lag check
    echo "   🔍 Checking final CDC lag..."
    local final_lag=$(get_cdc_lag "$table")
    if [ "$final_lag" = "0" ] || [ -z "$final_lag" ]; then
        echo -e "   ${GREEN}✅ CDC fully replicated${NC}"
    else
        echo -e "   ${YELLOW}⏳ CDC lag: $(printf "%'.0f" $final_lag) messages (replicating in background)${NC}"
    fi

    cd - > /dev/null
    echo ""
}

# Check current table status
echo "
==========================================
📊 Current Database Status
==========================================
"

# Define tables and files (parallel arrays)
ALL_TABLES=("title_ratings" "title_basics" "name_basics" "title_crew" "title_episode" "title_akas" "title_principals")
ALL_FILES=("title.ratings.tsv" "title.basics.tsv" "name.basics.tsv" "title.crew.tsv" "title.episode.tsv" "title.akas.tsv" "title.principals.tsv")

echo -e "${BLUE}Checking existing data...${NC}"
echo ""

printf "%-20s %-15s %-10s\n" "Table" "Records" "Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for table in "${ALL_TABLES[@]}"; do
    count=$(check_table_status "$table")
    if [ "$count" = "0" ]; then
        status="${YELLOW}Not loaded${NC}"
    else
        status="${GREEN}Loaded${NC}"
    fi
    printf "%-20s %-15s " "$table" "$(printf "%'.0f" $count)"
    echo -e "$status"
done

echo ""

# Menu for loading
echo "
==========================================
📋 Select Tables to Load
==========================================

1. title_ratings (1.6M records, 1 chunk)
2. title_episode (9.2M records, 2 chunks)
3. title_crew (12M records, 3 chunks)
4. title_basics (12M records, 3 chunks)
5. name_basics (14.8M records, 3 chunks)
6. title_akas (53.5M records, 11 chunks)
7. title_principals (95.3M records, 19 chunks)
8. All unloaded tables
9. All tables (reload everything)

Enter your choice (1-9):
"

read -p "> " choice

case $choice in
    1)
        load_table_chunked "title_ratings" "title.ratings.tsv"
        ;;
    2)
        load_table_chunked "title_episode" "title.episode.tsv"
        ;;
    3)
        load_table_chunked "title_crew" "title.crew.tsv"
        ;;
    4)
        load_table_chunked "title_basics" "title.basics.tsv"
        ;;
    5)
        load_table_chunked "name_basics" "name.basics.tsv"
        ;;
    6)
        load_table_chunked "title_akas" "title.akas.tsv"
        ;;
    7)
        load_table_chunked "title_principals" "title.principals.tsv"
        ;;
    8)
        # Load only unloaded tables
        for i in "${!ALL_TABLES[@]}"; do
            table="${ALL_TABLES[$i]}"
            file="${ALL_FILES[$i]}"
            count=$(check_table_status "$table")
            if [ "$count" = "0" ]; then
                load_table_chunked "$table" "$file"
            else
                echo -e "${YELLOW}⏭️  Skipping $table (already has $(printf "%'.0f" $count) records)${NC}"
            fi
        done
        ;;
    9)
        # Load all tables
        load_table_chunked "title_ratings" "title.ratings.tsv"
        load_table_chunked "title_episode" "title.episode.tsv"
        load_table_chunked "title_crew" "title.crew.tsv"
        load_table_chunked "title_basics" "title.basics.tsv"
        load_table_chunked "name_basics" "name.basics.tsv"
        load_table_chunked "title_akas" "title.akas.tsv"
        load_table_chunked "title_principals" "title.principals.tsv"
        ;;
    *)
        echo -e "${RED}Invalid choice${NC}"
        exit 1
        ;;
esac

echo "
==========================================
🎉 Loading Complete!
==========================================
"

# Show final summary
echo "📊 Final MySQL record counts:"
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
echo "💡 Monitor CDC replication:"
echo "   ./monitor-cdc-lag.sh"
echo ""
echo "🧹 To remove chunk files and save space:"
echo "   cd $DATA_DIR && rm *_chunk_*.tsv"
echo ""
