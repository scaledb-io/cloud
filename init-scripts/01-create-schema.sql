-- Create IMDb database schema
USE imdb;

-- Table for name.basics
DROP TABLE IF EXISTS name_basics;
CREATE TABLE name_basics (
    nconst VARCHAR(10) PRIMARY KEY,
    primaryName VARCHAR(255),
    birthYear INT,
    deathYear INT,
    primaryProfession TEXT,
    knownForTitles TEXT
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Table for title.basics
DROP TABLE IF EXISTS title_basics;
CREATE TABLE title_basics (
    tconst VARCHAR(10) PRIMARY KEY,
    titleType VARCHAR(50),
    primaryTitle TEXT,
    originalTitle TEXT,
    isAdult BOOLEAN,
    startYear INT,
    endYear INT,
    runtimeMinutes INT,
    genres VARCHAR(255),
    INDEX idx_titleType (titleType),
    INDEX idx_startYear (startYear),
    INDEX idx_genres (genres)
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Table for title.ratings
DROP TABLE IF EXISTS title_ratings;
CREATE TABLE title_ratings (
    tconst VARCHAR(10) PRIMARY KEY,
    averageRating DECIMAL(3,1),
    numVotes INT,
    INDEX idx_averageRating (averageRating),
    INDEX idx_numVotes (numVotes)
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Table for title.principals
DROP TABLE IF EXISTS title_principals;
CREATE TABLE title_principals (
    tconst VARCHAR(10),
    ordering INT,
    nconst VARCHAR(10),
    category VARCHAR(50),
    job TEXT,
    characters TEXT,
    PRIMARY KEY (tconst, ordering),
    INDEX idx_nconst (nconst),
    INDEX idx_category (category)
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Table for title.crew
DROP TABLE IF EXISTS title_crew;
CREATE TABLE title_crew (
    tconst VARCHAR(10) PRIMARY KEY,
    directors TEXT,
    writers TEXT
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Table for title.episode
DROP TABLE IF EXISTS title_episode;
CREATE TABLE title_episode (
    tconst VARCHAR(10) PRIMARY KEY,
    parentTconst VARCHAR(10),
    seasonNumber INT,
    episodeNumber INT,
    INDEX idx_parentTconst (parentTconst),
    INDEX idx_season_episode (seasonNumber, episodeNumber)
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Table for title.akas
DROP TABLE IF EXISTS title_akas;
CREATE TABLE title_akas (
    titleId VARCHAR(10),
    ordering INT,
    title TEXT,
    region VARCHAR(10),
    language VARCHAR(10),
    types TEXT,
    attributes TEXT,
    isOriginalTitle BOOLEAN,
    PRIMARY KEY (titleId, ordering),
    INDEX idx_region (region),
    INDEX idx_language (language)
) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Set session variables for bulk loading
SET GLOBAL local_infile = 1;
SET GLOBAL max_allowed_packet = 1073741824;