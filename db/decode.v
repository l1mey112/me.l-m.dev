import json
import time
import os

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
	is_me bool
}

fn conversations() ![]Conversation {
	json_data := os.read_file('../raw/data.json')!
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
				is_me: !cc.messages.any(it.author.id !in me)
			}

			cc.messages.clear()
			cc.timestamp = cts
		}

		cc.messages << message

		lts = cts
	}
	conversations << cc

	return conversations
}