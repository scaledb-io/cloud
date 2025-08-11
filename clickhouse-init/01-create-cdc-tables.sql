-- Production ClickHouse Schema for CDC
-- Optimized for real-time CDC ingestion from MySQL

CREATE DATABASE IF NOT EXISTS imdb;
USE imdb;

-- Create users for ProxySQL access
CREATE USER IF NOT EXISTS proxyuser IDENTIFIED BY 'proxypass123';
GRANT ALL ON imdb.* TO proxyuser;

-- Target tables for CDC data (optimized partitioning)
CREATE TABLE IF NOT EXISTS title_ratings
(
    tconst String,
    averageRating Float32,
    numVotes UInt32,
    cdc_operation String DEFAULT 'c',
    cdc_timestamp DateTime DEFAULT now(),
    processing_time DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (tconst, cdc_timestamp)
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS title_basics
(
    tconst String,
    titleType LowCardinality(String),
    primaryTitle String,
    originalTitle String,
    isAdult UInt8,
    startYear UInt16,
    endYear UInt16 DEFAULT 0,
    runtimeMinutes UInt16 DEFAULT 0,
    genres Array(String),
    cdc_operation String DEFAULT 'c',
    cdc_timestamp DateTime DEFAULT now(),
    processing_time DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (titleType, startYear, tconst)
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS name_basics
(
    nconst String,
    primaryName String,
    birthYear UInt16 DEFAULT 0,
    deathYear UInt16 DEFAULT 0,
    primaryProfession Array(String),
    knownForTitles Array(String),
    cdc_operation String DEFAULT 'c',
    cdc_timestamp DateTime DEFAULT now(),
    processing_time DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (primaryName, nconst)
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS title_crew
(
    tconst String,
    directors Array(String),
    writers Array(String),
    cdc_operation String DEFAULT 'c',
    cdc_timestamp DateTime DEFAULT now(),
    processing_time DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (tconst, cdc_timestamp)
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS title_episode
(
    tconst String,
    parentTconst String,
    seasonNumber UInt16 DEFAULT 0,
    episodeNumber UInt16 DEFAULT 0,
    cdc_operation String DEFAULT 'c',
    cdc_timestamp DateTime DEFAULT now(),
    processing_time DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (parentTconst, seasonNumber, episodeNumber, tconst)
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS title_akas
(
    titleId String,
    ordering UInt16,
    title String,
    region LowCardinality(String),
    language LowCardinality(String),
    types Array(String),
    attributes Array(String),
    isOriginalTitle UInt8 DEFAULT 0,
    cdc_operation String DEFAULT 'c',
    cdc_timestamp DateTime DEFAULT now(),
    processing_time DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (titleId, ordering, cdc_timestamp)
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS title_principals
(
    tconst String,
    ordering UInt16,
    nconst String,
    category LowCardinality(String),
    job String,
    characters Array(String),
    cdc_operation String DEFAULT 'c',
    cdc_timestamp DateTime DEFAULT now(),
    processing_time DateTime DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(cdc_timestamp)
ORDER BY (tconst, ordering, nconst)
SETTINGS index_granularity = 8192;

-- Kafka tables for CDC consumption (will be created by setup script)
-- Materialized views for CDC processing (will be created by setup script)

SELECT 'Production ClickHouse schema ready for CDC!' as status;