import db.sqlite
import time
import regex
import mymarkdown

// sets a custom table name. Default is struct name (case-sensitive)
[table: 'posts']
struct Post {
	id int [primary; sql: serial]
	created_at time.Time
	post_type string
	tags string // space separated
mut:
	content string
}

fn preprocess(mut media_regex regex.RE, text string) string {
	ntext := media_regex.replace_by_fn(text, fn (_ regex.RE, text string, b1 int, b2 int) string {
		t := text[b1..b2]

		if t.ends_with('.mp4') || t.ends_with('webm') {
			return '\n<video preload="none" src="${t}" controls></video>\n'
		}
		return '\n<img loading="lazy" src="${t}">\n'
	})

	return mymarkdown.to_html(ntext)
}

fn main() {
	mut db := sqlite.connect("data.sqlite")!
	defer { db.close() or { panic(err) } }

	mut media_regex := regex.regex_opt(r'https?://\S+\.(?:(png)|(jpe?g)|(gif)|(svg)|(webp)|(mp4)|(webm))')!

	posts := sql db {
		select from Post
	}!

	for p in posts {
		v := preprocess(mut media_regex, p.content)
		println(v)
		println('---------------------')
	}
}