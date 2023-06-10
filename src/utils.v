import mypicohttpparser as phttp
import mymarkdown
import time
import regex

[table: 'posts']
struct Post {
	id int [primary; sql: serial]
	created_at time.Time
	tags string // space separated
mut:
	content string
}

fn mcmp(a &char, len int, b string) bool {
	if len != b.len {
		return false
	}

	return unsafe { C.memcmp(a, b.str, b.len) == 0 }
}

const terminus = $embed_file('TerminusTTF.woff2').to_string()

const query_all_tags = "WITH split(tag, tags_remaining) AS (
  -- Initial query
  SELECT 
    '',
    tags || ' ' -- Appending tags column data to handle the first tag
  FROM posts
  -- Recursive query
  UNION ALL
  SELECT
    trim(substr(tags_remaining, 0, instr(tags_remaining, ' '))),
    substr(tags_remaining, instr(tags_remaining, ' ') + 1)
  FROM split
  WHERE tags_remaining != ''
)
SELECT tag, COUNT(*) AS tag_count
FROM split
WHERE tag != ''
GROUP BY tag;"

struct Tag {
	tag string
	count int
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

fn (mut app App) preprocess(text string) string {
	ntext := app.media_regex.replace_by_fn(text, fn (_ regex.RE, text string, b1 int, b2 int) string {
		t := text[b1..b2]

		if t.ends_with('mp4') || t.ends_with('webm') || t.ends_with('mov') {
			return '\n<video preload="none" src="${t}" controls></video>\n'
		}
		return '\n<img loading="lazy" src="${t}">\n'
	})

	return mymarkdown.to_html(ntext)
}