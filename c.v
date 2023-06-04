import regex

fn main() {
	text := r'https://cdn.discordapp.com/attachments/934070864473894952/1112921527374057522/image.png'
	mut re := regex.regex_opt(r'(\d+)')!

	a := re.find_all_str(text)
	println(a)
}