import json
import time
import os
import db.sqlite
import strings

struct Global {
	messages []Message
}

struct Attachment {
	url string
	file_name string [json: 'fileName']
}

struct Author {
	id string
	name string
}

struct Message {
	message_type string [json: 'type']
	timestamp string
	author Author
	content string
	attachments []Attachment
}

const me = [
	'456226577798135808' // : deleted user
	'1018362782833451080' // : l-m
]

struct Conversation {
mut:
	timestamp time.Time
	messages []Message
}

[table: 'posts']
struct Post {
	id int [primary; sql: serial]
	created_at time.Time
	tags string // space separated
mut:
	content string
}

fn main() {
	json_data := os.read_file('a.json')!
	data := json.decode(Global, json_data)!

	mut conversations := []Conversation{}

	mut cc := Conversation{}

	mut lts := time.parse_iso8601(data.messages[0].timestamp)!
	cc.timestamp = lts

	for message in data.messages {
		cts := time.parse_iso8601(message.timestamp)!
		is_past := (cts - lts).minutes() > 10

		if is_past {
			if cc.messages.any(it.author.id in me) {
				conversations << Conversation{
					...cc
					messages: cc.messages.clone() // sigh... memory corruption
				}
			}

			cc.messages.clear()
			cc.timestamp = cts
		}

		cc.messages << message

		lts = cts
	}
	conversations << cc

	mut db := sqlite.connect('../data.sqlite')!

	for ccc in conversations {
		mut sb := strings.new_builder(32)

		for m in ccc.messages {
			if m.author.id !in me {
				sb.write_string('[${m.author.name}] ')
			}
			for at in m.attachments {
				sb.writeln(at.url)
			}
			if m.content != '' {
				sb.writeln(m.content)
			} else {
				sb.write_u8(`\n`)
			}
		}

		post := Post{
			created_at: ccc.timestamp
			content: sb.str()
			tags: ''
		}
		
		sql db {
			insert post into Post
		}!
	}

	db.close()!
}