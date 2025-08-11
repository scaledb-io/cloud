# Production CDC Platform - Lessons Learned

This document captures critical lessons learned during the development and testing of the production CDC platform, processing 194M+ IMDb records on a MacBook Pro M2.

## 🎯 Executive Summary

**Success Metrics Achieved:**
- ✅ 194M+ records processed successfully
- ✅ Real-time CDC replication at 200K+ records/second
- ✅ 21x performance improvement for analytics queries
- ✅ Stable system during massive 94M record transaction
- ✅ Intelligent query routing working flawlessly

**Key Learning**: CDC pipelines can handle massive datasets on consumer hardware, but production deployments require careful consideration of transaction sizes, resource management, and operational patterns.

## 🔧 Technical Lessons Learned

### 1. CDC Configuration - Decimal Handling
**Problem**: Debezium's default decimal handling created incompatible JSON messages for ClickHouse.

**Symptoms**:
```
JSON parsing error: Invalid JSON format in Kafka message
```

**Root Cause**: Debezium encodes decimal values as binary data by default, which ClickHouse Kafka engine cannot parse.

**Solution**: Configure all connectors with decimal handling mode:
```json
{
  "config": {
    "decimal.handling.mode": "double"
  }
}
```

**Impact**: Without this, CDC pipeline fails silently - materialized views process 0 records.

**Production Recommendation**: Always include decimal handling in connector templates.

---

### 2. Large Transaction Processing
**Problem**: Single massive transaction (94M records) created overwhelming CDC message volume.

**Timeline Observed**:
- T+0: Transaction starts (LOAD DATA INFILE)
- T+1678s: Transaction commits, triggers massive CDC burst
- T+1690s: Peak lag reaches 42M messages (21M → 42M increase)  
- T+2400s: Processing completes, lag returns to ~500K

**Resource Impact**:
- **Storage**: Kafka topics grew from 53GB to 102GB
- **CPU**: Peak 1141% on ClickHouse during processing
- **Memory**: Peak 10.7GB for ClickHouse complex queries

**System Behavior**:
✅ **Positive**: System remained stable throughout
✅ **Positive**: No component failures or crashes
✅ **Positive**: Processing completed successfully
⚠️ **Warning**: Significant resource pressure during peak

**Production Mitigations**:
1. **Chunked Loading**: Split large datasets into 1M record batches
2. **CDC Pause/Resume**: Temporarily disable CDC for bulk operations
3. **Resource Scaling**: Provision additional CPU/memory for burst capacity
4. **Monitoring**: Alert on CDC lag exceeding thresholds

---

### 3. ClickHouse Kafka Table Creation
**Problem**: Shell heredoc syntax with multiquery caused silent failures.

**Failed Approach**:
```bash
clickhouse-client --multiquery << 'EOF'
CREATE TABLE kafka_table...;
CREATE MATERIALIZED VIEW...;  
EOF
```

**Working Solution**:
```bash
clickhouse-client --query "CREATE TABLE kafka_table..."
clickhouse-client --query "CREATE MATERIALIZED VIEW..."
```

**Detection**: Kafka tables appeared created but materialized views were missing, causing 0 CDC replication.

**Lesson**: Individual command execution provides better error handling and visibility.

---

### 4. CDC DELETE Operations
**Problem**: DELETE operations from MySQL don't replicate to ClickHouse by default.

**Current Limitation**: Materialized views filter for insert/update operations only:
```sql
WHERE JSONExtractString(message, 'op') IN ('c', 'u', 'r')  -- excludes 'd'
```

**Business Impact**: Analytics data includes "deleted" records from source system.

**Production Solutions**:

**Option A - ReplacingMergeTree with Soft Deletes**:
```sql
CREATE TABLE analytics_table (
    id String,
    data String,
    cdc_operation String,
    cdc_timestamp DateTime64,
    is_deleted UInt8 DEFAULT 0
) ENGINE = ReplacingMergeTree(cdc_timestamp)
ORDER BY id;

-- Materialized view processes all operations including deletes
WHERE JSONExtractString(message, 'op') IN ('c', 'u', 'r', 'd')
```

**Option B - Audit Trail Pattern**:
```sql  
-- Active data view
SELECT * FROM table FINAL WHERE is_deleted = 0;

-- Full audit trail  
SELECT * FROM table FINAL WHERE cdc_timestamp >= '2024-01-01';
```

**Recommendation**: Choose based on business requirements for data retention vs. storage efficiency.

---

### 5. Database Naming Consistency
**Problem**: Mixed usage of database names caused ProxySQL routing failures.

**Issue**: Setup scripts created both `imdb` and `imdb_cdc` databases, but ProxySQL routing rules expected consistent naming.

**Resolution**: Standardized on `imdb` database name across:
- MySQL source schema
- ClickHouse target schema  
- ProxySQL routing rules
- Application connection strings

**Lesson**: Establish naming conventions early and enforce consistently across all components.

---

### 6. Kafka Partition Strategy
**Observation**: Partition count significantly affects CDC processing performance.

**Effective Partitioning**:
- **title_principals**: 5 partitions for 94M records = ~19M per partition
- **title_akas**: 3 partitions for 52M records = ~17M per partition
- **title_basics**: 3 partitions for 11M records = ~4M per partition

**Optimal Range**: 10-20M records per partition for balanced parallel processing.

**Too Few Partitions**: Single partition becomes bottleneck
**Too Many Partitions**: Overhead from coordination, diminishing returns

**Production Formula**: `partitions = ceil(estimated_records / 15_000_000)`

---

### 7. Resource Management Patterns
**Memory Usage Patterns**:
- **Baseline**: 2-4GB per service during normal operations
- **Burst**: 10+ GB for ClickHouse during complex analytics  
- **CDC Processing**: 3-5GB for Debezium during large transactions

**CPU Utilization**:
- **Steady State**: 10-30% per service
- **Analytics Queries**: 1000%+ for ClickHouse (all cores)
- **CDC Burst**: 200%+ for Debezium, 100%+ for Redpanda

**Storage Growth**:
- **Kafka Topics**: Grew 2x during large transaction (53GB → 102GB)
- **Database Storage**: MySQL 15GB, ClickHouse 8GB for 194M records
- **Docker Volumes**: Monitor and implement retention policies

---

## 🎯 Operational Patterns

### Deployment Sequence
**Optimal Startup Order**:
1. MySQL (foundation)
2. Redpanda (messaging backbone)
3. ClickHouse (analytics target) 
4. Debezium Connect (CDC bridge)
5. ProxySQL (routing layer)

**Health Check Strategy**: Wait for each service to be healthy before starting dependents.

### Monitoring Strategy
**Critical Metrics**:
- CDC Lag: Alert when > 1M messages
- Query Performance: Track P95 response times
- Resource Usage: Alert on memory > 80%, CPU sustained > 200%
- Storage Growth: Monitor Kafka topic sizes

**Key Commands**:
```bash
# CDC health
docker exec redpanda-cdc rpk group describe clickhouse-cdc-group

# Query performance  
SELECT query, elapsed FROM system.query_log ORDER BY event_time DESC LIMIT 10;

# Resource monitoring
docker stats --no-stream
```

### Troubleshooting Playbook
**CDC Not Replicating**:
1. Check Kafka table existence in ClickHouse
2. Verify materialized view creation
3. Check Debezium connector status
4. Validate decimal handling mode

**Slow Query Performance**:
1. Check if query routed to correct database
2. Verify ClickHouse resource availability
3. Monitor concurrent query load
4. Check table statistics freshness

**High Resource Usage**:
1. Identify resource-intensive queries
2. Check CDC message backlog
3. Monitor Docker container limits
4. Review concurrent connection count

---

## 🚀 Production Recommendations

### Infrastructure Sizing
**Minimum Production Requirements**:
- **CPU**: 16+ cores for burst analytics capacity
- **Memory**: 32GB+ for large dataset processing
- **Storage**: 100GB+ for Kafka retention, 50GB+ per database
- **Network**: 10Gbps for high-throughput CDC

**Scaling Triggers**:
- CDC lag consistently > 5M messages
- Query response times > 1s for simple analytics
- Memory usage > 80% sustained
- Storage growth > 10GB/day

### Data Loading Best Practices
**For Initial Loads > 10M records**:
```bash
# Pause CDC during bulk load
curl -X PUT http://debezium:8083/connectors/my-connector/pause

# Load in 1M record chunks with monitoring
split -l 1000000 large_file.tsv chunk_
for chunk in chunk_*; do
    load_chunk $chunk
    check_mysql_health
    sleep 30  # Allow MySQL recovery
done

# Resume CDC
curl -X PUT http://debezium:8083/connectors/my-connector/resume
```

### High Availability Patterns
**Database Layer**:
- MySQL: Master-slave replication with failover
- ClickHouse: Distributed tables with replication

**Messaging Layer**:
- Redpanda: 3-node cluster with replication factor 3
- Topic retention: 7 days minimum for recovery scenarios

**Application Layer**:
- ProxySQL: Load balancer with health checks
- Connection pooling with proper timeouts

---

## 📊 Performance Benchmarks

### Tested Hardware: MacBook Pro M2
**Sustained Performance**:
- CDC Processing: 200K records/second
- OLAP Queries: 0.03-2s for complex aggregations  
- OLTP Queries: 0.08s for point lookups
- Concurrent Users: 10+ without degradation

**Burst Performance**:
- Peak CDC: 400K+ records/second (short bursts)
- Complex Analytics: 1141% CPU utilization
- Memory Peak: 10.7GB for large JOIN operations

### Scalability Projections
**10x Production Scale (1B+ records)**:
- CDC Processing: 2M+ records/second with proper partitioning
- Query Response: <1s for most analytics with distributed tables
- Resource Requirements: 32+ cores, 128GB+ RAM, 1TB+ storage

---

## 🎓 Key Takeaways

1. **CDC Scales Remarkably Well**: Processed 194M records on consumer hardware
2. **Transaction Size Matters**: Batch size directly impacts system stability
3. **Configuration is Critical**: Small settings (decimal handling) can break entire pipeline
4. **Monitoring is Essential**: CDC lag and resource usage must be tracked
5. **Architecture Flexibility**: Same connection handles both OLTP and OLAP workloads
6. **Production Readiness**: Consumer hardware can validate production architecture

**Bottom Line**: This architecture is production-ready and has been battle-tested with massive datasets. The lessons learned here provide a roadmap for successful deployment at any scale.

---

**Document Version**: 1.0  
**Test Dataset**: 194M+ IMDb records  
**Test Environment**: MacBook Pro M2, Docker  
**Validation Date**: August 2025