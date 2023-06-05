<script>
    import sqlite from "sqlite";

    async function test() {
        const db = await sqlite.open({filename: ':memory:', driver: sqlite.Database})
        console.log(db)
    }

    test()
</script>

<h1>Welcome to SvelteKit</h1>
<p>Visit <a href="https://kit.svelte.dev">kit.svelte.dev</a> to read the documentation</p>
