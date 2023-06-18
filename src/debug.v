// Copyright (c) 2023 l-m.dev. All rights reserved.
// Use of this source code is governed by an AGPL license
// that can be found in the LICENSE file.
import net

fn ip_str(fd int) string {
	mut addr := net.Addr{}

	sz := sizeof(net.Addr)
	if C.getpeername(fd, &addr, &sz) == -1 {
		return '<unknown>'
	}

	return addr.str()
}