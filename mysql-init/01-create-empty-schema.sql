-- Production MySQL Schema for CDC
-- Creates empty tables ready for data loading and CDC streaming

USE imdb;

-- Create monitor user for ProxySQL
CREATE USER IF NOT EXISTS 'monitor'@'%' IDENTIFIED BY 'monitor';
GRANT REPLICATION CLIENT ON *.* TO 'monitor'@'%';
GRANT SELECT ON *.* TO 'monitor'@'%';

-- Create proxy user for ProxySQL routing
CREATE USER IF NOT EXISTS 'proxyuser'@'%' IDENTIFIED BY 'proxypass123';
GRANT ALL PRIVILEGES ON imdb.* TO 'proxyuser'@'%';
GRANT SELECT ON *.* TO 'proxyuser'@'%';

FLUSH PRIVILEGES;

-- IMDb Tables Schema
CREATE TABLE IF NOT EXISTS title_ratings (
    tconst VARCHAR(10) PRIMARY KEY,
    averageRating DECIMAL(3,1),
    numVotes INT,
    INDEX idx_rating (averageRating),
    INDEX idx_votes (numVotes)
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS title_basics (
    tconst VARCHAR(10) PRIMARY KEY,
    titleType VARCHAR(50),
    primaryTitle VARCHAR(500),
    originalTitle VARCHAR(500),
    isAdult TINYINT,
    startYear INT,
    endYear INT,
    runtimeMinutes INT,
    genres TEXT,
    INDEX idx_type (titleType),
    INDEX idx_year (startYear)
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS name_basics (
    nconst VARCHAR(10) PRIMARY KEY,
    primaryName VARCHAR(255),
    birthYear INT,
    deathYear INT,
    primaryProfession TEXT,
    knownForTitles TEXT
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS title_crew (
    tconst VARCHAR(10) PRIMARY KEY,
    directors TEXT,
    writers TEXT
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS title_episode (
    tconst VARCHAR(10) PRIMARY KEY,
    parentTconst VARCHAR(10),
    seasonNumber INT,
    episodeNumber INT,
    INDEX idx_parent (parentTconst),
    INDEX idx_season (seasonNumber)
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS title_akas (
    titleId VARCHAR(10),
    ordering INT,
    title TEXT,
    region VARCHAR(10),
    language VARCHAR(10),
    types TEXT,
    attributes TEXT,
    isOriginalTitle TINYINT DEFAULT 0,
    PRIMARY KEY (titleId, ordering),
    INDEX idx_title (titleId),
    INDEX idx_region (region)
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS title_principals (
    tconst VARCHAR(10),
    ordering INT,
    nconst VARCHAR(10),
    category VARCHAR(50),
    job TEXT,
    characters TEXT,
    PRIMARY KEY (tconst, ordering),
    INDEX idx_tconst (tconst),
    INDEX idx_nconst (nconst),
    INDEX idx_category (category)
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

SELECT 'Production MySQL schema ready for CDC!' as status;