import net

fn ip_str(fd int) string {
	mut addr := net.Addr{}

	sz := sizeof(net.Addr)
	if C.getpeername(fd, &addr, &sz) == -1 {
		return '<unknown>'
	}

	return addr.str()
}