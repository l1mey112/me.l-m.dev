// Copyright (c) 2023 l-m.dev. All rights reserved.
// Use of this source code is governed by an AGPL license
// that can be found in the LICENSE file.
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

	return yt_default // worst case
}
