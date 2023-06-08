import db.sqlite
import time
import regex
import mymarkdown
import mypicoev as picoev
import mypicohttpparser as phttp
import os

[table: 'posts']
struct Post {
	id int [primary; sql: serial]
	created_at time.Time
	post_type string
	tags string // space separated
mut:
	content string
}

[heap]
struct App {
mut:
	media_regex regex.RE
	db sqlite.DB
	prerendered_home string
}

fn (mut app App) preprocess(text string) string {
	ntext := app.media_regex.replace_by_fn(text, fn (_ regex.RE, text string, b1 int, b2 int) string {
		t := text[b1..b2]

		if t.ends_with('mp4') || t.ends_with('webm') {
			return '\n<video preload="none" src="${t}" controls></video>\n'
		}
		return '\n<img loading="lazy" src="${t}">\n'
	})

	return mymarkdown.to_html(ntext)
}

fn (mut app App) rerender()! {
	posts := sql app.db {
		select from Post
	}!

	// TODO: search args, then cache that

	app.prerendered_home = $tmpl('tmpl.html')
}

fn write_all(mut res phttp.Response, v string) {
	res.write_string('Content-Length: ')
	unsafe {
		res.buf += C.u64toa(&char(res.buf), v.len)
	}
	res.write_string('\r\n\r\n')

	if (i64(res.buf) - i64(res.buf_start) + i64(v.len)) >= 8192 {
		res.end()
		C.write(res.fd, v.str, v.len)
	} else {
		res.write_string(v)
		res.end()
	}
}

const terminus = $embed_file('Terminus.woff2').to_string()

fn callback(data voidptr, req phttp.Request, mut res phttp.Response) {
	mut app := unsafe { &App(data) }

	if phttp.cmpn(req.method, 'GET ', 4) {
		if phttp.cmp(req.path, '/') {
			res.http_ok()
			res.header_date()
			res.html()
			write_all(mut res, app.prerendered_home)
		} else if phttp.cmp(req.path, '/font.woff2') {
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

	os.signal_opt(.int, fn [mut app] (_ os.Signal) {
		app.db.close() or { panic(err) }
		println('\nsigint: goodbye')
		exit(0)
	})!

	app.rerender()!
	println("http://localhost:8080/")
	picoev.new(port: 8080, cb: &callback, user_data: app, max_write: 8192).serve() // RIGHT UNDER THE MAXIMUM i32 SIGNED VALUE
}
