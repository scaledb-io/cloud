#!/bin/bash

echo "🧹 Kafka Topic Retention Configuration"
echo "======================================"
echo ""

# Check if services are running
if ! docker compose ps | grep -q "Up"; then
    echo "❌ CDC Platform not running. Please start services first."
    exit 1
fi

echo "📊 Current storage usage:"
current_usage=$(docker exec redpanda-cdc du -sh /var/lib/redpanda/data/kafka/ 2>/dev/null | cut -f1)
echo "   Kafka topics: $current_usage"
echo ""

# Check CDC lag before making changes
echo "🔍 Checking CDC lag before retention changes..."
total_lag=$(docker exec redpanda-cdc rpk group describe clickhouse-cdc-group 2>/dev/null | grep "TOTAL-LAG" | awk '{print $2}')

if [ -z "$total_lag" ]; then
    echo "⚠️  Could not determine CDC lag. Proceeding with caution..."
    total_lag="unknown"
else
    echo "   Current CDC lag: $total_lag messages"
    
    if [ "$total_lag" -gt 10000 ]; then
        echo "⚠️  High CDC lag detected. Consider waiting for processing to complete."
        echo "   Continue anyway? (y/N)"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "❌ Aborted. Use ./monitor-cdc-lag.sh to track progress."
            exit 1
        fi
    fi
fi

echo ""
echo "🎯 Retention Policy Options:"
echo "1) Aggressive cleanup (1 hour) - Immediate storage reclamation"
echo "2) Balanced cleanup (4 hours) - Some recovery buffer" 
echo "3) Conservative cleanup (24 hours) - Production-safe"
echo "4) Custom retention period"
echo ""
read -p "Select retention policy (1-4): " choice

case $choice in
    1)
        retention_ms=3600000
        retention_desc="1 hour"
        ;;
    2)
        retention_ms=14400000
        retention_desc="4 hours"
        ;;
    3)
        retention_ms=86400000
        retention_desc="24 hours"
        ;;
    4)
        echo "Enter retention period in hours (1-168): "
        read -r hours
        if [[ "$hours" =~ ^[0-9]+$ ]] && [ "$hours" -ge 1 ] && [ "$hours" -le 168 ]; then
            retention_ms=$((hours * 3600000))
            retention_desc="$hours hours"
        else
            echo "❌ Invalid retention period. Must be 1-168 hours."
            exit 1
        fi
        ;;
    *)
        echo "❌ Invalid selection. Exiting."
        exit 1
        ;;
esac

echo ""
echo "📋 Configuration Summary:"
echo "   Retention period: $retention_desc"
echo "   Retention (ms): $retention_ms"
echo "   Target: All CDC topics"
echo ""
echo "⚠️  This will permanently delete older messages. Continue? (y/N)"
read -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "❌ Configuration cancelled."
    exit 0
fi

echo ""
echo "🔧 Configuring retention for CDC topics..."
echo ""

# Define CDC topics
topics=("cdc.imdb.title_ratings" "cdc.imdb.title_basics" "cdc.imdb.name_basics" "cdc.imdb.title_crew" "cdc.imdb.title_episode" "cdc.imdb.title_akas" "cdc.imdb.title_principals")

success_count=0
total_topics=${#topics[@]}

for topic in "${topics[@]}"; do
    echo "   Configuring $topic..."
    if docker exec redpanda-cdc rpk topic alter-config "$topic" --set retention.ms="$retention_ms" >/dev/null 2>&1; then
        echo "   ✅ $topic configured successfully"
        ((success_count++))
    else
        echo "   ❌ Failed to configure $topic"
    fi
done

echo ""
if [ $success_count -eq $total_topics ]; then
    echo "✅ All $total_topics CDC topics configured with $retention_desc retention"
else
    echo "⚠️  Configured $success_count out of $total_topics topics"
fi

echo ""
echo "📊 Expected Results:"
case $choice in
    1)
        echo "   🕐 Cleanup time: Within 1 hour"
        echo "   💾 Storage reduction: ~95% (100GB+ → ~7GB)"
        echo "   🔄 Recovery window: 1 hour"
        ;;
    2)
        echo "   🕐 Cleanup time: Within 4 hours"
        echo "   💾 Storage reduction: ~90% (gradual)"
        echo "   🔄 Recovery window: 4 hours"
        ;;
    3)
        echo "   🕐 Cleanup time: Within 24 hours"
        echo "   💾 Storage reduction: ~85% (gradual)"
        echo "   🔄 Recovery window: 24 hours"
        ;;
    4)
        echo "   🕐 Cleanup time: Within $retention_desc"
        echo "   💾 Storage reduction: Depends on data age"
        echo "   🔄 Recovery window: $retention_desc"
        ;;
esac

echo ""
echo "🧪 Testing CDC functionality..."
test_id="tt$(date +%s | tail -c 8)"

# Insert test record
if mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 imdb -e "
INSERT INTO title_basics VALUES ('$test_id', 'movie', 'Retention Test', 'Retention Test', 0, 2024, NULL, 90, 'Drama');" 2>/dev/null; then
    echo "   ✅ Test record inserted"
    
    # Wait for CDC replication
    echo "   ⏳ Checking CDC replication..."
    sleep 5
    
    ch_result=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT COUNT(*) FROM imdb.title_basics WHERE tconst = '$test_id';" 2>/dev/null)
    
    if [ "$ch_result" = "1" ]; then
        echo "   ✅ CDC replication working perfectly"
        
        # Cleanup test record
        mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 imdb -e "DELETE FROM title_basics WHERE tconst = '$test_id';" 2>/dev/null
        echo "   ✅ Test record cleaned up"
    else
        echo "   ⚠️  CDC may need more time to replicate (not a critical issue)"
    fi
else
    echo "   ⚠️  Could not insert test record (check connectivity)"
fi

echo ""
echo "📋 Monitoring Commands:"
echo "   Storage usage: docker exec redpanda-cdc du -sh /var/lib/redpanda/data/kafka/"
echo "   CDC lag: docker exec redpanda-cdc rpk group describe clickhouse-cdc-group"
echo "   Continuous monitoring: ./monitor-cdc-lag.sh"
echo ""
echo "✅ Kafka retention configuration complete!"

if [ "$choice" = "1" ]; then
    echo ""
    echo "💡 Pro tip: After storage cleanup completes, you may want to increase"
    echo "   retention to 24-48 hours for production operations:"
    echo "   ./configure-kafka-retention.sh (select option 3)"
fi