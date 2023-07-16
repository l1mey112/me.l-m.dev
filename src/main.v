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

enum CacheStatus as i64 { // i know that `as i64` isn't implemented yet
	clean = 0
	invalidate_posts // essentially invalidate all
	invalidate_meta // spotify and yt thumbs
}

[heap]
struct App {
mut:
	media_regex regex.RE
	spotify_regex regex.RE
	youtube_regex regex.RE
	db sqlite.DB
	stats struct {
	mut:
		posts u64
		tags u64
		last_edit_time time.Time // caches are invalidated at that time
	}
	cache []CacheEntry = []CacheEntry{cap: cache_max}
	cache_rss ?string
	cache_embed ?string
	cache_flag i64 // CacheStatus enum
	wal os.File // append only
	ch chan Status // worker
}

fn to_unix_str(v string) string {
	return time.unix(v.i64()).utc_string()
}

fn (mut app App) logln(v string) {
	app.wal.writeln('${time.now()}: ${v}') or {}
	app.wal.flush()
}

// TODO: some kind of spinlock?

fn (mut app App) invalidate_cache(status CacheStatus) {
	// i don't want to overwrite a .invalidate_posts with a .invalidate_meta
	current_status := unsafe { CacheStatus(stdatomic.load_i64(&app.cache_flag)) }

	if current_status == .invalidate_posts {
		return
	}
	
	stdatomic.store_i64(&app.cache_flag, i64(status))
}

fn (mut app App) invalidate_cache_do()! {
	// TODO: do a CAS here

	status := unsafe { CacheStatus(stdatomic.load_i64(&app.cache_flag)) }

	if status == .clean {
		return
	}

	// .invalidate_posts | .invalidate_meta

	if status == .invalidate_posts {
		app.stats.last_edit_time = time.now()
		app.stats.posts = u64(sql app.db {
			select count from Post
		} or {
			return error('failed to count posts, ${err}')
		})
		app.stats.tags = app.raw_query(query_count_tags) or {
			return error("failed to count tags, ${err}")		
		}[0].vals[0].u64()
	}

	app.cache = []CacheEntry{cap: cache_max} // force GC to collect old ptrs
	app.cache_rss = none
	app.cache_embed = none

	stdatomic.store_i64(&app.cache_flag, i64(CacheStatus.clean))
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
mut:
	post i64
	img i64 = -1 // -1 is none
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

fn get_search_query(req string) SearchQuery {
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
	$if trace_orm ? {
		eprintln('raw_query: ' + query)
	}
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
			select from Post order by created_at desc
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
	}
}

fn (mut app App) serve_embed(req string, mut res phttp.Response) {
	if app.cache_embed == none {
		rows := app.raw_query('select created_at, tags from posts order by created_at desc limit 10;') or {
			app.logln("/embed: failed ${err}")		
			res.http_500()
			res.end()
			return
		}

		app.cache_embed = $tmpl('tmpl/embed.html')
	}
	
	etag := app.etag(req)
	res.http_ok()
	res.header_date()
	res.html()
	res.write_string('ETag: "${etag}"\r\n')
	res.write_string('Cache-Control: max-age=0, must-revalidate\r\n')

	if cache_embed := app.cache_embed {
		write_all(mut res, cache_embed)
	}
}

fn (app &App) etag(req string) u64 {
	return hash.wyhash_c(req.str, u64(req.len), u64(app.stats.last_edit_time.unix))
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

fn construct_tags(tags string) string {
	if tags == '' {
		return ''
	}
	
	return fmt_tag(tags.split(' '))
}

fn construct_tags_query(tags []string) string {
	mut sb := strings.new_builder(24)

	for idx, tag in tags {
		sb.write_string("tag_${urllib.query_escape(tag)}=on")
		if idx + 1 < tags.len {
			sb.write_u8(`&`)
		}
	}

	return sb.str()
}

fn construct_next(query Query, post_page u64, no_next bool) ?string {
	if no_next {
		return none
	}

	match query {
		SearchQuery{
			mut q := '?page=${query.page + 1}'

			if query.search != '' {
				q += '&search=${urllib.query_escape(query.search)}'
			}

			if query.tags.len != 0 {
				q += '&${construct_tags_query(query.tags)}'
			}

			return q
		}
		PostQuery{
			return '?page=${post_page + 1}'
		}
	}
}

fn construct_last_page(query Query, post_page u64, pages u64, no_next bool) ?string {
	if no_next || pages == 0 || pages - 1 == post_page {
		return none
	}

	match query {
		SearchQuery{
			mut q := '?page=${pages - 1}'

			if query.search != '' {
				q += '&search=${urllib.query_escape(query.search)}'
			}

			if query.tags.len != 0 {
				q += '&${construct_tags_query(query.tags)}'
			}

			return q
		}
		PostQuery{
			return '?page=${pages - 1}'
		}
	}
}

fn construct_previous(query Query, post_page u64) ?string {
	if post_page == 0 {
		return none
	}

	match query {
		SearchQuery{
			if query.page == 0 {
				return none
			}

			mut q := '?'

			if query.page != 1 {
				q += 'page=${query.page - 1}'
			}

			if query.search != '' {
				q += '&search=${urllib.query_escape(query.search)}'
			}

			if query.tags.len != 0 {
				q += '&${construct_tags_query(query.tags)}'
			}

			if q == '?' {
				return ''
			}

			return q
		}
		PostQuery{
			return '?page=${post_page - 1}'
		}
	}
}

fn construct_first_page(query Query, post_page u64) ?string {
	if post_page == 0 {
		return none
	}

	match query {
		SearchQuery{
			if query.page == 0 {
				return none
			}

			if query.search == '' && query.tags.len == 0 {
				return ''
			}

			mut q := '?page=0'

			if query.search != '' {
				q += '&search=${urllib.query_escape(query.search)}'
			}

			if query.tags.len != 0 {
				q += '&${construct_tags_query(query.tags)}'
			}

			return q
		}
		PostQuery{
			return ''
		}
	}
}

fn (mut app App) get_meta_img_count(post Post) i64 {
	// 'https?://\S+\.(?:(png)|(jpe?g)|(gif)|(svg)|(webp)|(mp4)|(webm)|(mov))'

	media := app.media_regex.find_all_str(post.content)

	mut nidx := i64(0)
	for m in media {
		if m.ends_with('mp4') || m.ends_with('webm') || m.ends_with('mov') {
			continue
		} 

		nidx++
	}

	return nidx
}

fn (mut app App) find_meta_img(post Post, img i64) ?string {
	// 'https?://\S+\.(?:(png)|(jpe?g)|(gif)|(svg)|(webp)|(mp4)|(webm)|(mov))'

	media := app.media_regex.find_all_str(post.content)

	// i would love to do a .filter() but V incurs a cost that way

	mut nidx := i64(0)
	for m in media {
		if m.ends_with('mp4') || m.ends_with('webm') || m.ends_with('mov') {
			continue
		} 

		if nidx == img {
			return m
		}
		
		nidx++
	}

	return none
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
	if req.starts_with('/?edit=') {
		if !is_authed {
			forbidden_go_auth(mut res)
			return
		}
		unix := time.unix(i64(strconv.parse_uint(req[7..], 10, 64) or {
			unsafe { goto bad_req }
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

	if req.starts_with('/?p=') {
		mut post := PostQuery{post: -1}
		
		words := req[2..].split('&')

		for word in words {
			kv := word.split_nth('=', 2)
			if kv.len != 2 {
				continue
			}

			// oh how i love `goto`
			key := kv[0]
			val := kv[1]
			if key == 'p' {
				post.post = i64(strconv.parse_uint(val, 10, 64) or {
					unsafe { goto bad_req }
					return
				})
			} else if key == 'img' {
				post.img = i64(strconv.parse_uint(val, 10, 64) or {
					unsafe { goto bad_req }
					return
				})
			}
		}

		// req.starts_with('/?p=')
		// -> assume that `post.unix` is set

		query = post
	} else if !edit_is {
		query = get_search_query(req)
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

	mut db_query := ""

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
					rows := app.raw_query("select count(*) from posts where (created_at >= ${query.post} or created_at == 0) order by (case when created_at = 0 then 1 else 2 end), created_at desc") or {
						app.logln("/: failed ${err}")
						res.http_500()
						res.end()
						return
					}
					if rows.len == 1 && rows[0].vals.len == 1 {
						posts_from_start := rows[0].vals[0].u64()
						if posts_from_start != 0 {
							page = (posts_from_start - 1) / posts_per_page
						}
					}
				}
			}
		}
	} else {
		db_query += " where created_at = ${target_post.created_at.unix}"
	}

	db_query += " order by (case when created_at = 0 then 1 else 2 end), created_at desc"

	total_count_from_search := app.raw_query("select count(*) from posts${db_query}") or {
		app.logln("/ (count): failed ${err}")
		res.http_500()
		res.end()
		return
	}[0].vals[0].u64()

	total_pages_from_search := (total_count_from_search + posts_per_page - 1) / posts_per_page

	db_query += " limit ${posts_per_page} offset ${posts_per_page * page}"

	posts := app.raw_query("select * from posts${db_query}") or {
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
	mut meta_description := ''
	mut meta_image_url := ?string(none)
	if sel := post_to_select {
		for idx, p in posts {
			if p.created_at.unix == sel {
				selected_post_idx = idx 
				meta_description = construct_tags(posts[selected_post_idx].tags)

				img := (query as PostQuery).img

				if img != -1 {
					meta_image_url = app.find_meta_img(posts[selected_post_idx], img)
				}
			}
		}
	}

	no_next := page + 1 >= total_pages_from_search
	nav := $tmpl('tmpl/nav_tmpl.html')

	tmpl := $tmpl('tmpl/tmpl.html')

	res.http_ok()
	res.header_date()
	res.html()
	// do not cache authed pages
	if !is_authed {
		app.enter_cache(query, tmpl)

		res.write_string('ETag: "${etag}"\r\n')
		res.write_string('Cache-Control: max-age=0, must-revalidate\r\n')
		write_all(mut res, tmpl)
	} else {
		res.write_string('Cache-Control: no-cache, no-store\r\n')
		write_all(mut res, tmpl)
	}
	return
bad_req:
	res.write_string('HTTP/1.1 400 Bad Request\r\n')
	res.header_date()
	res.write_string('Content-Length: 0\r\n\r\n')
	res.end()
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
	mut is_authed := true
	mut etag := ?u64(none)

	// atomic prepare request, used for etag cache
	app.invalidate_cache_do() or {
		app.logln("/ (invalidate_cache_do): failed ${err}")
		res.http_500()
		res.end()
	}

	// check for gzip and auth
	for idx in 0..req.num_headers {
		hdr := req.headers[idx]
		if hdr.name == 'Cookie' {
			for v in hdr.value.split('; ') {
				if v.starts_with('auth=') {
					if v.after('auth=') == secret_cookie {
						is_authed = true
					}
					break
				}
			}
		} else if hdr.name == 'If-None-Match' {
			str := hdr.value

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
			res.write_string('Cache-Control: max-age=0, must-revalidate\r\n')
			res.header_date()
			res.write_string('Content-Length: 0\r\n\r\n')
			res.end()
			return
		}
	}

	if req.method == 'GET' {
		if req.path.starts_with('/?meta=') {
			v := i64(strconv.parse_uint(req.path[7..], 10, 64) or {
				unsafe { goto bad_req }
				return
			})
			moved_permanently("/?p=${v}##", mut res)
			return
		} else if req.path == '/' || req.path.starts_with( '/?') {
			app.serve_home(req.path, is_authed, mut res)
			return
		} else if req.path == '/embed' {
			app.serve_embed(req.path, mut res)
			return
		} else if req.path == '/index.xml' {
			app.serve_rss(mut res)
			return
		} else if req.path == '/opensearch.xml' {
			res.http_ok()
			res.header_date()
			res.write_string('Content-Type: text/xml\r\n')
			res.write_string('Cache-Control: max-age=31536000, immutable\r\n') // never changes, 1 year
			write_all(mut res, opensearch)
			return
		} else if req.path == '/TerminusTTF.woff2' {
			res.http_ok()
			res.header_date()
			res.write_string('Content-Type: font/woff2\r\n')
			res.write_string('Cache-Control: max-age=31536000, immutable\r\n') // never changes, 1 year
			write_all(mut res, terminus)
			return
		} else if req.path == '/auth' {
			res.http_ok()
			res.header_date()
			res.html()
			write_all(mut res, $tmpl('tmpl/auth_tmpl.html'))
			return
		} else if req.path == '/backup' {
			if !is_authed {
				forbidden_go_auth(mut res)
				return
			}

			file := "backup/backup_${time.now().unix}.sqlite"

			app.raw_query("vacuum into '${file}'") or {
				app.logln("/backup: failed ${err}")
				res.http_500()
				res.end()
				return
			}
			
			app.logln("/backup: created '${file}'")
			see_other('/', mut res)
			return
		} else if req.path.starts_with('/delete/') {
			if !is_authed {
				forbidden_go_auth(mut res)
				return
			}

			post_created_at := time.unix(i64(strconv.parse_uint(req.path[8..], 10, 64) or {
				unsafe { goto bad_req }
				return
			}))

			app.raw_query('delete from posts where created_at = ${post_created_at.unix}') or {
				app.logln("/delete: failed ${err}")
				res.http_500()
				res.end()
				return
			}

			if app.db.get_affected_rows_count() == 0 {
				res.http_404()
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
	} else if req.method == 'POST' {
		if req.path == '/auth' {
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
		} else if req.path == '/post' {
			if !is_authed {
				forbidden_go_auth(mut res)
				return
			}

			// body contains urlencoded data
			post, _ := get_post(req.body) or {
				unsafe { goto bad_req }
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

			app.invalidate_cache(.invalidate_posts)
			see_other('/?p=${post.created_at.unix}##', mut res)
			return
		}
		res.http_404()
		res.end()
	} else {
		res.http_405()
		res.end()
	}
	return
bad_req:
	res.write_string('HTTP/1.1 400 Bad Request\r\n')
	res.header_date()
	res.write_string('Content-Length: 0\r\n\r\n')
	res.end()
}

// -d trace_orm

fn main() {
	mut app := &App{
		media_regex: regex.regex_opt(r'https?://\S+\.(?:(png)|(jpe?g)|(gif)|(svg)|(webp)|(mp4)|(webm)|(mov))')!
		spotify_regex: regex.regex_opt(r'https?://open\.spotify\.com/track/(\S+)')!
		youtube_regex: regex.regex_opt(r"https?://(?:www\.)?youtu(?:be\.com/watch\?v=)|(?:\.be/)(\S+)")!
		db: sqlite.connect("data.sqlite")!
		wal: os.open_append("wal.log")!
		ch: chan Status{cap: 8}
	}

	C.atexit(fn [mut app] () {
		app.db.close() or {}
		app.wal.close()
		println('\ngoodbye')
	})

	app.invalidate_cache(.invalidate_posts)
	app.invalidate_cache_do()!

	assert secret_password != ''
	assert os.is_dir('backup')

	eport := env_port.int()
	port := if eport == 0 { 8080 } else { eport }

	println("http://localhost:${port}/")
	spawn app.worker()
	mut pico := picoev.new(port: port, cb: &callback, user_data: app, max_read: 8192, max_write: 8192) // RIGHT UNDER THE MAXIMUM i32 SIGNED VALUE
	pico.serve()
}
