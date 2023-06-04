import os
import json
import time
import term as t

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

struct Conversation {
mut:
	timestamp time.Time
	messages []Message
}

const html_replacements = [
	"&", "&amp;",
	"<", "&lt;",
	">", "&gt;",
	"\"", "&quot;",
	"\'", "&#39;",
	"/", "&#x2F;",
]

const me = [
	'456226577798135808' // : deleted user
	'1018362782833451080' // : l-m
]

fn main() {
	json_data := os.read_file('data.json')!
	data := json.decode(Global, json_data)!

	mut conversations := []Conversation{}

	mut cc := Conversation{}

	mut lts := time.parse_iso8601(data.messages[0].timestamp)!
	cc.timestamp = lts

	for message in data.messages {
		cts := time.parse_iso8601(message.timestamp)!
		is_past := (cts - lts).minutes() > 10

		if is_past {
			conversations << Conversation{
				...cc
				messages: cc.messages.clone() // sigh... memory corruption
			}

			cc.messages.clear()
			cc.timestamp = cts
		}

		cc.messages << message

		lts = cts
	}
	conversations << cc

	for c in conversations {
		manual_audit := c.messages.any(it.author.id !in me)

		if manual_audit {
			println("${json.encode(c.messages)},")
		}
		/* for m in c.messages {
			println('<p>[${m.author.name}] ${m.content.replace_each(html_replacements)}</p>')
			for a in m.attachments {
				if a.file_name.ends_with(".mp4") {
					println('<video src="${a.url}"></video>')
				} else {
					println('<img src="${a.url}">')
				}
			}
		} */
	}

	/* for c in conversations {
		println('<article>')
		for m in c.messages {
			println('<p>[${m.author.name}] ${m.content.replace_each(html_replacements)}</p>')
			for a in m.attachments {
				if a.file_name.ends_with(".mp4") {
					println('<video src="${a.url}"></video>')
				} else {
					println('<img src="${a.url}">')
				}
			}
		}
		println('</article>')
	} */

	/* for c in conversations {
		println('--------- ${c.timestamp}')
		for m in c.messages {
			println('[${t.bold(t.red(m.author.name))}] ${m.content}')
		}
	}
	println('${conversations.len} conversations from ${conversations.first().timestamp} to ${conversations.last().timestamp}') */
}