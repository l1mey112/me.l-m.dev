/* import sqlite from "sqlite";
import type { Database } from "sqlite";
 */
import sqlite from "better-sqlite3";
import type { Database } from "better-sqlite3";

let _db: Database | null = null;

export async function DB(): Promise<Database> {
	if (!_db) {
		_db = sqlite('data.sqlite')
		_db.pragma('journal_mode = WAL');
	}
	return _db;
}

export interface PostEntry {
	id: number;
	created_at: number;
	post_type: string;
	tags: null | string[];
	content: string;
}

// --- invalidate by setting to null
// --- if null, reload from DB()
let _valid_posts: PostEntry[] | null = null;

export async function get_posts(): Promise<PostEntry[]> {
	if (!_valid_posts) {
		const db = await DB();
		_valid_posts = db.prepare('SELECT * FROM posts').all() as PostEntry[];
	}	

	return _valid_posts;
}