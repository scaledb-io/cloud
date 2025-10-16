#!/bin/bash

# Wait for MySQL to be ready
echo "Waiting for MySQL to be ready..."
until mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1" > /dev/null 2>&1; do
    sleep 5
done

echo "MySQL is ready. Starting data import..."

# Check if data files exist and decompress if needed
DATA_DIR="/imdb-data"
if [ -d "$DATA_DIR" ]; then
    echo "Found data directory at $DATA_DIR"
    
    # Decompress gz files if they exist
    for gz_file in $DATA_DIR/*.gz; do
        if [ -f "$gz_file" ]; then
            base_name=$(basename "$gz_file" .gz)
            echo "Decompressing $gz_file to /tmp/$base_name"
            gunzip -c "$gz_file" > "/tmp/$base_name"
        fi
    done
    
    # Use /tmp for data files
    DATA_DIR="/tmp"
else
    echo "No data directory found, will download data..."
    # Download logic would go here if needed
    exit 1
fi

# Enable local_infile and optimize for bulk loading
mysql -u root -p${MYSQL_ROOT_PASSWORD} --local-infile=1 <<EOF
USE imdb;
SET GLOBAL local_infile = 1;
SET SESSION sql_mode = '';
SET SESSION foreign_key_checks = 0;
SET SESSION unique_checks = 0;
SET SESSION autocommit = 0;
EOF

# Function to load TSV file into table
load_tsv() {
    local FILE=$1
    local TABLE=$2
    local COLUMNS=$3
    
    echo "Loading $FILE into $TABLE..."
    
    mysql -u root -p${MYSQL_ROOT_PASSWORD} --local-infile=1 imdb <<EOF
SET SESSION sql_mode = '';
LOAD DATA LOCAL INFILE '$DATA_DIR/$FILE'
INTO TABLE $TABLE
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
($COLUMNS)
SET 
    birthYear = NULLIF(@birthYear, '\\\\N'),
    deathYear = NULLIF(@deathYear, '\\\\N'),
    isAdult = IF(@isAdult = '\\\\N', NULL, @isAdult),
    startYear = NULLIF(@startYear, '\\\\N'),
    endYear = NULLIF(@endYear, '\\\\N'),
    runtimeMinutes = NULLIF(@runtimeMinutes, '\\\\N'),
    averageRating = NULLIF(@averageRating, '\\\\N'),
    numVotes = NULLIF(@numVotes, '\\\\N'),
    seasonNumber = NULLIF(@seasonNumber, '\\\\N'),
    episodeNumber = NULLIF(@episodeNumber, '\\\\N'),
    isOriginalTitle = IF(@isOriginalTitle = '\\\\N', NULL, @isOriginalTitle);
EOF
    
    if [ $? -eq 0 ]; then
        echo "Successfully loaded $FILE"
    else
        echo "Error loading $FILE"
    fi
}

# Load name.basics
echo "Loading name.basics.tsv..."
mysql -u root -p${MYSQL_ROOT_PASSWORD} --local-infile=1 imdb <<EOF
SET SESSION sql_mode = '';
SET SESSION foreign_key_checks = 0;
SET SESSION unique_checks = 0;
SET SESSION autocommit = 0;
LOAD DATA LOCAL INFILE '/tmp/name.basics.tsv'
INTO TABLE name_basics
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(nconst, primaryName, @birthYear, @deathYear, @primaryProfession, @knownForTitles)
SET 
    birthYear = IF(@birthYear = '\\\\N', NULL, @birthYear),
    deathYear = IF(@deathYear = '\\\\N', NULL, @deathYear),
    primaryProfession = IF(@primaryProfession = '\\\\N', NULL, @primaryProfession),
    knownForTitles = IF(@knownForTitles = '\\\\N', NULL, @knownForTitles);
COMMIT;
EOF
echo "Loaded name.basics.tsv successfully"

# Load title.basics
echo "Loading title.basics.tsv..."
mysql -u root -p${MYSQL_ROOT_PASSWORD} --local-infile=1 imdb <<EOF
SET SESSION sql_mode = '';
SET SESSION foreign_key_checks = 0;
SET SESSION unique_checks = 0;
SET SESSION autocommit = 0;
LOAD DATA LOCAL INFILE '/tmp/title.basics.tsv'
INTO TABLE title_basics
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(tconst, titleType, primaryTitle, originalTitle, @isAdult, @startYear, @endYear, @runtimeMinutes, @genres)
SET 
    isAdult = IF(@isAdult = '\\\\N', NULL, @isAdult),
    startYear = IF(@startYear = '\\\\N', NULL, @startYear),
    endYear = IF(@endYear = '\\\\N', NULL, @endYear),
    runtimeMinutes = IF(@runtimeMinutes = '\\\\N', NULL, @runtimeMinutes),
    genres = IF(@genres = '\\\\N', NULL, @genres);
COMMIT;
EOF
echo "Loaded title.basics.tsv successfully"

# Load title.ratings
echo "Loading title.ratings.tsv..."
mysql -u root -p${MYSQL_ROOT_PASSWORD} --local-infile=1 imdb <<EOF
SET SESSION sql_mode = '';
SET SESSION foreign_key_checks = 0;
SET SESSION unique_checks = 0;
SET SESSION autocommit = 0;
LOAD DATA LOCAL INFILE '/tmp/title.ratings.tsv'
INTO TABLE title_ratings
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(tconst, @averageRating, @numVotes)
SET 
    averageRating = IF(@averageRating = '\\\\N', NULL, @averageRating),
    numVotes = IF(@numVotes = '\\\\N', NULL, @numVotes);
COMMIT;
EOF
echo "Loaded title.ratings.tsv successfully"

# Load title.principals
echo "Loading title.principals.tsv..."
mysql -u root -p${MYSQL_ROOT_PASSWORD} --local-infile=1 imdb <<EOF
SET SESSION sql_mode = '';
SET SESSION foreign_key_checks = 0;
SET SESSION unique_checks = 0;
SET SESSION autocommit = 0;
LOAD DATA LOCAL INFILE '/tmp/title.principals.tsv'
INTO TABLE title_principals
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(tconst, ordering, nconst, @category, @job, @characters)
SET 
    category = IF(@category = '\\\\N', NULL, @category),
    job = IF(@job = '\\\\N', NULL, @job),
    characters = IF(@characters = '\\\\N', NULL, @characters);
COMMIT;
EOF
echo "Loaded title.principals.tsv successfully"

# Load title.crew
echo "Loading title.crew.tsv..."
mysql -u root -p${MYSQL_ROOT_PASSWORD} --local-infile=1 imdb <<EOF
SET SESSION sql_mode = '';
SET SESSION foreign_key_checks = 0;
SET SESSION unique_checks = 0;
SET SESSION autocommit = 0;
LOAD DATA LOCAL INFILE '/tmp/title.crew.tsv'
INTO TABLE title_crew
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(tconst, @directors, @writers)
SET 
    directors = IF(@directors = '\\\\N', NULL, @directors),
    writers = IF(@writers = '\\\\N', NULL, @writers);
COMMIT;
EOF
echo "Loaded title.crew.tsv successfully"

# Load title.episode
echo "Loading title.episode.tsv..."
mysql -u root -p${MYSQL_ROOT_PASSWORD} --local-infile=1 imdb <<EOF
SET SESSION sql_mode = '';
SET SESSION foreign_key_checks = 0;
SET SESSION unique_checks = 0;
SET SESSION autocommit = 0;
LOAD DATA LOCAL INFILE '/tmp/title.episode.tsv'
INTO TABLE title_episode
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(tconst, parentTconst, @seasonNumber, @episodeNumber)
SET 
    seasonNumber = IF(@seasonNumber = '\\\\N', NULL, @seasonNumber),
    episodeNumber = IF(@episodeNumber = '\\\\N', NULL, @episodeNumber);
COMMIT;
EOF
echo "Loaded title.episode.tsv successfully"

# Load title.akas
echo "Loading title.akas.tsv..."
mysql -u root -p${MYSQL_ROOT_PASSWORD} --local-infile=1 imdb <<EOF
SET SESSION sql_mode = '';
SET SESSION foreign_key_checks = 0;
SET SESSION unique_checks = 0;
SET SESSION autocommit = 0;
LOAD DATA LOCAL INFILE '/tmp/title.akas.tsv'
INTO TABLE title_akas
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\t'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(titleId, ordering, @title, @region, @language, @types, @attributes, @isOriginalTitle)
SET 
    title = IF(@title = '\\\\N', NULL, @title),
    region = IF(@region = '\\\\N', NULL, @region),
    language = IF(@language = '\\\\N', NULL, @language),
    types = IF(@types = '\\\\N', NULL, @types),
    attributes = IF(@attributes = '\\\\N', NULL, @attributes),
    isOriginalTitle = IF(@isOriginalTitle = '\\\\N' OR @isOriginalTitle = '', NULL, @isOriginalTitle);
COMMIT;
EOF
echo "Loaded title.akas.tsv successfully"

echo "Data import completed!"

# Show table counts
echo "Verifying data import..."
mysql -u root -p${MYSQL_ROOT_PASSWORD} imdb <<EOF
SELECT 'name_basics' as table_name, COUNT(*) as row_count FROM name_basics
UNION ALL
SELECT 'title_basics', COUNT(*) FROM title_basics
UNION ALL
SELECT 'title_ratings', COUNT(*) FROM title_ratings
UNION ALL
SELECT 'title_principals', COUNT(*) FROM title_principals
UNION ALL
SELECT 'title_crew', COUNT(*) FROM title_crew
UNION ALL
SELECT 'title_episode', COUNT(*) FROM title_episode
UNION ALL
SELECT 'title_akas', COUNT(*) FROM title_akas;
EOF