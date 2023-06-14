import regex

fn main() {
	text := "
		test
		http://youtu.be/FdeioVndUhs
	test2 https://www.youtube.com/watch?v=FdeioVndUhs
	"
	mut re := regex.regex_opt(r"https?://(?:www\.)?youtu(?:be\.com/watch\?v=)|(?:\.be/)(\w+)")!

	ntext := re.replace_by_fn(text, fn (re regex.RE, text string, b1 int, b2 int) string {
		video_url := text[b1..b2]
		video_id := re.get_group_by_id(text, 0)

		return video_id
	})

	println(ntext)
}
