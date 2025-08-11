# Kafka Topic Retention Management

This document covers Kafka topic retention policies for the production CDC platform, including cleanup of initial bulk loads and ongoing operational settings.

## 🎯 Overview

After initial data loading (194M+ records), Kafka topics can accumulate significant storage (100GB+) that's no longer needed for ongoing CDC operations. This guide covers retention management strategies.

## 📊 Initial Load Storage Impact

### Observed Storage Growth
- **Pre-load**: ~5GB baseline topic storage
- **During 94M record transaction**: Storage doubled (53GB → 102GB)
- **Post-load total**: 102GB across all CDC topics
- **Ongoing changes**: <100MB per day typical

### Topic Breakdown (Post Initial Load)
```bash
# Check current storage usage
docker exec redpanda-cdc du -sh /var/lib/redpanda/data/kafka/
# Result: 102G

# List CDC topics
docker exec redpanda-cdc rpk topic list | grep "cdc.imdb"
```

## 🧹 Retention Configuration Strategies

### Strategy 1: Immediate Cleanup (Recommended for Development)
**Use Case**: After successful initial load, clean up immediately to reclaim storage.

```bash
# Set 1-hour retention for immediate cleanup
topics=("cdc.imdb.title_ratings" "cdc.imdb.title_basics" "cdc.imdb.name_basics" "cdc.imdb.title_crew" "cdc.imdb.title_episode" "cdc.imdb.title_akas" "cdc.imdb.title_principals")

for topic in "${topics[@]}"; do
    docker exec redpanda-cdc rpk topic alter-config "$topic" --set retention.ms=3600000
done
```

**Results**:
- Storage reduction: 102GB → ~7GB (95% reduction)
- Cleanup time: Within 1 hour
- CDC functionality: Fully preserved

### Strategy 2: Staged Cleanup (Recommended for Production)
**Use Case**: Production environments needing recovery buffer.

```bash
# Phase 1: Short retention for cleanup (4 hours)
for topic in "${topics[@]}"; do
    docker exec redpanda-cdc rpk topic alter-config "$topic" --set retention.ms=14400000
done

# Phase 2: After cleanup, set production retention (24 hours)
for topic in "${topics[@]}"; do
    docker exec redpanda-cdc rpk topic alter-config "$topic" --set retention.ms=86400000
done
```

### Strategy 3: Selective Retention (Large Tables Only)
**Use Case**: Clean up only the largest topics causing storage issues.

```bash
# Target only the largest tables
large_tables=("cdc.imdb.title_principals" "cdc.imdb.title_akas" "cdc.imdb.title_basics")

for topic in "${large_tables[@]}"; do
    docker exec redpanda-cdc rpk topic alter-config "$topic" --set retention.ms=3600000
done
```

## ⚙️ Production Retention Policies

### Recommended Settings by Environment

#### Development/Testing
```bash
# Short retention for rapid iteration
retention.ms=3600000    # 1 hour
```

#### Staging
```bash
# Balance between storage and recovery time
retention.ms=14400000   # 4 hours  
```

#### Production
```bash
# Sufficient for most recovery scenarios
retention.ms=86400000   # 24 hours

# High-availability environments
retention.ms=604800000  # 7 days
```

### Retention Configuration Commands

```bash
# Check current retention settings
docker exec redpanda-cdc rpk topic describe cdc.imdb.title_principals | grep retention

# Set retention for specific topic
docker exec redpanda-cdc rpk topic alter-config TOPIC_NAME --set retention.ms=VALUE

# Set retention for all CDC topics
topics=($(docker exec redpanda-cdc rpk topic list | grep "cdc.imdb" | awk '{print $1}'))
for topic in "${topics[@]}"; do
    docker exec redpanda-cdc rpk topic alter-config "$topic" --set retention.ms=86400000
done
```

## 🧪 Testing CDC After Retention Changes

Always verify CDC functionality after changing retention settings:

```bash
# Test script
test_id="tt$(date +%s | tail -c 8)"

# Insert test record
mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 imdb -e "
INSERT INTO title_basics VALUES ('$test_id', 'movie', 'Retention Test', 'Test', 0, 2024, NULL, 90, 'Drama');"

# Wait for CDC replication
sleep 5

# Verify replication to ClickHouse
ch_result=$(docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
SELECT COUNT(*) FROM imdb.title_basics WHERE tconst = '$test_id';")

if [ "$ch_result" = "1" ]; then
    echo "✅ CDC working after retention change"
else
    echo "❌ CDC may have issues"
fi

# Cleanup test record
mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 imdb -e "
DELETE FROM title_basics WHERE tconst = '$test_id';"
```

## 📈 Monitoring Retention Impact

### Storage Monitoring
```bash
# Check topic storage usage
docker exec redpanda-cdc du -sh /var/lib/redpanda/data/kafka/

# Monitor cleanup progress
watch "docker exec redpanda-cdc du -sh /var/lib/redpanda/data/kafka/"

# Check specific topic sizes (if available)
docker exec redpanda-cdc find /var/lib/redpanda/data/kafka -name "*title_principals*" -type d -exec du -sh {} \;
```

### CDC Lag Monitoring
```bash
# Check consumer group lag during retention cleanup
docker exec redpanda-cdc rpk group describe clickhouse-cdc-group

# Monitor for any lag spikes during cleanup
./monitor-cdc-lag.sh
```

## ⚠️ Important Considerations

### Data Safety
- **Backup Critical Data**: Ensure all data is replicated to ClickHouse before aggressive retention
- **Verify Replication**: Check that CDC lag is minimal (< 1000 messages) before cleanup
- **Test Recovery**: Verify you can restore from ClickHouse if needed

### Performance Impact
- **Cleanup Process**: Storage cleanup may cause temporary I/O spikes
- **Concurrent Operations**: Monitor system performance during cleanup
- **Network Traffic**: Large cleanups may generate network activity

### Recovery Scenarios
```bash
# If CDC breaks after retention changes, check:
1. Connector status: curl -s http://localhost:8083/connectors/CONNECTOR_NAME/status
2. ClickHouse consumers: SELECT * FROM system.processes WHERE query LIKE '%Kafka%'
3. Topic availability: docker exec redpanda-cdc rpk topic list
4. Consumer group health: docker exec redpanda-cdc rpk group describe clickhouse-cdc-group
```

## 🎯 Best Practices Summary

### Initial Load Cleanup
1. ✅ Verify CDC processing is complete (lag < 1000)
2. ✅ Test CDC with small transaction before bulk cleanup  
3. ✅ Set short retention (1-4 hours) for cleanup phase
4. ✅ Monitor storage reduction progress
5. ✅ Adjust to production retention after cleanup

### Ongoing Operations
1. ✅ Set retention based on RTO/RPO requirements
2. ✅ Monitor storage usage trends
3. ✅ Alert on unusual retention cleanup behavior
4. ✅ Document retention policies in runbooks
5. ✅ Regular testing of CDC functionality

### Emergency Procedures
```bash
# If storage becomes critical, emergency cleanup:
docker exec redpanda-cdc rpk topic alter-config cdc.imdb.title_principals --set retention.ms=1800000  # 30 minutes

# If CDC breaks, check and restart consumers:
docker restart clickhouse-cdc
docker restart debezium-cdc
```

## 📝 Change Log

### Initial Implementation (August 2025)
- Implemented 1-hour retention after 194M record initial load
- Achieved 95% storage reduction (102GB → ~7GB)
- Verified CDC functionality preservation
- Documented all retention strategies and testing procedures

---

**Document Version**: 1.0  
**Last Updated**: August 2025  
**Tested Environment**: MacBook Pro M2, 194M+ IMDb records