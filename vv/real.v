import db.sqlite
import strings
import time

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

fn into_string(c Conversation) string {
	mut sb := strings.new_builder(80)

	for msg in c.messages {
		if msg.author.id !in me {
			sb.write_string('[${msg.author.name}] ')
		}
		if msg.content != '' {
			sb.writeln(msg.content)
		}
		for attachment in msg.attachments {
			sb.writeln(attachment.url)
		}
	}

	return sb.str().trim_space()
}

fn main() {
	mut db := sqlite.connect("data.sqlite")!
	defer { db.close() or { panic(err) } }

	sql db {
		create table Post
	}!

	ccs := conversations()!

	// TODO: web interface will allow tag assignment and editing

	for cc in ccs {
		post := Post{
			created_at: cc.timestamp
			post_type: 'i-will-post-random-stuff-here'
			content: into_string(cc)
		}

		sql db {
			insert post into Post
		}!
	}

	nr_posts := sql db {
		select count from Post
	}!

	println('number of all posts: ${nr_posts}')
}