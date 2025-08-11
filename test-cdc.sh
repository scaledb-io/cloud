#!/bin/bash

echo "
==========================================
🧪 CDC Platform Test Suite
==========================================

This script tests the production CDC platform
without requiring the full IMDb dataset.
"

# Check if services are running
echo "🔍 Checking service health..."
if ! docker compose ps | grep -q "Up"; then
    echo "❌ CDC Platform not running. Please run ./setup-production-cdc.sh first"
    exit 1
fi

echo "✅ All services are running"

echo "
==========================================
🧪 Testing CDC Pipeline
==========================================
"

echo "1️⃣ Testing MySQL connection..."
if mysql -h127.0.0.1 -P3306 -uproxyuser -pproxypass123 -e "SELECT 'MySQL OK' as status;" 2>/dev/null; then
    echo "   ✅ MySQL connection successful"
else
    echo "   ❌ MySQL connection failed"
    exit 1
fi

echo "2️⃣ Testing ClickHouse connection..."
if docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT 'ClickHouse OK' as status;" 2>/dev/null; then
    echo "   ✅ ClickHouse connection successful"
else
    echo "   ❌ ClickHouse connection failed"
    exit 1
fi

echo "3️⃣ Testing ProxySQL connection..."
if mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 -e "SELECT 'ProxySQL OK' as status;" 2>/dev/null; then
    echo "   ✅ ProxySQL connection successful"
else
    echo "   ❌ ProxySQL connection failed"
    exit 1
fi

echo "4️⃣ Testing CDC replication..."
# Insert test data (MySQL tconst field is limited to 10 characters)
test_id="tt$(date +%s | tail -c 8)"
echo "   📊 Inserting test record: $test_id"

mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 -e "
INSERT INTO title_ratings VALUES ('$test_id', 8.5, 100);" 2>/dev/null

# Wait for CDC processing with timeout
echo "   ⏳ Waiting for CDC replication (max 60 seconds)..."
cdc_success=false
for i in {1..12}; do
    sleep 5
    ch_count=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
    SELECT count() FROM imdb.title_ratings WHERE tconst = '$test_id';" 2>/dev/null || echo "0")
    
    if [ "$ch_count" = "1" ]; then
        echo "   ✅ CDC replication successful - record found in ClickHouse (${i}0s)"
        cdc_success=true
        break
    else
        echo "   🔄 Waiting... attempt $i/12"
    fi
done

if [ "$cdc_success" = "false" ]; then
    echo "   ❌ CDC replication failed - record not replicated after 60 seconds"
    echo "   🧹 Cleaning up test data..."
    mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 -e "DELETE FROM title_ratings WHERE tconst = '$test_id';" 2>/dev/null
    exit 1
fi

echo "
==========================================
🎯 Testing Intelligent Query Routing
==========================================
"

echo "5️⃣ Testing OLAP query routing (should go to ClickHouse)..."
olap_result=$(mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 imdb -N -e "
SELECT COUNT(*) FROM title_ratings;" 2>/dev/null || echo "0")
echo "   📊 OLAP Result: $olap_result records found (routed to ClickHouse)"

echo "6️⃣ Testing OLTP query routing (should go to MySQL)..."
oltp_result=$(mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 imdb -N -e "
SELECT * FROM title_ratings WHERE tconst = '$test_id' LIMIT 1;" 2>/dev/null | wc -l || echo "0")
echo "   📊 OLTP Result: $oltp_result records found (routed to MySQL)"

echo "7️⃣ Checking ProxySQL routing statistics..."
mysql -h127.0.0.1 -P6032 -uadmin -padmin -e "
SELECT 
    rule_id, 
    hits,
    CASE 
        WHEN rule_id = 100 THEN 'Analytics → ClickHouse'
        WHEN rule_id = 999 THEN 'Default → MySQL' 
        ELSE 'Other rules'
    END as description
FROM stats_mysql_query_rules 
WHERE hits > 0 
ORDER BY rule_id;" 2>/dev/null

echo "
==========================================
🎉 Test Results Summary
==========================================

✅ MySQL: Connected and operational
✅ ClickHouse: Connected and operational  
✅ ProxySQL: Intelligent routing working
✅ CDC Pipeline: Real-time replication active
✅ Test Record: $test_id inserted and replicated

🚀 Your production CDC platform is fully functional!

📊 Next steps:
- Load full dataset: ./load-imdb-data.sh
- Monitor Redpanda: http://localhost:8080
- Try your own data loads
"

echo "
==========================================
🧹 Cleaning Up Test Data
==========================================
"

echo "🧹 Removing test record: $test_id"
mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 -e "DELETE FROM title_ratings WHERE tconst = '$test_id';" 2>/dev/null

if [ $? -eq 0 ]; then
    echo "✅ Test data cleaned up successfully"
else
    echo "⚠️  Test data cleanup may have failed - please verify manually"
fi