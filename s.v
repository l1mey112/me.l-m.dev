import os
import json
import net.http
import regex

struct Attachment {
mut:
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
	timestamp string
	messages []NMessage
}

struct NMessage {
	content string
	attachments []Attachment
}

fn main() {
	json_data := os.read_file('raw/myself.json')!
	data := json.decode([][]Message, json_data)!

	mut ccs := []Conversation
	
	for m in data {
		mut cvs := Conversation{
			timestamp: m[0].timestamp
			messages: m.map(NMessage{it.content, it.attachments})
		}

		for mut cv in cvs.messages {
			for mut at in cv.attachments {
				if at.url.starts_with("https://cdn.discordapp.com") {
					mut re := regex.regex_opt(r'(\d+)')!

					a := re.find_all_str(at.url)
					name := "images/${a[1]}-${at.file_name}"
					
					http.download_file(at.url, name)!
					
					at.url = name
				}
			}
		}
		
		ccs << cvs
	}

	/* for c in ccs {
		for m in c.messages {
			println(m.attachments)
		}
	} */
	
	//println(json.encode(ccs))
}