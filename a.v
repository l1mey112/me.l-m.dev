import sync.stdatomic

[heap]
struct App {
	ch chan int
	flag i64 // atomic
}

fn (mut app App) worker() {
	mut payload := 0
	mut sel := false
	
	for {
		select {
			payload = <-app.ch {
				sel = true
			}
		}
		if !sel { continue }

		println(payload)

		stdatomic.store_i64(&app.flag, 1)
	}
}

fn main() {
	mut app := &App{
		ch: chan int{cap: 8}
		flag: 0
	}

	a := spawn app.worker()

	for i in 0..16 {
		app.ch <- i
		if stdatomic.load_i64(&app.flag) == 1 {
			println('flag handled')
			stdatomic.store_i64(&app.flag, 0)
		}
	}

	a.wait()
}