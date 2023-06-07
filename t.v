import regex

fn main() {
    rg := r'https?://\S+\.(?:(png)|(jpe?g)|(gif)|(svg)|(webp)|(mp4)|(webm))'
	mut re := regex.regex_opt(rg)!

	text := 'https://google.com/favicon.svg
	         https://vosca.dev/images/logo/test.webm
	         https://l-m.dev/'

	s := re.replace_by_fn(text, fn (_ regex.RE, text string, b1 int, b2 int) string {
		t := text[b1..b2]

		if t.ends_with('.mp4') || t.ends_with('webm') {
			return '\n<video preload="none" src="${t}" controls></video>\n'
		}
		return '\n<img loading="lazy" src="${t}">\n'
	})

	println(s)
}
