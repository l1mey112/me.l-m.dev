import db.sqlite

const sql = "WITH split(tag, tags_remaining) AS (
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
SELECT DISTINCT tag
FROM split
WHERE tag != '';"

fn main() {
	mut db := sqlite.connect("data.sqlite")!

	rows, ret := db.exec(sql)

	if sqlite.is_error(ret) {
		panic('err')
	}

	println(rows.map(it.vals[0]))

	db.close()!
}