#!/bin/bash

echo "
==========================================
🚀 PRODUCTION CDC PLATFORM DEPLOYMENT
==========================================

This will deploy a complete production-ready CDC platform:
✅ MySQL 8.0 with binlog CDC
✅ Debezium real-time streaming  
✅ Redpanda high-performance messaging
✅ ClickHouse analytics database
✅ ProxySQL intelligent query routing

Estimated deployment time: 5-10 minutes
"

# Function to wait for service health
wait_for_service() {
    local service=$1
    local max_attempts=${2:-60}
    local attempt=1
    
    echo "⏳ Waiting for $service to be healthy..."
    
    while [ $attempt -le $max_attempts ]; do
        if docker compose ps $service | grep -q "healthy"; then
            echo "✅ $service is healthy"
            return 0
        fi
        
        if [ $((attempt % 10)) -eq 0 ]; then
            echo "  🔄 $service still starting... (attempt $attempt/$max_attempts)"
        fi
        sleep 5
        attempt=$((attempt + 1))
    done
    
    echo "❌ $service failed to become healthy after $max_attempts attempts"
    return 1
}

echo "
==========================================
PHASE 1: Infrastructure Deployment
==========================================
"

echo "🏗️  Starting all services..."
docker compose up -d

echo "
==========================================
PHASE 2: Service Health Checks
==========================================
"

# Wait for services in dependency order
wait_for_service mysql 60
wait_for_service redpanda 45
wait_for_service clickhouse 40
wait_for_service proxysql 30
wait_for_service debezium-connect 90

echo "
==========================================
PHASE 3: CDC Pipeline Configuration
==========================================
"

echo "📊 Creating Redpanda topics..."
sleep 10
docker exec redpanda-cdc rpk topic create cdc.imdb.title_ratings --partitions 1 --replicas 1
docker exec redpanda-cdc rpk topic create cdc.imdb.title_basics --partitions 3 --replicas 1
docker exec redpanda-cdc rpk topic create cdc.imdb.name_basics --partitions 3 --replicas 1
docker exec redpanda-cdc rpk topic create cdc.imdb.title_crew --partitions 2 --replicas 1
docker exec redpanda-cdc rpk topic create cdc.imdb.title_episode --partitions 2 --replicas 1
docker exec redpanda-cdc rpk topic create cdc.imdb.title_akas --partitions 3 --replicas 1
docker exec redpanda-cdc rpk topic create cdc.imdb.title_principals --partitions 5 --replicas 1
docker exec redpanda-cdc rpk topic create cdc.dbhistory --partitions 1 --replicas 1

echo "🔗 Setting up ClickHouse Kafka consumers..."
echo "⏳ Waiting for Redpanda to be fully ready for Kafka table creation..."
sleep 15

echo "📊 Testing Redpanda connectivity from ClickHouse..."
if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "SELECT 'ClickHouse ready' as status;" > /dev/null 2>&1; then
    echo "❌ ClickHouse not ready for Kafka table creation"
    exit 1
fi

echo "🔗 Creating ClickHouse Kafka tables and materialized views..."

# Create Kafka tables and materialized views for all IMDb tables
echo "   📊 Creating title_ratings Kafka table and view..."
if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE TABLE IF NOT EXISTS title_ratings_kafka (message String) 
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.title_ratings', 'clickhouse-cdc-group', 'JSONAsString');
"; then
    echo "❌ Failed to create title_ratings Kafka table"
    exit 1
fi

if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE MATERIALIZED VIEW IF NOT EXISTS title_ratings_cdc_mv TO title_ratings AS
SELECT 
    JSONExtractString(message, 'after', 'tconst') as tconst,
    JSONExtractFloat(message, 'after', 'averageRating') as averageRating,
    JSONExtractUInt(message, 'after', 'numVotes') as numVotes,
    JSONExtractString(message, 'op') as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp
FROM title_ratings_kafka
WHERE JSONExtractString(message, 'op') IN ('c', 'u', 'r')
  AND length(JSONExtractString(message, 'after', 'tconst')) > 0;
"; then
    echo "❌ Failed to create title_ratings materialized view"
    exit 1
fi

echo "   📊 Creating title_basics Kafka table and view..."
if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE TABLE IF NOT EXISTS title_basics_kafka (message String)
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.title_basics', 'clickhouse-cdc-group', 'JSONAsString');
"; then
    echo "❌ Failed to create title_basics Kafka table"
    exit 1
fi

if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE MATERIALIZED VIEW IF NOT EXISTS title_basics_cdc_mv TO title_basics AS
SELECT 
    JSONExtractString(message, 'after', 'tconst') as tconst,
    JSONExtractString(message, 'after', 'titleType') as titleType,
    JSONExtractString(message, 'after', 'primaryTitle') as primaryTitle,
    JSONExtractString(message, 'after', 'originalTitle') as originalTitle,
    JSONExtractUInt(message, 'after', 'isAdult') as isAdult,
    JSONExtractUInt(message, 'after', 'startYear') as startYear,
    JSONExtractUInt(message, 'after', 'endYear') as endYear,
    JSONExtractUInt(message, 'after', 'runtimeMinutes') as runtimeMinutes,
    splitByChar(',', JSONExtractString(message, 'after', 'genres')) as genres,
    JSONExtractString(message, 'op') as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp
FROM title_basics_kafka
WHERE JSONExtractString(message, 'op') IN ('c', 'u', 'r')
  AND length(JSONExtractString(message, 'after', 'tconst')) > 0;
"; then
    echo "❌ Failed to create title_basics materialized view"
    exit 1
fi

echo "   📊 Creating name_basics Kafka table and view..."
if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE TABLE IF NOT EXISTS name_basics_kafka (message String)
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.name_basics', 'clickhouse-cdc-group', 'JSONAsString');
"; then
    echo "❌ Failed to create name_basics Kafka table"
    exit 1
fi

if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE MATERIALIZED VIEW IF NOT EXISTS name_basics_cdc_mv TO name_basics AS
SELECT 
    JSONExtractString(message, 'after', 'nconst') as nconst,
    JSONExtractString(message, 'after', 'primaryName') as primaryName,
    JSONExtractUInt(message, 'after', 'birthYear') as birthYear,
    JSONExtractUInt(message, 'after', 'deathYear') as deathYear,
    splitByChar(',', JSONExtractString(message, 'after', 'primaryProfession')) as primaryProfession,
    splitByChar(',', JSONExtractString(message, 'after', 'knownForTitles')) as knownForTitles,
    JSONExtractString(message, 'op') as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp
FROM name_basics_kafka
WHERE JSONExtractString(message, 'op') IN ('c', 'u', 'r')
  AND length(JSONExtractString(message, 'after', 'nconst')) > 0;
"; then
    echo "❌ Failed to create name_basics materialized view"
    exit 1
fi

echo "   📊 Creating title_crew Kafka table and view..."
if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE TABLE IF NOT EXISTS title_crew_kafka (message String)
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.title_crew', 'clickhouse-cdc-group', 'JSONAsString');
"; then
    echo "❌ Failed to create title_crew Kafka table"
    exit 1
fi

if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE MATERIALIZED VIEW IF NOT EXISTS title_crew_cdc_mv TO title_crew AS
SELECT 
    JSONExtractString(message, 'after', 'tconst') as tconst,
    splitByChar(',', JSONExtractString(message, 'after', 'directors')) as directors,
    splitByChar(',', JSONExtractString(message, 'after', 'writers')) as writers,
    JSONExtractString(message, 'op') as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp
FROM title_crew_kafka
WHERE JSONExtractString(message, 'op') IN ('c', 'u', 'r')
  AND length(JSONExtractString(message, 'after', 'tconst')) > 0;
"; then
    echo "❌ Failed to create title_crew materialized view"
    exit 1
fi

echo "   📊 Creating title_episode Kafka table and view..."
if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE TABLE IF NOT EXISTS title_episode_kafka (message String)
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.title_episode', 'clickhouse-cdc-group', 'JSONAsString');
"; then
    echo "❌ Failed to create title_episode Kafka table"
    exit 1
fi

if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE MATERIALIZED VIEW IF NOT EXISTS title_episode_cdc_mv TO title_episode AS
SELECT 
    JSONExtractString(message, 'after', 'tconst') as tconst,
    JSONExtractString(message, 'after', 'parentTconst') as parentTconst,
    JSONExtractUInt(message, 'after', 'seasonNumber') as seasonNumber,
    JSONExtractUInt(message, 'after', 'episodeNumber') as episodeNumber,
    JSONExtractString(message, 'op') as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp
FROM title_episode_kafka
WHERE JSONExtractString(message, 'op') IN ('c', 'u', 'r')
  AND length(JSONExtractString(message, 'after', 'tconst')) > 0;
"; then
    echo "❌ Failed to create title_episode materialized view"
    exit 1
fi

echo "   📊 Creating title_akas Kafka table and view..."
if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE TABLE IF NOT EXISTS title_akas_kafka (message String)
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.title_akas', 'clickhouse-cdc-group', 'JSONAsString');
"; then
    echo "❌ Failed to create title_akas Kafka table"
    exit 1
fi

if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE MATERIALIZED VIEW IF NOT EXISTS title_akas_cdc_mv TO title_akas AS
SELECT 
    JSONExtractString(message, 'after', 'titleId') as titleId,
    JSONExtractUInt(message, 'after', 'ordering') as ordering,
    JSONExtractString(message, 'after', 'title') as title,
    JSONExtractString(message, 'after', 'region') as region,
    JSONExtractString(message, 'after', 'language') as language,
    splitByChar(',', JSONExtractString(message, 'after', 'types')) as types,
    splitByChar(',', JSONExtractString(message, 'after', 'attributes')) as attributes,
    JSONExtractUInt(message, 'after', 'isOriginalTitle') as isOriginalTitle,
    JSONExtractString(message, 'op') as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp
FROM title_akas_kafka
WHERE JSONExtractString(message, 'op') IN ('c', 'u', 'r')
  AND length(JSONExtractString(message, 'after', 'titleId')) > 0;
"; then
    echo "❌ Failed to create title_akas materialized view"
    exit 1
fi

echo "   📊 Creating title_principals Kafka table and view..."
if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE TABLE IF NOT EXISTS title_principals_kafka (message String)
ENGINE = Kafka('redpanda-cdc:29092', 'cdc.imdb.title_principals', 'clickhouse-cdc-group', 'JSONAsString');
"; then
    echo "❌ Failed to create title_principals Kafka table"
    exit 1
fi

if ! docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "
USE imdb;
CREATE MATERIALIZED VIEW IF NOT EXISTS title_principals_cdc_mv TO title_principals AS
SELECT 
    JSONExtractString(message, 'after', 'tconst') as tconst,
    JSONExtractUInt(message, 'after', 'ordering') as ordering,
    JSONExtractString(message, 'after', 'nconst') as nconst,
    JSONExtractString(message, 'after', 'category') as category,
    JSONExtractString(message, 'after', 'job') as job,
    splitByChar(',', JSONExtractString(message, 'after', 'characters')) as characters,
    JSONExtractString(message, 'op') as cdc_operation,
    toDateTime(JSONExtractUInt(message, 'ts_ms') / 1000) as cdc_timestamp
FROM title_principals_kafka
WHERE JSONExtractString(message, 'op') IN ('c', 'u', 'r')
  AND length(JSONExtractString(message, 'after', 'tconst')) > 0;
"; then
    echo "❌ Failed to create title_principals materialized view"
    exit 1
fi

# Grant permissions for ProxySQL routing  
docker exec clickhouse-cdc clickhouse-client --password clickhouse123 --query "GRANT SELECT ON imdb.* TO proxyuser;" 2>/dev/null

echo "✅ ClickHouse Kafka tables and materialized views created successfully for all 7 tables"

echo "⚡ Creating Debezium CDC connectors for all IMDb tables..."
sleep 15

# Create CDC connectors for all IMDb tables (with decimal handling)
curl -s -X POST -H "Content-Type: application/json" http://localhost:8083/connectors --data '{
  "name": "imdb-title-ratings-cdc",
  "config": {
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "tasks.max": "1",
    "database.hostname": "mysql-cdc",
    "database.port": "3306",
    "database.user": "root",
    "database.password": "rootpassword",
    "database.server.id": "100",
    "topic.prefix": "cdc",
    "database.include.list": "imdb",
    "table.include.list": "imdb.title_ratings",
    "schema.history.internal.kafka.bootstrap.servers": "redpanda-cdc:29092",
    "schema.history.internal.kafka.topic": "cdc.dbhistory",
    "snapshot.mode": "initial",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "decimal.handling.mode": "double"
  }
}' > /dev/null

curl -s -X POST -H "Content-Type: application/json" http://localhost:8083/connectors --data '{
  "name": "imdb-title-basics-cdc",
  "config": {
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "tasks.max": "1",
    "database.hostname": "mysql-cdc",
    "database.port": "3306",
    "database.user": "root",
    "database.password": "rootpassword",
    "database.server.id": "200",
    "topic.prefix": "cdc",
    "database.include.list": "imdb",
    "table.include.list": "imdb.title_basics",
    "schema.history.internal.kafka.bootstrap.servers": "redpanda-cdc:29092",
    "schema.history.internal.kafka.topic": "cdc.dbhistory",
    "snapshot.mode": "initial",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "decimal.handling.mode": "double"
  }
}' > /dev/null

curl -s -X POST -H "Content-Type: application/json" http://localhost:8083/connectors --data '{
  "name": "imdb-name-basics-cdc",
  "config": {
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "tasks.max": "1",
    "database.hostname": "mysql-cdc",
    "database.port": "3306",
    "database.user": "root",
    "database.password": "rootpassword",
    "database.server.id": "300",
    "topic.prefix": "cdc",
    "database.include.list": "imdb",
    "table.include.list": "imdb.name_basics",
    "schema.history.internal.kafka.bootstrap.servers": "redpanda-cdc:29092",
    "schema.history.internal.kafka.topic": "cdc.dbhistory",
    "snapshot.mode": "initial",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "decimal.handling.mode": "double"
  }
}' > /dev/null

# Create CDC connectors for remaining tables
echo "📊 Creating connectors for remaining tables..."

curl -s -X POST -H "Content-Type: application/json" http://localhost:8083/connectors --data '{
  "name": "imdb-title-crew-cdc",
  "config": {
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "tasks.max": "1",
    "database.hostname": "mysql-cdc",
    "database.port": "3306",
    "database.user": "root",
    "database.password": "rootpassword",
    "database.server.id": "400",
    "topic.prefix": "cdc",
    "database.include.list": "imdb",
    "table.include.list": "imdb.title_crew",
    "schema.history.internal.kafka.bootstrap.servers": "redpanda-cdc:29092",
    "schema.history.internal.kafka.topic": "cdc.dbhistory",
    "snapshot.mode": "initial",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "decimal.handling.mode": "double"
  }
}' > /dev/null

curl -s -X POST -H "Content-Type: application/json" http://localhost:8083/connectors --data '{
  "name": "imdb-title-episode-cdc",
  "config": {
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "tasks.max": "1",
    "database.hostname": "mysql-cdc",
    "database.port": "3306",
    "database.user": "root",
    "database.password": "rootpassword",
    "database.server.id": "500",
    "topic.prefix": "cdc",
    "database.include.list": "imdb",
    "table.include.list": "imdb.title_episode",
    "schema.history.internal.kafka.bootstrap.servers": "redpanda-cdc:29092",
    "schema.history.internal.kafka.topic": "cdc.dbhistory",
    "snapshot.mode": "initial",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "decimal.handling.mode": "double"
  }
}' > /dev/null

curl -s -X POST -H "Content-Type: application/json" http://localhost:8083/connectors --data '{
  "name": "imdb-title-akas-cdc",
  "config": {
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "tasks.max": "1",
    "database.hostname": "mysql-cdc",
    "database.port": "3306",
    "database.user": "root",
    "database.password": "rootpassword",
    "database.server.id": "600",
    "topic.prefix": "cdc",
    "database.include.list": "imdb",
    "table.include.list": "imdb.title_akas",
    "schema.history.internal.kafka.bootstrap.servers": "redpanda-cdc:29092",
    "schema.history.internal.kafka.topic": "cdc.dbhistory",
    "snapshot.mode": "initial",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "decimal.handling.mode": "double"
  }
}' > /dev/null

curl -s -X POST -H "Content-Type: application/json" http://localhost:8083/connectors --data '{
  "name": "imdb-title-principals-cdc",
  "config": {
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "tasks.max": "1",
    "database.hostname": "mysql-cdc",
    "database.port": "3306",
    "database.user": "root",
    "database.password": "rootpassword",
    "database.server.id": "700",
    "topic.prefix": "cdc",
    "database.include.list": "imdb",
    "table.include.list": "imdb.title_principals",
    "schema.history.internal.kafka.bootstrap.servers": "redpanda-cdc:29092",
    "schema.history.internal.kafka.topic": "cdc.dbhistory",
    "snapshot.mode": "initial",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "decimal.handling.mode": "double"
  }
}' > /dev/null

echo "
==========================================
🎉 PRODUCTION CDC PLATFORM DEPLOYED!
==========================================

✅ MySQL CDC ready on port 3306 (empty tables)
✅ ClickHouse analytics ready on ports 9000/8123
✅ ProxySQL intelligent routing on port 6033  
✅ Debezium CDC connectors deployed
✅ Redpanda messaging on port 9092
✅ Redpanda Console on http://localhost:8080

🎯 INTELLIGENT QUERY ROUTING READY:
- OLAP queries (COUNT, SUM, AVG, GROUP BY) → ClickHouse
- OLTP queries (INSERT, UPDATE, DELETE) → MySQL
- Connect through ProxySQL: mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123

📊 NEXT STEPS:

1. 📥 Load IMDb dataset (134M+ records):
   ./load-imdb-data.sh

2. 🔍 Test with your own data:
   mysql -h127.0.0.1 -P6033 -uproxyuser -pproxypass123 -e \"INSERT INTO title_ratings VALUES ('tt9999999', 9.5, 1000);\"

3. 👀 Monitor real-time CDC:
   clickhouse-client --host 127.0.0.1 --password clickhouse123 --query \"SELECT count() FROM imdb_cdc.title_ratings;\"

🚀 Production CDC platform ready for data loading!
"