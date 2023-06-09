import db.sqlite
import regex
import mypicoev as picoev
import mypicohttpparser as phttp
import os
import strings
import compress.gzip
import net.http
import net.urllib

[heap]
struct App {
mut:
	media_regex regex.RE
	db sqlite.DB
	prerendered_home string
}

fn (app &App) fmt_tag(tags []string) string {
	if tags.len == 0 {
		return ''
	}

	mut sb := strings.new_builder(32)

	sb.write_string('[ ')
	for idx, tag in tags {
		sb.write_string(tag)
		sb.write_u8(` `)
		if idx + 1 < tags.len {
			sb.write_string('| ')
		}
	}
	sb.write_string(']')

	return sb.str()
}

struct Query {
mut:
	search string
	tags []string
}

fn get_query(req string) Query {
	// assert req == '/' || req.match_blob('/?*')

	mut query := Query{}

	if req.len == 1 {
		return query
	}

	words := req[2..].split('&')

	for word in words {
		kv := word.split_nth('=', 2)
		if kv.len != 2 {
			continue
		}
		key := urllib.query_unescape(kv[0]) or { continue }

		if key.starts_with('tag_') {
			query.tags << key[4..]
		} else if key == 'search' {
			val := urllib.query_unescape(kv[1]) or { continue }
			query.search = val
		}
	}

	return query
}

fn (mut app App) serve_home(req string, mut res phttp.Response)! {
	// 1. handle home url
	// 2. parse search queries
	// 3. cache lookup
	// \-- return
	// |
	// 4. access database and rerender
	// 5. enter into popularity cache
	// \-- return

	query := get_query(req)
}

fn (mut app App) rerender()! {
	posts_total := sql app.db {
		select count from Post
	}!

	tag_rows, tag_ret := app.db.exec(query_all_tags)
	if sqlite.is_error(tag_ret) {
		return error('error: ${tag_ret}')
	}

	mut all_tags := tag_rows.map(Tag{it.vals[0], it.vals[1].int()})
	all_tags.sort(a.count > b.count)

	//all_tags_fmt := all_tags.map("${it.tag}: ${it.count}")

	posts := sql app.db {
		select from Post
	}!

	// TODO: search args, then cache that

	app.prerendered_home = $tmpl('tmpl.html')
}

fn callback(data voidptr, req phttp.Request, mut res phttp.Response) {
	mut app := unsafe { &App(data) }
	mut accepts_gzip := false
	mut is_authed := false

	// check for gzip
	for idx in 0..req.num_headers {
		hdr := req.headers[idx]
		if mcmp(hdr.name, hdr.name_len, 'Accept-Encoding') {
			if unsafe { (&u8(hdr.value)).vstring_with_len(hdr.value_len).contains('gzip') } {
				accepts_gzip = true
			}
			break
		}
	}

	_ = is_authed

	if phttp.cmpn(req.method, 'GET ', 4) {
		if phttp.cmp(req.path, '/') {
			res.http_ok()
			res.header_date()
			res.html()
			if accepts_gzip {
				// completely cuts the HTML size in HALF!
				// TODO: this should be cached, it also creates unneeded copies

				res.write_string('Content-Encoding: gzip\r\n')
				val := gzip.compress(app.prerendered_home.bytes()) or { panic(err) }
				write_all(mut res, val.bytestr())
			} else {
				write_all(mut res, app.prerendered_home)
			}
		} else if phttp.cmpn(req.path, '/?', 2) {
			println(http.parse_form(req.path[2..]))
			res.http_404()
			res.end()
		} else if phttp.cmp(req.path, '/TerminusTTF.woff2') {
			res.http_ok()
			res.header_date()
			res.write_string('Content-Type: font/woff2\r\n')
			write_all(mut res, terminus)
		} else {
			res.http_404()
			res.end()
		}
	} else {
		res.http_405()
		res.end()
	}
}

fn main() {
	mut app := &App{
		media_regex: regex.regex_opt(r'https?://\S+\.(?:(png)|(jpe?g)|(gif)|(svg)|(webp)|(mp4)|(webm))')!
		db: sqlite.connect("data.sqlite")!
	}

	/* C.atexit(fn [mut app] () {
		app.db.close() or { panic(err) }
		println('\natexit: goodbye')
	}) */

	os.signal_opt(.int, fn [mut app] (_ os.Signal) {
		app.db.close() or { panic(err) }
		println('\nsigint: goodbye')
		exit(0)
	})!

	app.rerender()!
	println("http://localhost:8080/")
	picoev.new(port: 8080, cb: &callback, user_data: app, max_write: 8192).serve() // RIGHT UNDER THE MAXIMUM i32 SIGNED VALUE
}
