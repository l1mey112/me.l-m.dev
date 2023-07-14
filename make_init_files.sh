#!/bin/sh

set -xe

# call this to create the files needed

# `.schema`
echo 'CREATE TABLE `posts` (`id` INTEGER, `created_at` INTEGER, `tags` TEXT, `content` TEXT, PRIMARY KEY(`id`));' \
    'CREATE TABLE `spotify_cache` (`id` INTEGER, `track_id` TEXT, `track_name` TEXT, `artist_name` TEXT, `artist_id` TEXT, `cover_art_url` TEXT, `audio_preview_url` TEXT, PRIMARY KEY(`id`));' \
    'CREATE TABLE `yt_thumb_cache` (`id` INTEGER, `yt_id` TEXT, `yt_thumb` TEXT, PRIMARY KEY(`id`));' \
    | sqlite3 data.sqlite

mkdir -p backup
touch wal.log