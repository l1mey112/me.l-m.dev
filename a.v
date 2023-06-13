import db.sqlite
import time

[table: 'posts']
struct Post {
	id int [primary; sql: serial]
mut:
	created_at time.Time
	tags string // space separated
	content string
}

fn main() {
	mut db1 := sqlite.connect('data.sqlite')!
	mut db2 := sqlite.connect('data_two.sqlite')!

	posts := sql db2 {
		select from Post
	}!

	println(posts)

	for post in posts {
		p := Post{
			...post
			id: 0
		}
		sql db1 {
			insert p into Post
		}!
	}

	db2.close()!
	db1.close()!
}