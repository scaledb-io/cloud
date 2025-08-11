# Production CDC Platform Scripts

## 📋 Available Scripts

### 🏗️ `setup-production-cdc.sh`
**Deploy the complete CDC platform infrastructure**
- Deploys MySQL, ClickHouse, Redpanda, Debezium, ProxySQL
- Configures CDC connectors and intelligent routing
- Creates empty database schemas
- **Time**: 5-10 minutes
- **Output**: Running CDC platform ready for data

```bash
./setup-production-cdc.sh
```

### 📊 `load-imdb-data.sh`
**Download and load complete IMDb dataset**
- Downloads 7GB of IMDb data files
- Loads 134M+ records into MySQL
- Streams via real-time CDC to ClickHouse  
- Shows loading progress and CDC verification
- **Time**: 30-60 minutes
- **Output**: Production system with massive dataset

```bash
./load-imdb-data.sh
```

### 🧪 `test-cdc.sh`
**Quick verification of CDC platform functionality**
- Tests all service connections
- Verifies CDC replication with test data
- Checks intelligent query routing
- Shows ProxySQL routing statistics
- **Time**: 30 seconds
- **Output**: Health check report

```bash
./test-cdc.sh
```

### 🧹 `cleanup.sh`
**Clean shutdown and optional data removal**
- Stops all containers gracefully
- Optionally removes all data volumes
- Cleans up networks and unused resources
- **Time**: 30 seconds
- **Output**: Clean system state

```bash
./cleanup.sh
```

## 🚀 Typical Workflow

### New Deployment
```bash
# 1. Deploy platform
./setup-production-cdc.sh

# 2. Quick test
./test-cdc.sh

# 3. Load full dataset (optional)
./load-imdb-data.sh
```

### Development/Testing
```bash
# Deploy platform only
./setup-production-cdc.sh

# Test with small data
./test-cdc.sh

# Manual testing
mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123
```

### Cleanup
```bash
# Stop everything
./cleanup.sh

# Remove all data (optional when prompted)
```

## 🎯 Script Features

### Error Handling
- All scripts check prerequisites
- Graceful failures with helpful messages
- Service health verification

### Progress Monitoring  
- Real-time status updates
- CDC replication verification
- Loading progress indicators

### User-Friendly Output
- Clear phase separation
- Emoji indicators for status
- Copy-pasteable test commands

### Production Ready
- Configurable timeouts
- Health checks
- Resource optimization

## 📚 Additional Information

### Service Ports
- **MySQL**: 3306 (direct)
- **ClickHouse**: 9000 (native), 8123 (HTTP)
- **ProxySQL**: 6033 (queries), 6032 (admin)
- **Redpanda**: 9092 (external), 29092 (internal)
- **Debezium**: 8083 (REST API)
- **Console**: 8080 (web UI)

### Default Credentials
- **MySQL**: root/rootpassword, proxyuser/proxypass123
- **ClickHouse**: default/clickhouse123
- **ProxySQL**: admin/admin, proxyuser/proxypass123
- **Debezium**: No authentication

### Data Locations
- **MySQL Data**: Docker volume `mysql-data`
- **ClickHouse Data**: Docker volume `clickhouse-data`
- **Redpanda Data**: Docker volume `redpanda-data`
- **ProxySQL Config**: Docker volume `proxysql-data`

### Performance Notes
- **Memory**: 8GB+ recommended for full dataset
- **Storage**: 10GB+ for complete IMDb dataset
- **CPU**: 4+ cores recommended for optimal performance
- **Network**: High throughput for CDC streaming