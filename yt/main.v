module yt

import net.http

const default = "0.jpg"

const strs = [
	"maxresdefault.jpg"
	"mqdefault.jpg"
]

pub fn get_embed(id string) string {
	for v in strs {
		r := http.get('https://i3.ytimg.com/vi/${id}/${v}') or {
			return default
		}

		if r.status_code != 404 {
			return v
		}
	}

	return default
}
