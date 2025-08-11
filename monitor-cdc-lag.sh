#!/bin/bash

echo "🔍 CDC Lag Monitor - Started $(date)"
echo "======================================"
echo ""

# Track metrics over time
start_time=$(date +%s)
previous_lag=0
previous_records=0

while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    
    # Get current lag
    total_lag=$(docker exec redpanda-cdc rpk group describe clickhouse-cdc-group | grep "TOTAL-LAG" | awk '{print $2}')
    
    # Get ClickHouse records
    ch_records=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT count() FROM imdb.title_principals;" 2>/dev/null || echo "0")
    
    # Calculate rates
    if [ $previous_lag -ne 0 ]; then
        lag_change=$((total_lag - previous_lag))
        record_change=$((ch_records - previous_records))
        processing_rate=$((record_change / 30))  # per second over 30s interval
        
        echo "$(date '+%H:%M:%S') | Lag: $total_lag (-$((lag_change * -1))) | Records: $ch_records (+$record_change) | Rate: ${processing_rate}K/sec"
    else
        echo "$(date '+%H:%M:%S') | Lag: $total_lag | Records: $ch_records | Baseline measurement"
    fi
    
    previous_lag=$total_lag
    previous_records=$ch_records
    
    # Exit if lag is under 1M (nearly complete)
    if [ "$total_lag" -lt 1000000 ]; then
        echo ""
        echo "✅ CDC processing nearly complete (lag < 1M messages)"
        echo "🎉 Final status at $(date):"
        echo "   - Total lag: $total_lag messages"
        echo "   - ClickHouse records: $ch_records"
        echo "   - Processing time: $((elapsed / 60)) minutes"
        break
    fi
    
    # Check every 30 seconds
    sleep 30
done

echo ""
echo "📊 Final verification:"
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
SELECT 'title_principals' as table, count() as records FROM imdb.title_principals
UNION ALL SELECT '==== MySQL Source ====', (SELECT COUNT(*) FROM mysql('mysql-cdc:3306', 'imdb', 'title_principals', 'root', 'rootpassword'));
" 2>/dev/null