import db.sqlite
import time
import regex
import mymarkdown

[table: 'posts']
struct Post {
	id int [primary; sql: serial]
	created_at time.Time
	post_type string
	tags string // space separated
mut:
	content string
}

struct App {
mut:
	media_regex regex.RE = regex.regex_opt(r'https?://\S+\.(?:(png)|(jpe?g)|(gif)|(svg)|(webp)|(mp4)|(webm))') or { panic(err) }
	db sqlite.DB = sqlite.connect("data.sqlite") or { panic(err) }
}

fn (mut a App) preprocess(text string) string {
	ntext := a.media_regex.replace_by_fn(text, fn (_ regex.RE, text string, b1 int, b2 int) string {
		t := text[b1..b2]

		if t.ends_with('.mp4') || t.ends_with('webm') {
			return '\n<video preload="none" src="${t}" controls></video>\n'
		}
		return '\n<img loading="lazy" src="${t}">\n'
	})

	return mymarkdown.to_html(ntext)
}

fn main() {
	mut app := App{}
	defer { app.db.close() or { panic(err) } }

	posts := sql app.db {
		select from Post
	}!

	for p in posts {
		v := app.preprocess(p.content)
		println(v)
		println('---------------------')
	}
}