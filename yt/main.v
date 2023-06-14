module yt

import net.http

pub const yt_prepend = "https://i3.ytimg.com/vi/"
pub const yt_default = "0.jpg"

const strs = [
	"maxresdefault.jpg"
	"mqdefault.jpg"
	"0.jpg" // always present
]

pub fn get_embed(id string) ?string {
	for v in strs {
		r := http.get('https://i3.ytimg.com/vi/${id}/${v}') or {
			return none
		}

		if r.status_code != 404 {
			return v
		}
	}

	return none
}
