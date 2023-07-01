// Copyright (c) 2023 l-m.dev. All rights reserved.
// Use of this source code is governed by an AGPL license
// that can be found in the LICENSE file.
import db.sqlite
import regex
import picoev
import picohttpparser as phttp
import os
import strings
import net.urllib
import time
import strconv
import sync.stdatomic
import crypto.sha256
import hash

const env_port = os.getenv("PORT")
const secret_password = os.getenv("SECRET")
const secret_cookie = sha256.hexhash("${time.now().unix}-${secret_password}")
const base_url = 'https://me.l-m.dev/'
const cache_max = 32 // larger!
const posts_per_page = 25

[heap]
struct App {
mut:
	media_regex regex.RE
	spotify_regex regex.RE
	youtube_regex regex.RE
	db sqlite.DB
	last_edit_time time.Time // caches are invalidated at that time
	cache []CacheEntry = []CacheEntry{cap: cache_max}
	cache_rss ?string
	cache_flag i64 // atomic
	wal os.File // append only
	ch chan Status // worker
}

fn (mut app App) logln(v string) {
	app.wal.writeln('${time.now()}: ${v}') or {}
	app.wal.flush()
}

fn (mut app App) invalidate_cache() {
	if stdatomic.load_i64(&app.cache_flag) == 0 {
		stdatomic.store_i64(&app.cache_flag, 1)
	}
}

fn (mut app App) invalidate_cache_do() {
	if stdatomic.load_i64(&app.cache_flag) == 1 {
		// unsafe { app.cache.len = 0 }
		app.last_edit_time = time.now()
		app.cache = []CacheEntry{cap: cache_max} // force GC to collect old ptrs
		app.cache_rss = none

		stdatomic.store_i64(&app.cache_flag, 0)
	}
}

// return render, use_gzip
fn (mut app App) get_cache(query Query) ?string {
	// get cache value, increment pop
	// if gzip compression is needed, generate it on demand and cache result

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

struct SearchQuery {
mut:
	search string
	tags []string
	page u64
}

struct PostQuery {
	post i64
}

type Query = SearchQuery | PostQuery

struct CacheEntry {
	query Query
	render string
mut:
	pop u64
}

fn fmt_tag(tags []string) string {
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

fn get_post(req string) ?(Post, bool) {
	// tags=test+test&content=It+was+a+dark+and+stormy+night...

	mut content := ?string(none)
	mut tags := ?string(none)
	mut created_at := ?time.Time(none)
	mut is_update := false

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
		} else if key == 'post_id' {
			unix := i64(strconv.parse_uint(val, 10, 64) or {
				continue
			})
			created_at = time.unix(unix)
			is_update = true
		}
	}

	post := Post{
		created_at: if unix := created_at { unix } else { time.now() } 
		tags: tags?
		content: content?
	}

	return post, is_update
}

fn get_query(req string) SearchQuery {
	// assert req == '/' || req.match_blob('/?*')

	mut query := SearchQuery{}

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
		} else if key == 'page' {
			page := strconv.parse_uint(kv[1], 10, 64) or { continue }
			query.page = page
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

const xmlescape_replace = [
	"\"", "&quot;"
	"'", "&apos;"
	"<", "&lt;"
	">", "&gt;"
	"&", "&amp;"
]

fn xmlescape(a string) string {
	return a.replace_each(xmlescape_replace)
}

fn (mut app App) serve_rss(mut res phttp.Response) {
	if app.cache_rss == none {
		posts := sql app.db {
			select from Post
		} or {
			panic('unreachable')
		}

		app.cache_rss = $tmpl('tmpl/tmpl.xml')
	}

	res.http_ok()
	res.header_date()
	res.write_string('Content-Type: application/rss+xml\r\n')

	if cache_rss := app.cache_rss {
		write_all(mut res, cache_rss)
		return
	}
}

fn (app &App) etag(req string) u64 {
	return hash.wyhash_c(req.str, u64(req.len), u64(app.last_edit_time.unix))
}

fn construct_article_header(created_at i64, latest i64, selected ?i64) string {	
	mut ret := if created_at == latest {
		'<div id=latest><article'
	} else {
		'<article'
	}

	if sel := selected {
		if sel == created_at {
			ret += ' class=lat id="#"'
		}
	} else if latest == created_at {
		ret += ' class=lat'
	}

	return ret + '>'
}

fn construct_tags(post &Post) string {
	return fmt_tag(post.tags.split(' '))
}

fn (mut app App) serve_home(req string, is_authed bool, mut res phttp.Response) {
	// edit post by unix (AUTH ONLY)
	//   /?edit=123456789

	// 1. handle home url
	// 2. parse search queries
	// 3. cache lookup
	// \-- return
	// |
	// 4. access database and rerender
	// 5. enter into popularity cache
	// \-- return

	// a non ?Post is more convienent to $tmpl()
	mut edit_is := false
	mut target_post := Post{
		content: 'It was a dark and stormy night...'
	}

	// ignore and pass if not authed
	if phttp.cmpn(req, '/?edit=', 7) {
		if !is_authed {
			forbidden_go_auth(mut res)
			return
		}
		unix := time.unix(i64(strconv.parse_uint(req[7..], 10, 64) or {
			res.write_string('HTTP/1.1 400 Bad Request\r\n')
			res.header_date()
			res.write_string('Content-Length: 0\r\n\r\n')
			res.end()
			return
		}))

		rows := sql app.db {
		    select from Post where created_at == unix limit 1
		} or {
			res.http_404()
			res.end()
			return
		}

		edit_is = true
		if rows.len != 0 {
			target_post = rows[0]
		} else {
			target_post.created_at = unix
		}
	}

	mut query := unsafe { Query{} }

	if phttp.cmpn(req, '/?p=', 4) {
		unix := i64(strconv.parse_uint(req[4..], 10, 64) or {
			res.write_string('HTTP/1.1 400 Bad Request\r\n')
			res.header_date()
			res.write_string('Content-Length: 0\r\n\r\n')
			res.end()
			return
		})
		query = PostQuery{unix}
	} else if !edit_is {
		query = get_query(req)
	}

	// always render new if authed, never cache authed pages

	etag := app.etag(req)

	if !is_authed {
		if render := app.get_cache(query) {
			res.http_ok()
			res.header_date()
			res.html()
			res.write_string('ETag: "${etag}"\r\n')
			res.write_string('Cache-Control: max-age=86400, must-revalidate\r\n')
			write_all(mut res, render)
			return
		}
	}

	mut db_query := "select * from posts"

	mut page := u64(0)
	mut post_to_select := ?i64(none)

	if !edit_is {
		match mut query {
			SearchQuery {
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
							db_query += " and "
						} else {
							db_query += ")"
						}
					}
				}
				page = query.page
			}
			PostQuery {
				post_to_select = query.post
				if query.post != 0 {
					rows := app.raw_query("select count(*) from posts where (created_at >= ${query.post} or created_at == 0) order by (case when created_at = 0 then 1 else 2 end), created_at desc;") or {
						app.logln("/: failed ${err}")
						res.http_500()
						res.end()
						return
					}
					if rows.len == 1 && rows[0].vals.len == 1 {
						posts_from_start := rows[0].vals[0].u64()
						page = (posts_from_start - 1) / posts_per_page
					}
				}
			}
		}
	} else {
		db_query += " where created_at = ${target_post.created_at.unix}"
	}

	if req == '/' || req.starts_with('/?p=') {
		// place unix 0 at the top, this post is pinned
		db_query += " order by (case when created_at = 0 then 1 else 2 end), created_at desc"
	} else {
		db_query += " order by created_at desc"
	}

	db_query += " limit ${posts_per_page} offset ${posts_per_page * page}"

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
	} or {
		app.logln("/: failed ${err}")
		res.http_500()
		res.end()
		return
	}

	mut latest_post_unix := i64(0)
	latest_post_unix_rows := app.raw_query("select created_at from posts order by created_at desc limit 1") or {
		app.logln("/: failed ${err}")
		res.http_500()
		res.end()
		return
	}
	if latest_post_unix_rows.len != 0 {
		latest_post_unix = latest_post_unix_rows[0].vals[0].i64()
	}

	mut selected_post_idx := -1
	if sel := post_to_select {
		for idx, p in posts {
			if p.created_at.unix == sel {
				selected_post_idx = idx 
			}
		}
	}

	// do not cache authed pages

	mut tmpl := $tmpl('tmpl/tmpl.html')

	res.http_ok()
	res.header_date()
	res.html()
	if !is_authed {
		app.enter_cache(query, tmpl)

		if render := app.get_cache(query) {
			res.write_string('ETag: "${etag}"\r\n')
			res.write_string('Cache-Control: max-age=86400, must-revalidate\r\n')
			/* if is_gzip {
				res.write_string('Content-Encoding: gzip\r\n')
			} */
			write_all(mut res, render)
		}
	} else {
		// compress on the go, this cannot be cached

		/* if use_gzip && tmpl.len > cache_min_gzip {
			if val := gzip.compress(tmpl.bytes()) {
				tmpl = val.bytestr()
				res.write_string('Content-Encoding: gzip\r\n')
			}
		} */
		res.write_string('Cache-Control: no-cache\r\n')
		write_all(mut res, tmpl)
	}
}

fn forbidden_go_auth(mut res phttp.Response) {
	res.write_string('HTTP/1.1 403 Forbidden\r\n')
	res.header_date()
	res.html()
	write_all(mut res, $tmpl('tmpl/redirect_tmpl.html'))
}

fn moved_permanently(location string, mut res phttp.Response) {
	res.write_string('HTTP/1.1 301 Moved Permanently\r\n')
	res.write_string('Location: ${location}\r\n')
	res.write_string('Content-Length: 0\r\n\r\n')
	res.end()
}

fn see_other(location string, mut res phttp.Response) {
	res.write_string('HTTP/1.1 303 See Other\r\n')
	res.write_string('Location: ${location}\r\n')
	res.write_string('Content-Length: 0\r\n\r\n')
	res.end()
}

fn callback(data voidptr, req phttp.Request, mut res phttp.Response) {
	mut app := unsafe { &App(data) }
	mut is_authed := false
	mut etag := ?u64(none)

	// atomic prepare request
	app.invalidate_cache_do()

	// check for gzip and auth
	for idx in 0..req.num_headers {
		hdr := req.headers[idx]
		if mcmp(hdr.name, hdr.name_len, 'Cookie') {
			str := unsafe { (&u8(hdr.value)).vstring_with_len(hdr.value_len) }

			for v in str.split('; ') {
				if v.starts_with('auth=') {
					if v.after('auth=') == secret_cookie {
						is_authed = true
					}
					break
				}
			}
		} else if mcmp(hdr.name, hdr.name_len, 'If-None-Match') {
			str := unsafe { (&u8(hdr.value)).vstring_with_len(hdr.value_len) }

			if str.len >= 3 {
				// "x"
				etag = str[1..str.len - 1].u64()
			}
		}
	}

	if e := etag {
		if e == app.etag(req.path) && !is_authed {
			res.write_string('HTTP/1.1 304 Not Modified\r\n')
			res.write_string('ETag: "${e}"\r\n')
			res.write_string('Cache-Control: max-age=86400, must-revalidate\r\n')
			res.header_date()
			res.write_string('Content-Length: 0\r\n\r\n')
			res.end()
			return
		}
	}

	if phttp.cmpn(req.method, 'GET ', 4) {
		if phttp.cmpn(req.path, '/?meta=', 7) {
			v := i64(strconv.parse_uint(req.path[7..], 10, 64) or {
				res.write_string('HTTP/1.1 400 Bad Request\r\n')
				res.header_date()
				res.write_string('Content-Length: 0\r\n\r\n')
				res.end()
				return
			})
			moved_permanently("/?p=${v}##", mut res)
			return
		} else if phttp.cmp(req.path, '/') || phttp.cmpn(req.path, '/?', 2) {
			app.serve_home(req.path, is_authed, mut res)
			return
		} else if phttp.cmp(req.path, '/index.xml') {
			app.serve_rss(mut res)
			return
		} else if phttp.cmp(req.path, '/TerminusTTF.woff2') {
			res.http_ok()
			res.header_date()
			res.write_string('Content-Type: font/woff2\r\n')
			res.write_string('Cache-Control: max-age=31536000, immutable\r\n') // never changes, 1 year
			write_all(mut res, terminus)
			return
		} else if phttp.cmp(req.path, '/auth') {
			res.http_ok()
			res.header_date()
			res.html()
			write_all(mut res, $tmpl('tmpl/auth_tmpl.html'))
			return
		} else if phttp.cmp(req.path, '/backup') {
			if !is_authed {
				forbidden_go_auth(mut res)
				return
			}

			file := "backup/backup_${time.now().unix}.sqlite"
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
			return
		} else if phttp.cmpn(req.path, '/delete/', 8) {
			if !is_authed {
				forbidden_go_auth(mut res)
				return
			}

			post_created_at := time.unix(i64(strconv.parse_uint(req.path[8..], 10, 64) or {
				res.write_string('HTTP/1.1 400 Bad Request\r\n')
				res.header_date()
				res.write_string('Content-Length: 0\r\n\r\n')
				res.end()
				return
			}))

			sql app.db {
				delete from Post where created_at == post_created_at
			} or {
				res.write_string('HTTP/1.1 400 Bad Request\r\n')
				res.header_date()
				res.write_string('Content-Length: 0\r\n\r\n')
				res.end()
				return
			}

			app.logln("/delete: deleted /#${post_created_at.unix}")

			// redirect to the next post
			if row := app.db.exec_one('select created_at from posts where created_at > ${post_created_at.unix} order by created_at limit 1') {
				nearest_created_at := row.vals[0].int() // created_at
				if nearest_created_at != 0 {
					see_other('/#${nearest_created_at}', mut res)
					return
				}
			}
			see_other('/', mut res)
			return
		}
		res.http_404()
		res.end()
	} else if phttp.cmpn(req.method, 'POST ', 5) {
		if phttp.cmp(req.path, '/auth') {
			// auth=....
			// Set-Cookie: cookieName=cookieValue; Secure; SameSite=Strict
			pwd := req.body.all_after('auth=')

			if pwd == secret_password {
				res.write_string('HTTP/1.1 303 See Other\r\n')
				res.write_string('Location: /\r\n')
				res.write_string('Set-Cookie: auth=${secret_cookie}; SameSite=Strict\r\n') // removed `Secure;`, often hosted without https
				res.write_string('Content-Length: 0\r\n\r\n')
				res.end()
				return
			}

			res.write_string('HTTP/1.1 403 Forbidden\r\n')
			res.header_date()
			res.html()
			write_all(mut res, $tmpl('tmpl/auth_failed_tmpl.html'))
			return
		} else if phttp.cmp(req.path, '/post') {
			if !is_authed {
				forbidden_go_auth(mut res)
				return
			}

			// body contains urlencoded data
			post, _ := get_post(req.body) or {
				res.write_string('HTTP/1.1 400 Bad Request\r\n')
				res.header_date()
				res.write_string('Content-Length: 0\r\n\r\n')
				res.end()
				return
			}

			// check if exists
			count := sql app.db {
				select count from Post where created_at == post.created_at
			} or {
				app.logln("/post: update: failed ${err}")
				return
			}

			if count == 0 {
				sql app.db {
					insert post into Post
				} or {
					app.logln("/post: failed ${err}")
					res.http_500()
					res.end()
					return
				}
				app.logln("/post: created /#${post.created_at.unix}")
			} else {
				sql app.db {
					update Post set content = post.content, tags = post.tags where created_at == post.created_at
				} or {
					app.logln("/post: update /#${post.created_at} failed ${err}")
					res.http_500()
					res.end()
					return
				}
				app.logln("/post: update /#${post.created_at.unix}")
			}

			app.invalidate_cache()
			see_other('/?p=${post.created_at.unix}##', mut res)
			return
		}
		res.http_404()
		res.end()
	} else {
		res.http_405()
		res.end()
	}
}

// #000000000 -> DEPRECATE, the server cannot see this
//
// ?p=000000000 -> links to post, and contains meta information
// ?page=10 -> supported in a search query

// ?p=000000000## -> links to post and jumps to id="#"
//                   much better solution

fn main() {
	mut app := &App{
		media_regex: regex.regex_opt(r'https?://\S+\.(?:(png)|(jpe?g)|(gif)|(svg)|(webp)|(mp4)|(webm)|(mov))')!
		spotify_regex: regex.regex_opt(r'https?://open\.spotify\.com/track/(\S+)')!
		youtube_regex: regex.regex_opt(r"https?://(?:www\.)?youtu(?:be\.com/watch\?v=)|(?:\.be/)(\S+)")!
		db: sqlite.connect("data.sqlite")!
		wal: os.open_append("wal.log")!
		last_edit_time: time.now()
		ch: chan Status{cap: 8}
	}

	os.signal_opt(.int, fn [mut app] (_ os.Signal) {
		app.db.close() or {}
		app.wal.close()
		println('\nsigint: goodbye')
		exit(0)
	})!

	assert secret_password != ''
	assert os.is_dir('backup')

	eport := env_port.int()
	port := if eport == 0 { 8080 } else { eport }

	println("http://localhost:${port}/")
	spawn app.worker()
	picoev.new(port: port, cb: &callback, user_data: app, max_read: 8192, max_write: 8192).serve() // RIGHT UNDER THE MAXIMUM i32 SIGNED VALUE
}
