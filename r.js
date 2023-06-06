import sqlite from "better-sqlite3";
import { createClient, SchemaFieldTypes } from 'redis'

const redis_client = createClient();

redis_client.on('error', err => console.log('Redis Client Error', err));

await redis_client.connect();

/* try {
	// Documentation: https://redis.io/commands/ft.create/
	await redis_client.ft.create('index:post', {
		created_at: {
			type: SchemaFieldTypes.NUMERIC,
			SORTABLE: true,
		},
		post_type: SchemaFieldTypes.TEXT,
		tags: {
			type: SchemaFieldTypes.TAG,
			SEPARATOR: ' ',
		},
		content: SchemaFieldTypes.TEXT,
	}, {
		ON: 'HASH',
		PREFIX: 'post'
	});
} catch (e) {
	if (e.message === 'Index already exists') {
		console.log('Index exists already, skipped creation.');
	} else {
		// Something went wrong, perhaps RediSearch isn't installed...
		console.error(e);
		process.exit(1);
	}
}

const db = sqlite('data.sqlite');
const posts = db.prepare('SELECT * FROM posts').all();
let cnt = 0;

for (const v of posts) {
	await redis_client.hSet(`post:${cnt}`, {
		created_at: v.created_at,
		post_type: v.post_type,
		tags: '',
		content: v.content,
	});
	cnt++;
}

db.close(); */

const results = await redis_client.ft.search(
	'index:post', 
	'@post_type:cs @content:wasm',
	{
		SORTBY: {
			BY: 'created_at',
		}
	}
);

for (const doc of results.documents) {
	// noderedis:animals:3: Rover, 9 years old.
	// noderedis:animals:4: Fido, 7 years old.
	console.log(`${doc.id}: ${doc.value.content}`);
}

await redis_client.quit();