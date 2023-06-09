import db.sqlite
import regex
import mypicoev as picoev
import mypicohttpparser as phttp
import os
import strings
import compress.gzip
import net.urllib
import time

const cache_max = 8

[heap]
struct App {
mut:
	media_regex regex.RE
	db sqlite.DB
	cache []CacheEntry = []CacheEntry{cap: cache_max}
}

fn (mut app App) invalidate_cache() {
	unsafe { app.cache.len = 0 }
}

fn (mut app App) get_cache(query Query) ?string {
	// get cache value, increment pop

	for mut c in app.cache {
		if c.query == query {
			c.pop++
			return c.render
		}
	}

	return none
}

fn (mut app App) enter_cache(query Query, render string) {
	// get_cache() should be called before this
	// no point to enter something that is already in the cache

	if app.cache.len < cache_max {
		app.cache << CacheEntry{
			query: query
			render: render
		}
		return
	}

	mut cc_idx := 0

	// locate the cache entry with the lowest pop
	for idx, c in app.cache {
		if c.pop < app.cache[cc_idx].pop {
			cc_idx = idx
		}
	}

	// wipe out old cache value, set pop to 0
	app.cache[cc_idx] = CacheEntry{
		query: query
		render: render
	}
}

struct Query {
mut:
	search string
	tags []string
}

struct CacheEntry {
	query Query
	render string
mut:
	pop u64
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

fn (app &App) dbg_log() {
	for idx, c in app.cache {
		eprintln("${idx}: (${c.pop}) '${c.query.search}' > ${c.query.tags}")
	}
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
			query.tags << key[4..].to_lower()
		} else if key == 'search' {
			val := urllib.query_unescape(kv[1]) or { continue }
			query.search = val
		}
	}

	return query
}

fn (app &App) raw_query(query string) ![]sqlite.Row {
	rows, ret := app.db.exec(query)

	if sqlite.is_error(ret) {
		return app.db.error_message(ret, query)
	}

	return rows
}

const sqlsearch_replace = [
	"\t", "*"
	"\n", "*"
	"\v", "*"
	"\f", "*"
	"\r", "*"
	" ", "*"
	"'", "''" // sqlescape
]

fn sqlsearch(a string) string {
	return a.replace_each(sqlsearch_replace)
}

fn (mut app App) serve_home(req string, mut res phttp.Response) {
	// 1. handle home url
	// 2. parse search queries
	// 3. cache lookup
	// \-- return
	// |
	// 4. access database and rerender
	// 5. enter into popularity cache
	// \-- return

	query := get_query(req)

	if render := app.get_cache(query) {
		res.http_ok()
		res.header_date()
		res.html()
		write_all(mut res, render) // TODO: handle gzip
		return
	}
	eprintln("cache MISS: ${query}")

	mut db_query := "select * from posts"

	if query.search != "" {
		db_query += " where (content glob '*${sqlsearch(query.search)}*' collate nocase)"
	}

	posts := app.raw_query(db_query) or {
		eprintln("${time.now()}: ${err}")
		res.http_500()
		res.end()
		return
	}.map(Post{
		id: it.vals[0].int()
		created_at: time.unix(it.vals[1].i64())
		tags: it.vals[2]
		content: it.vals[3]
	})

	tag_rows := app.raw_query(query_all_tags) or {
		eprintln("${time.now()}: ${err}")
		res.http_500()
		res.end()
		return
	}

	mut all_tags := tag_rows.map(Tag{it.vals[0], it.vals[1].int()})
	all_tags.sort(a.count > b.count)

	posts_total := sql app.db {
		select count from Post
	} or { panic(err) }

	render := $tmpl('tmpl.html')
	app.enter_cache(query, render)

	res.http_ok()
	res.header_date()
	res.html()
	write_all(mut res, render) // TODO: handle gzip

	// eprintln(posts)
	// eprintln(all_tags)
	// eprintln(db_query)
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
		if phttp.cmp(req.path, '/') || phttp.cmpn(req.path, '/?', 2) {
			res.http_ok()
			res.header_date()
			res.html()
			app.serve_home(req.path, mut res)
			app.dbg_log()
			/* if accepts_gzip {
				// completely cuts the HTML size in HALF!
				// TODO: this should be cached, it also creates unneeded copies

				res.write_string('Content-Encoding: gzip\r\n')
				val := gzip.compress(app.prerendered_home.bytes()) or { panic(err) }
				write_all(mut res, val.bytestr())
			} else {
				write_all(mut res, app.prerendered_home)
			} */
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

	println("http://localhost:8080/")
	picoev.new(port: 8080, cb: &callback, user_data: app, max_write: 8192).serve() // RIGHT UNDER THE MAXIMUM i32 SIGNED VALUE
}
