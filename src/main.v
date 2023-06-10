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
const cache_min_gzip = 1500 // will rarely get hit

[heap]
struct App {
mut:
	media_regex regex.RE
	db sqlite.DB
	cache []CacheEntry = []CacheEntry{cap: cache_max}
	wal os.File // append only
}

fn (mut app App) logln(v string) {
	app.wal.writeln('${time.now()}: ${v}') or {}
	app.wal.flush()
}

fn (mut app App) invalidate_cache() {
	// unsafe { app.cache.len = 0 }
	app.cache = []CacheEntry{cap: cache_max} // force GC to collect old ptrs
}

// return render, use_gzip
fn (mut app App) get_cache(query Query, use_gzip bool) ?(string, bool) {
	// get cache value, increment pop
	// if gzip compression is needed, generate it on demand and cache result

	for mut c in app.cache {
		if c.query == query {
			c.pop++

			// only gzip larger than 1500 bytes
			if use_gzip && c.render.len > cache_min_gzip {
				if render_gzip := c.render_gzip {
					return render_gzip, true
				}
				if val := gzip.compress(c.render.bytes()) {
					render_gzip := val.bytestr()
					c.render_gzip = render_gzip
					return render_gzip, true
				}
			}
			return c.render, false
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
	render_gzip ?string
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

fn get_post(req string) ?Post {
	// tags=test+test&content=It+was+a+dark+and+stormy+night...

	mut content := ?string(none)
	mut tags := ?string(none)

	for word in req.split('&') {
		kv := word.split_nth('=', 2)
		if kv.len != 2 {
			continue
		}
		key := urllib.query_unescape(kv[0]) or { continue }
		val := urllib.query_unescape(kv[1]) or { continue }

		if key == 'content' {
			content = val
		} else if key == 'tags' {
			tags = val
		}
	}

	post := Post{
		created_at: time.now()
		tags: tags?
		content: content?
	}

	return post
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

fn (mut app App) serve_home(req string, is_authed bool, use_gzip bool, mut res phttp.Response) {
	// 1. handle home url
	// 2. parse search queries
	// 3. cache lookup
	// \-- return
	// |
	// 4. access database and rerender
	// 5. enter into popularity cache
	// \-- return

	query := get_query(req)

	// always render new if authed, never cache authed pages

	if !is_authed {
		if render, is_gzip := app.get_cache(query, use_gzip) {
			res.http_ok()
			res.header_date()
			res.html()
			if is_gzip {
				res.write_string('Content-Encoding: gzip\r\n')
			}
			write_all(mut res, render)
			return
		}
	}

	mut db_query := "select * from posts"

	if query.search != "" {
		db_query += " where (content glob '*${sqlsearch(query.search)}*' collate nocase)"
	}
	if query.tags.len != 0 {
		db_query += if query.search != "" {
			" and ("
		} else {
			" where ("
		}

		for idx, t in query.tags {
			tag := t.replace_each(['_', '\\_', '%', '\\%'])

			db_query += "tags like '%${tag}%' escape '\\'"
			if idx + 1 < query.tags.len {
				db_query += " or "
			} else {
				db_query += ")"
			}
		}
	}

	posts := app.raw_query(db_query) or {
		app.logln("/ (posts): failed ${err}")
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
		app.logln("/ (tags): failed ${err}")
		res.http_500()
		res.end()
		return
	}

	mut all_tags := tag_rows.map(Tag{it.vals[0], it.vals[1].int()})
	all_tags.sort(a.count > b.count)

	posts_total := sql app.db {
		select count from Post
	} or { panic("unreachable") }

	// do not cache authed pages

	mut tmpl := $tmpl('tmpl.html')

	res.http_ok()
	res.header_date()
	res.html()
	if !is_authed {
		app.enter_cache(query, tmpl)

		if render, is_gzip := app.get_cache(query, use_gzip) {
			if is_gzip {
				res.write_string('Content-Encoding: gzip\r\n')
			}
			write_all(mut res, render)
		}
	} else {
		// compress on the go, this cannot be cached

		if use_gzip && tmpl.len > cache_min_gzip {
			if val := gzip.compress(tmpl.bytes()) {
				tmpl = val.bytestr()
				res.write_string('Content-Encoding: gzip\r\n')
			}
		}

		write_all(mut res, tmpl)
	}
}

fn see_other(location string, mut res phttp.Response) {
	res.write_string('HTTP/1.1 303 See Other\r\n')
	res.write_string('Location: ${location}\r\n')
	res.write_string('Content-Length: 0\r\n\r\n')
	res.end()
}

fn callback(data voidptr, req phttp.Request, mut res phttp.Response) {
	mut app := unsafe { &App(data) }
	mut use_gzip := false
	mut is_authed := true // TODO: verify!!

	// check for gzip
	for idx in 0..req.num_headers {
		hdr := req.headers[idx]
		if mcmp(hdr.name, hdr.name_len, 'Accept-Encoding') {
			if unsafe { (&u8(hdr.value)).vstring_with_len(hdr.value_len).contains('gzip') } {
				use_gzip = true
			}
			break
		}
	}

	_ = is_authed

	if phttp.cmpn(req.method, 'GET ', 4) {
		if phttp.cmp(req.path, '/') || phttp.cmpn(req.path, '/?', 2) {
			app.serve_home(req.path, is_authed, use_gzip, mut res)
			return
		} else if phttp.cmp(req.path, '/TerminusTTF.woff2') {
			res.http_ok()
			res.header_date()
			res.write_string('Content-Type: font/woff2\r\n')
			write_all(mut res, terminus)
			return
		} else if is_authed {
			if phttp.cmp(req.path, '/backup') {
				file := "backup_${time.now().unix}.sqlite"
				query := "vacuum into '${file}'"
				ret := app.db.exec_none(query)
				if sqlite.is_error(ret) {
					app.logln("/backup: failed ${app.db.error_message(ret, query)}")
					res.http_500()
					res.end()
					return
				}
				app.logln("/backup: created '${file}'")
				see_other('/', mut res)
			}
		}
		res.http_404()
		res.end()
	} else if phttp.cmpn(req.method, 'POST ', 5) {
		if phttp.cmp(req.path, '/post') {
			// body contains urlencoded data
			post := get_post(req.body) or {
				res.write_string('HTTP/1.1 400 Bad Request\r\n')
				res.header_date()
				res.write_string('Content-Length: 0\r\n\r\n')
				res.end()
				return
			}

			sql app.db {
				insert post into Post
			} or {
				app.logln("/post: failed ${err}")
				res.http_500()
				res.end()
				return
			}

			app.invalidate_cache()
			see_other('/#${post.created_at.unix}', mut res)
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
		wal: os.open_append("wal.log")!
	}

	app.logln("begin!")

	/* C.atexit(fn [mut app] () {
		app.db.close() or { panic(err) }
		println('\natexit: goodbye')
	}) */

	os.signal_opt(.int, fn [mut app] (_ os.Signal) {
		app.db.close() or {}
		app.wal.close()
		println('\nsigint: goodbye')
		exit(0)
	})!

	println("http://localhost:8080/")
	picoev.new(port: 8080, cb: &callback, user_data: app, max_write: 8192).serve() // RIGHT UNDER THE MAXIMUM i32 SIGNED VALUE
}
