// Copyright (c) 2023 l-m.dev. All rights reserved.
// Use of this source code is governed by an AGPL license
// that can be found in the LICENSE file.// Copyright (c) 2023 l-m.dev. All rights reserved.
// Use of this source code is governed by an AGPL license
// that can be found in the LICENSE file.
import spotify
import yt

type YT_ID = string
type SPOTIFY_ID = string
type Status = YT_ID | SPOTIFY_ID

fn (mut app App) worker() {
	mut payload := unsafe { Status{} }
	
	for {
		payload = <-app.ch

		match payload {
			YT_ID {
				app.req_youtube(payload as YT_ID)
			}
			SPOTIFY_ID {
				app.req_spotify(payload as SPOTIFY_ID)
			}
		}

		// kill caches
		app.invalidate_cache(.invalidate_meta)
	}
}

[table: 'spotify_cache']
struct SpotifyTrack {
	id                int [primary; sql: serial]
	track_id          string
	track_name        string
	artist_name       string
	artist_id         string
	cover_art_url     string
	audio_preview_url string
}

fn (mut app App) get_spotify(url string, id string) ?SpotifyTrack {
	// 1. check DB
	// \-- return track
	// |
	// 2. spawn thread, request spotify
	// 3. enter into DB
	// \-- return none

	// when the entry to a DB is made
	// the cache will be invalidated
	// so that spotify embeds can be made

	// 'https://open.spotify.com/track/xxxxx?si=xxxxx'.after('open.spotify.com/track/').before('?')

	track := sql app.db {
		select from SpotifyTrack where track_id == id
	} or {
		app.logln("spotify_cache(get): failed ${err}")
		return none
	}

	if track.len > 0 {
		return track[0]
	}

	app.ch <- SPOTIFY_ID(id)

	return none
}

fn (mut app App) req_spotify(id string) {
	count := sql app.db {
		select count from SpotifyTrack where track_id == id
	} or {
		app.logln("spotify_cache(count_existing): failed ${err}")
		return
	}

	if count != 0 {
		return
	}

	// TODO: a malformed url may cause constant requests
	spotify_track := spotify.get('https://open.spotify.com/track/$id') or { return } // will take time!

	track := SpotifyTrack{
		track_id: spotify_track.id
		track_name: spotify_track.name
		artist_name: spotify_track.artist
		artist_id: spotify_track.artist_id
		cover_art_url: spotify_track.cover_art_url
		audio_preview_url: spotify_track.audio_preview_url or { '' }
	}

	sql app.db {
		insert track into SpotifyTrack
	} or {
		app.logln("spotify_cache(insert): failed ${err}")
		return
	}
}

[table: 'yt_thumb_cache']
struct YtThumbnail {
	id int [primary; sql: serial]
	yt_id    string
	yt_thumb string
}

fn (mut app App) get_youtube(id string) string {
	rows := sql app.db {
		select from YtThumbnail where yt_id == id
	} or {
		app.logln("yt_thumb_cache(get): failed ${err}")
		return yt.yt_default
	}

	if rows.len > 0 {
		return rows[0].yt_thumb
	}

	app.ch <- YT_ID(id)

	return yt.yt_default
}

fn (mut app App) req_youtube(id string) {
	count := sql app.db {
		select count from YtThumbnail where yt_id == id
	} or {
		app.logln("yt_thumb_cache(count_existing): failed ${err}")
		return
	}

	if count != 0 {
		return
	}

	if thumb := yt.get_embed(id) {
		tthumb := YtThumbnail{yt_id: id, yt_thumb: thumb}

		sql app.db {
			insert tthumb into YtThumbnail
		} or {
			app.logln("yt_thumb_cache(insert): failed ${err}")
			return
		}
	}
}
