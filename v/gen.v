import db.sqlite
import strings
import time
import os

const html_replacements = [
	"&", "&amp;",
	"<", "&lt;",
	">", "&gt;",
	"\"", "&quot;",
	"\'", "&#39;",
	"/", "&#x2F;",
	"\n", "<br>",
	"\r\n", "<br>",
]

[table: 'posts']
struct Post {
	id int [primary; sql: serial]
	created_at time.Time
	post_type string
	tags string // space separated
mut:
	content string
}

fn escape_content(content string) string {
	// mut sb := strings.new_builder(80)

	return content.replace_each(html_replacements)
}

fn main() {
	mut db := sqlite.connect('db/data.sqlite')!
	defer { db.close() or { panic(err) } }

	posts := sql db {
		select from Post where post_type == "i-will-post-random-stuff-here"
	}!

	src := $tmpl("tmpl.html")
	os.write_file('index.html', src)!
}