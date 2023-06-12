module spotify

import net.http
import regex
import encoding.base64
import json

struct RootCoverArt {
	url    string
	width  int
	height int
}

struct RootArtist {
	id string
	profile struct {
		name string
	}
}

struct RootTrack {
	id             string
	name           string
	uri            string
	album_of_track struct {
		cover_art struct {
			sources []RootCoverArt
		} [json: coverArt]
	} [json: albumOfTrack]

	previews struct {
		audio_previews struct {
			items []struct {
				url string
			}
		} [json: audioPreviews]
	}

	first_artist struct {
		items []RootArtist
	} [json: firstArtist]
}

struct Root {
	entities struct {
		items map[string]RootTrack
	}
}

pub struct Track {
pub:
	id                string
	name              string
	artist            string
	artist_id         string
	cover_art_url     string
	audio_preview_url ?string
}

const query = r'<script\s+id="initial-state"\s+type="text/plain">([^<]+)</script>'

fn largest_cover_art(sources []RootCoverArt) ?string {
	mut root_art := sources[0] or { return none }

	for i := 1; i < sources.len ; i++ {
		size := sources[i].width * sources[i].height
		root_size := root_art.width * root_art.height
		
		if size > root_size {
			root_art = sources[i]
		}
	}

	return root_art.url
}

// https://open.spotify.com/track/$track_id
// https://open.spotify.com/artist/$artist_id

pub fn get(url string) ?Track {
	resp := http.get(url) or { return none }

	mut re := regex.regex_opt(spotify.query) or { panic('unreachable') }

	s, _ := re.find_from(resp.body, 0)
	if s < 0 {
		return none
	}

	base64_content := re.get_group_by_id(resp.body, 0)
	json_src := base64.decode_str(base64_content)

	obj := json.decode(Root, json_src) or { return none }

	key := obj.entities.items.keys()[0] or {
		return none
	}

	root_track := obj.entities.items[key]

	mut preivew_url := ?string(none)
	if val := root_track.previews.audio_previews.items[0] {
		preivew_url = val.url
	}

	if root_track.first_artist.items.len <= 0 {
		return none
	}

	profile := root_track.first_artist.items[0]

	return Track{
		id: root_track.id
		name: root_track.name
		artist: profile.profile.name
		artist_id: profile.id
		cover_art_url: largest_cover_art(root_track.album_of_track.cover_art.sources)?
		audio_preview_url: preivew_url
	}
}
