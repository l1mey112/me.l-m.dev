import spotify

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

	// TODO: this may cause a race condition with `app.invalidate_cache`
	//
	spawn app.req_spotify(url)

	return none
}

fn (mut app App) req_spotify(url string) {
	// TODO: a malformed url may cause constant requests
	//
	spotify_track := spotify.get(url) or { return } // will take time!

	track := SpotifyTrack{
		track_id: spotify_track.id
		track_name: spotify_track.name
		artist_name: spotify_track.artist
		artist_id: spotify_track.artist_id
		cover_art_url: spotify_track.cover_art_url
		audio_preview_url: spotify_track.audio_preview_url or { '' }
	}

	count := sql app.db {
		select count from SpotifyTrack where track_id == track.track_id
	} or {
		app.logln("spotify_cache(count_existing): failed ${err}")
		return
	}

	if count != 0 {
		return
	}

	sql app.db {
		insert track into SpotifyTrack
	} or {
		app.logln("spotify_cache(insert): failed ${err}")
		return
	}

	app.invalidate_cache()
}