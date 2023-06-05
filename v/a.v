import markdown
import pcre

fn main() {
	v := markdown.to_html('https://cdn.discordapp.com/attachments/934070864473894952/934366824366219304/unknown.png')
	println(v)
}

// fn main() {
// 	mut re := pcre.new_regex(r'https?://\S+\.(png|jpe?g|gif|mp4|mov)', 0)!
// 	mut m := re.match_str('https://cdn.discordapp.com/attachments/934070864473894952/934366824366219304/unknown.png
// 	...ee
// 	https://cdn.discordapp.com/attachments/934070864473894952/934366824366219304/gov.mov', 0, 0)!
// 	println(m.get_all())
// 	println(m.group_size)
// 	println(m.ovector)
// 	mut n := m.next()?
// 	println(n.group_size)
// 	println(n.ovector)
// 	c := n.next()?
// 	println(c.group_size)
// 	println(c.ovector)
// }
