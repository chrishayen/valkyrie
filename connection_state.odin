package valkyrie

import "base:intrinsics"
import "core:c"
import "core:fmt"
import linux "core:sys/linux"
import http "http"

// TLS_Handshake_State tracks the progress of TLS handshake
TLS_Handshake_State :: enum {
	Handshaking,
	Ready,
	Error,
}

// Connection tracks per-connection state.
Connection :: struct {
	fd:      linux.Fd,
	is_tls:  bool,
	tls_ctx: ^TLS_Context,
}

// Connection_Context tracks per-client connection state.
Connection_Context :: struct {
	fd:              linux.Fd,
	tls_conn:        ^TLS_Connection,
	handshake_state: TLS_Handshake_State,
	is_tls:          bool,
	handler:         http.Protocol_Handler,
	handler_ready:   bool,
}

// Init_With_TLS initializes a new connection.
Init_With_TLS :: proc(
	fd: linux.Fd,
	enable_tls: bool,
	cert_path: string,
	key_path: string,
) -> (
	^Connection,
	bool,
) {
	conn := new(Connection)
	conn.fd = fd
	conn.is_tls = enable_tls

	if !enable_tls {
		return conn, true
	}

	tls_ctx, tls_ok := tls_config_new(cert_path, key_path)
	if !tls_ok {
		free(conn)
		return nil, false
	}

	conn.tls_ctx = new(TLS_Context)
	conn.tls_ctx^ = tls_ctx

	return conn, true
}

// Destroy cleans up TLS context and frees the connection.
Destroy :: proc(conn: ^Connection) {
	if conn.is_tls && conn.tls_ctx != nil {
		tls_destroy(conn.tls_ctx)
		free(conn.tls_ctx)
	}
	free(conn)
}

// Init_Connection_Context creates a new connection context for a client connection.
// Sets up TLS connection if enabled, using the provided TLS context.
Init_Connection_Context :: proc(
	client_fd: linux.Fd,
	enable_tls: bool,
	tls_ctx: ^TLS_Context,
) -> (
	^Connection_Context,
	bool,
) {
	conn_ctx := new(Connection_Context)
	conn_ctx.fd = client_fd
	conn_ctx.is_tls = enable_tls
	conn_ctx.handshake_state = enable_tls ? .Handshaking : .Ready

	if !enable_tls {
		return conn_ctx, true
	}

	if tls_ctx == nil {
		free(conn_ctx)
		return nil, false
	}

	// Create TLS connection for client using shared TLS context
	tls_conn, tls_conn_ok := tls_connection_new(tls_ctx, c.int(client_fd))
	if !tls_conn_ok {
		free(conn_ctx)
		return nil, false
	}

	// Allocate on heap to maintain stable pointer for s2n
	conn_ctx.tls_conn = new(TLS_Connection)
	conn_ctx.tls_conn^ = tls_conn

	return conn_ctx, true
}

// Listen creates and configures a listening socket with epoll.
// Initializes the connection with the listening socket fd.
// Returns the epoll fd and success status.
// Defaults: bind_address="0.0.0.0", port=8080 (or 8443 if enable_tls=true)
Listen :: proc(
	conn: ^Connection,
	bind_address: string = "0.0.0.0",
	port: int = 0,
	enable_tls: bool = false,
	process_id: int = 0,
) -> (
	epoll_fd: linux.Fd,
	ok: bool,
) {
	// Set default port based on TLS
	actual_port := port
	if actual_port == 0 {
		actual_port = 8443 if enable_tls else 8080
	}
	// ===== Create Epoll =====
	epoll, epoll_err := linux.epoll_create1({.FDCLOEXEC})
	if epoll_err != .NONE {
		fmt.eprintfln("[Worker %d] Failed to create epoll", process_id)
		return 0, false
	}

	// ===== Create Socket =====
	sock, sock_err := linux.socket(.INET, .STREAM, {.CLOEXEC, .NONBLOCK}, .TCP)
	if sock_err != .NONE {
		fmt.eprintfln("[Worker %d] Failed to create socket", process_id)
		linux.close(epoll)
		return 0, false
	}

	// ===== Set SO_REUSEADDR =====
	{
		opt_val: c.int = 1
		result := linux.setsockopt_sock(sock, .SOCKET, .REUSEADDR, &opt_val)
		if result != .NONE {
			fmt.eprintfln("[Worker %d] Failed to set SO_REUSEADDR", process_id)
			linux.close(sock)
			linux.close(epoll)
			return 0, false
		}
	}

	// ===== Set SO_REUSEPORT =====
	{
		SO_REUSEPORT :: 15
		SOL_SOCKET :: 1
		opt_val: c.int = 1
		result := int(
			intrinsics.syscall(
				linux.SYS_setsockopt,
				uintptr(sock),
				uintptr(SOL_SOCKET),
				uintptr(SO_REUSEPORT),
				uintptr(&opt_val),
				size_of(c.int),
			),
		)
		if result < 0 {
			fmt.eprintfln("[Worker %d] Failed to set SO_REUSEPORT", process_id)
			linux.close(sock)
			linux.close(epoll)
			return 0, false
		}
	}

	// ===== Bind =====
	addr: linux.Sock_Addr_In
	addr.sin_family = .INET
	addr.sin_port = u16be(u16(actual_port))

	// Parse bind address
	parsed_addr, parse_ok := parse_ip_address(bind_address)
	if !parse_ok {
		fmt.eprintfln("[Worker %d] Invalid bind address: %s", process_id, bind_address)
		linux.close(sock)
		linux.close(epoll)
		return 0, false
	}
	addr.sin_addr = parsed_addr

	bind_err := linux.bind(sock, &addr)
	if bind_err != .NONE {
		fmt.eprintfln("[Worker %d] Failed to bind to %s:%d", process_id, bind_address, actual_port)
		linux.close(sock)
		linux.close(epoll)
		return 0, false
	}

	// ===== Listen =====
	listen_err := linux.listen(sock, 128)
	if listen_err != .NONE {
		fmt.eprintfln("[Worker %d] Failed to listen", process_id)
		linux.close(sock)
		linux.close(epoll)
		return 0, false
	}

	// ===== Add to Epoll =====
	event := linux.EPoll_Event {
		events = {.IN},
		data = linux.EPoll_Data{fd = sock},
	}
	epoll_add_err := linux.epoll_ctl(epoll, .ADD, sock, &event)
	if epoll_add_err != .NONE {
		fmt.eprintfln("[Worker %d] Failed to add listen socket to epoll", process_id)
		linux.close(sock)
		linux.close(epoll)
		return 0, false
	}

	// Store the listening socket fd in the connection
	conn.fd = sock
	conn.is_tls = enable_tls

	log_debug("Listening socket created with fd=%d", sock)

	return epoll, true
}

// Accept accepts all pending client connections from the listening socket.
// Loops until no more connections are available (EAGAIN/EWOULDBLOCK).
// Adds each connection to epoll and stores in the connections map.
Accept :: proc(listen_conn: ^Connection, epoll_fd: linux.Fd, connections: ^map[linux.Fd]^Connection_Context) {
	for {
		// Accept new connection
		client_addr: linux.Sock_Addr_In
		client_fd, accept_err := linux.accept(listen_conn.fd, &client_addr)
		if accept_err != .NONE {
			break
		}

		log_debug("Accepted connection on fd=%d", client_fd)

		// Set non-blocking
		flags, fcntl_err := linux.fcntl_getfl(client_fd, .GETFL)
		if fcntl_err != .NONE {
			log_error("Failed to get flags for fd=%d", client_fd)
			linux.close(client_fd)
			continue
		}

		fcntl_err = linux.fcntl_setfl(client_fd, .SETFL, flags + {.NONBLOCK})
		if fcntl_err != .NONE {
			log_error("Failed to set non-blocking for fd=%d", client_fd)
			linux.close(client_fd)
			continue
		}

		log_debug("Set fd=%d to non-blocking", client_fd)

		// Create connection context for client
		conn_ctx, ctx_ok := Init_Connection_Context(client_fd, listen_conn.is_tls, listen_conn.tls_ctx)
		if !ctx_ok {
			log_error("Failed to init connection context for fd=%d", client_fd)
			linux.close(client_fd)
			continue
		}

		log_debug("Created TLS connection context for fd=%d, is_tls=%v", client_fd, listen_conn.is_tls)

		// Add client socket to epoll
		client_event := linux.EPoll_Event {
			events = {.IN},
			data = linux.EPoll_Data{fd = client_fd},
		}
		epoll_ctl_err := linux.epoll_ctl(epoll_fd, .ADD, client_fd, &client_event)
		if epoll_ctl_err != .NONE {
			log_error("Failed to add fd=%d to epoll", client_fd)
			if conn_ctx.tls_conn != nil {
				tls_connection_free(conn_ctx.tls_conn)
				free(conn_ctx.tls_conn)
			}
			linux.close(client_fd)
			free(conn_ctx)
			continue
		}

		log_debug("Added fd=%d to epoll, waiting for data", client_fd)

		// Store connection
		connections[client_fd] = conn_ctx
	}
}

// Handle_TLS_Handshake performs TLS negotiation for a client connection.
// Returns true if the connection should continue, false if it should be closed.
Handle_TLS_Handshake :: proc(
	conn_ctx: ^Connection_Context,
	epoll_fd: linux.Fd,
	fd: linux.Fd,
) -> bool {
	if !conn_ctx.is_tls || conn_ctx.handshake_state != .Handshaking {
		return true
	}

	if conn_ctx.tls_conn == nil {
		return false
	}

	result := tls_negotiate(conn_ctx.tls_conn)

	switch result {
	case .Success:
		conn_ctx.handshake_state = .Ready

		// After handshake, switch epoll to read-only events
		event := linux.EPoll_Event {
			events = {.IN},
			data = linux.EPoll_Data{fd = fd},
		}
		linux.epoll_ctl(epoll_fd, .MOD, fd, &event)

		// Initialize HTTP/2 handler now that TLS is ready
		handler, handler_ok := http.protocol_handler_init(true)
		if !handler_ok {
			return false
		}
		conn_ctx.handler = handler
		conn_ctx.handler_ready = true

	case .WouldBlock_Read:
		// Need more data to read - ensure we're watching for read events
		event := linux.EPoll_Event {
			events = {.IN},
			data = linux.EPoll_Data{fd = fd},
		}
		linux.epoll_ctl(epoll_fd, .MOD, fd, &event)
		return true

	case .WouldBlock_Write:
		// Need to write data - watch for write events
		event := linux.EPoll_Event {
			events = {.OUT},
			data = linux.EPoll_Data{fd = fd},
		}
		linux.epoll_ctl(epoll_fd, .MOD, fd, &event)
		return true

	case .Error:
		conn_ctx.handshake_state = .Error
		return false
	}

	return true
}

// Read reads all available data from a connection.
// Returns the data buffer and success status. Returns false on EOF or error.
// Caller is responsible for deleting the returned buffer.
Read :: proc(conn_ctx: ^Connection_Context, fd: linux.Fd) -> (data: []u8, ok: bool) {
	if conn_ctx.is_tls {
		return read_tls(conn_ctx)
	}
	return read_plain(fd)
}

// read_tls reads all available data from a TLS connection.
read_tls :: proc(conn_ctx: ^Connection_Context) -> (data: []u8, ok: bool) {
	if conn_ctx.tls_conn == nil {
		return nil, false
	}

	temp_buf: [4096]u8
	data_buf: [dynamic]u8

	for {
		n_bytes := tls_recv(conn_ctx.tls_conn, temp_buf[:])

		if n_bytes > 0 {
			append(&data_buf, ..temp_buf[:n_bytes])
		} else if n_bytes == 0 {
			// Would block
			break
		} else {
			// Error
			delete(data_buf)
			return nil, false
		}
	}

	return data_buf[:], true
}

// read_plain reads all available data from a plain socket.
read_plain :: proc(fd: linux.Fd) -> (data: []u8, ok: bool) {
	temp_buf: [4096]u8
	data_buf: [dynamic]u8

	for {
		n_bytes, read_err := linux.read(fd, temp_buf[:])

		if read_err == .NONE && n_bytes > 0 {
			append(&data_buf, ..temp_buf[:n_bytes])
		} else if read_err == .EAGAIN || read_err == .EWOULDBLOCK {
			// Would block, no more data
			break
		} else {
			// Error or EOF
			delete(data_buf)
			return nil, false
		}
	}

	return data_buf[:], true
}

// Close_Connection closes and cleans up a connection.
Close_Connection :: proc(epoll_fd: linux.Fd, fd: linux.Fd, connections: ^map[linux.Fd]^Connection_Context) {
	conn_ctx, found := connections[fd]
	if !found {
		return
	}

	// Shutdown TLS if enabled
	if conn_ctx.is_tls && conn_ctx.tls_conn != nil {
		tls_shutdown(conn_ctx.tls_conn)
		tls_connection_free(conn_ctx.tls_conn)
		free(conn_ctx.tls_conn)
	}

	// Destroy HTTP/2 handler if initialized
	if conn_ctx.handler_ready {
		http.protocol_handler_destroy(&conn_ctx.handler)
	}

	// Remove from epoll
	linux.epoll_ctl(epoll_fd, .DEL, fd, nil)

	// Close socket
	linux.close(fd)

	// Free connection context
	free(conn_ctx)
	delete_key(connections, fd)
}

