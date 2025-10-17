package http

import "core:sys/linux"
import "core:net"
import "core:c"
import "core:fmt"

// Server_Config contains server configuration
Server_Config :: struct {
	host:          string,
	port:          int,
	max_connections: int,
	backlog:       int,
	enable_tls:    bool,
	cert_path:     string,
	key_path:      string,
}

// Server represents the HTTP/2 server
Server :: struct {
	config:        Server_Config,
	listen_fd:     linux.Fd,
	event_loop:    Event_Loop,
	connections:   map[linux.Fd]Connection,
	running:       bool,
	tls_ctx:       TLS_Context,
}

// Default configuration values
DEFAULT_MAX_CONNECTIONS :: 1024
DEFAULT_BACKLOG :: 128

// server_init creates and initializes a new server
server_init :: proc(config: Server_Config, allocator := context.allocator) -> (server: Server, ok: bool) {
	if config.port <= 0 || config.port > 65535 {
		return {}, false
	}

	// Initialize event loop
	event_loop := event_loop_init() or_return

	// Create connections map
	connections := make(map[linux.Fd]Connection, allocator)

	// Initialize TLS if enabled
	tls_ctx: TLS_Context
	if config.enable_tls {
		ctx, tls_ok := tls_init(config.cert_path, config.key_path, allocator)
		if !tls_ok {
			fmt.eprintln("Failed to initialize TLS")
			delete(connections)
			event_loop_destroy(&event_loop)
			return {}, false
		}
		tls_ctx = ctx
	}

	return Server{
		config = config,
		listen_fd = -1,
		event_loop = event_loop,
		connections = connections,
		running = false,
		tls_ctx = tls_ctx,
	}, true
}

// server_destroy cleans up server resources
server_destroy :: proc(server: ^Server) {
	// Close all connections
	for fd, &conn in server.connections {
		http2_connection_destroy(&conn)
		connection_destroy(&conn)
	}
	delete(server.connections)

	// Close listen socket
	if server.listen_fd >= 0 {
		event_loop_remove(&server.event_loop, server.listen_fd)
		linux.close(server.listen_fd)
		server.listen_fd = -1
	}

	// Destroy TLS context if enabled
	if server.config.enable_tls {
		tls_destroy(&server.tls_ctx)
	}

	// Destroy event loop
	event_loop_destroy(&server.event_loop)

	server.running = false
}

// server_bind creates and binds the listening socket
server_bind :: proc(server: ^Server) -> bool {
	if server.listen_fd >= 0 {
		return false
	}

	// Create socket
	listen_fd, sock_err := linux.socket(.INET, .STREAM, {.CLOEXEC, .NONBLOCK}, .TCP)
	if sock_err != .NONE {
		return false
	}

	// Set SO_REUSEADDR to allow quick restart
	{
		opt_val: c.int = 1
		result := linux.setsockopt_sock(listen_fd, .SOCKET, .REUSEADDR, &opt_val)
		if result != .NONE {
			linux.close(listen_fd)
			return false
		}
	}

	// Set SO_REUSEPORT for load balancing across multiple processes (optional)
	{
		opt_val: c.int = 1
		linux.setsockopt_sock(listen_fd, .SOCKET, .REUSEPORT, &opt_val)
		// Ignore result - not all systems support this
	}

	// Prepare address
	addr: linux.Sock_Addr_In
	addr.sin_family = .INET
	addr.sin_port = u16be(server.config.port)

	// Parse host address
	if server.config.host == "" || server.config.host == "0.0.0.0" {
		addr.sin_addr = {0, 0, 0, 0} // INADDR_ANY
	} else {
		// For simplicity, only support numeric IPs for now
		// In production, would use getaddrinfo or similar
		addr.sin_addr = {0, 0, 0, 0} // Default to INADDR_ANY
	}

	// Bind socket
	bind_err := linux.bind(listen_fd, &addr)
	if bind_err != .NONE {
		linux.close(listen_fd)
		return false
	}

	server.listen_fd = listen_fd
	return true
}

// server_listen starts listening for connections
server_listen :: proc(server: ^Server) -> bool {
	if server.listen_fd < 0 {
		return false
	}

	backlog := server.config.backlog
	if backlog <= 0 {
		backlog = DEFAULT_BACKLOG
	}

	// Start listening
	result := linux.listen(server.listen_fd, c.int(backlog))
	if result != .NONE {
		return false
	}

	// Add listen socket to event loop
	if !event_loop_add(&server.event_loop, server.listen_fd, {.Read}) {
		return false
	}

	return true
}

// server_accept accepts a new connection
server_accept :: proc(server: ^Server) -> bool {
	if server.listen_fd < 0 {
		return false
	}

	// Accept connection
	client_addr: linux.Sock_Addr_In

	client_fd, accept_err := linux.accept(
		server.listen_fd,
		&client_addr,
		{.CLOEXEC, .NONBLOCK},
	)

	if accept_err != .NONE {
		if accept_err == .EAGAIN || accept_err == .EWOULDBLOCK {
			// No more pending connections
			return true
		}
		return false
	}

	// Check connection limit
	if len(server.connections) >= server.config.max_connections {
		// Too many connections, reject
		linux.close(client_fd)
		return true
	}

	// Create connection
	conn, conn_ok := connection_init(client_fd)
	if !conn_ok {
		linux.close(client_fd)
		return false
	}

	// Setup TLS if enabled
	if server.config.enable_tls {
		tls_conn_ptr := new(TLS_Connection)
		tls_conn, tls_ok := tls_connection_new(&server.tls_ctx, c.int(client_fd))
		if !tls_ok {
			fmt.eprintln("Failed to create TLS connection")
			connection_destroy(&conn)
			free(tls_conn_ptr)
			return false
		}
		tls_conn_ptr^ = tls_conn
		conn.tls_conn = tls_conn_ptr
		conn.tls_handshake_complete = false
		// Handshake will be performed incrementally in the event loop
		// HTTP/2 initialization will happen after TLS handshake completes
	} else {
		// Plain TCP - initialize HTTP/2 immediately
		if !http2_connection_init(&conn) {
			connection_destroy(&conn)
			return false
		}
	}

	// Add to event loop
	if !event_loop_add(&server.event_loop, client_fd, {.Read, .Write}) {
		http2_connection_destroy(&conn)
		connection_destroy(&conn)
		return false
	}

	// Store connection
	server.connections[client_fd] = conn

	return true
}

// server_remove_connection removes and cleans up a connection
server_remove_connection :: proc(server: ^Server, fd: linux.Fd) {
	conn, exists := &server.connections[fd]
	if !exists {
		return
	}

	// Remove from event loop
	event_loop_remove(&server.event_loop, fd)

	// Destroy HTTP/2 protocol handler
	http2_connection_destroy(conn)

	// Destroy connection
	connection_destroy(conn)

	// Remove from map
	delete_key(&server.connections, fd)
}

// server_handle_connection_read handles read events on a connection
server_handle_connection_read :: proc(server: ^Server, fd: linux.Fd) {
	conn, exists := &server.connections[fd]
	if !exists {
		return
	}

	// If TLS is enabled and handshake not complete, attempt handshake
	if conn.tls_conn != nil && !conn.tls_handshake_complete {
		result := tls_negotiate(conn.tls_conn)
		switch result {
		case .Success:
			conn.tls_handshake_complete = true
			// Initialize HTTP/2 now that TLS is established
			if !http2_connection_init(conn) {
				fmt.eprintln("Failed to initialize HTTP/2 after TLS handshake")
				server_remove_connection(server, fd)
				return
			}
			// Continue to read and process data
		case .WouldBlock:
			// Handshake needs more I/O, wait for next event
			return
		case .Error:
			// Handshake failed
			fmt.eprintln("TLS handshake failed")
			server_remove_connection(server, fd)
			return
		}
	}

	// Read available data
	n := connection_read_available(conn)

	if n < 0 {
		// Error occurred
		server_remove_connection(server, fd)
		return
	}

	if n == 0 && conn.state == .Closing {
		// Connection closed by peer
		server_remove_connection(server, fd)
		return
	}

	// Process HTTP/2 protocol
	if !http2_connection_process(conn) {
		server_remove_connection(server, fd)
		return
	}

	// Enable write notifications if there's data to send
	if connection_has_write_pending(conn) {
		event_loop_modify(&server.event_loop, fd, {.Read, .Write})
	}
}

// server_handle_connection_write handles write events on a connection
server_handle_connection_write :: proc(server: ^Server, fd: linux.Fd) {
	conn, exists := &server.connections[fd]
	if !exists {
		return
	}

	// If TLS is enabled and handshake not complete, attempt handshake
	if conn.tls_conn != nil && !conn.tls_handshake_complete {
		result := tls_negotiate(conn.tls_conn)
		switch result {
		case .Success:
			conn.tls_handshake_complete = true
			// Initialize HTTP/2 now that TLS is established
			if !http2_connection_init(conn) {
				fmt.eprintln("Failed to initialize HTTP/2 after TLS handshake")
				server_remove_connection(server, fd)
				return
			}
			// Continue to write data
		case .WouldBlock:
			// Handshake needs more I/O, wait for next event
			return
		case .Error:
			// Handshake failed
			fmt.eprintln("TLS handshake failed")
			server_remove_connection(server, fd)
			return
		}
	}

	// Write pending data
	written := connection_write_pending(conn)

	if written < 0 {
		// Error occurred
		server_remove_connection(server, fd)
		return
	}

	// If no more data to write, disable write notifications
	if !connection_has_write_pending(conn) {
		event_loop_modify(&server.event_loop, fd, {.Read})
	}
}

// server_run starts the server event loop
server_run :: proc(server: ^Server) -> bool {
	if server.listen_fd < 0 {
		return false
	}

	server.running = true

	for server.running {
		// Wait for events
		events, ok := event_loop_wait(&server.event_loop, 1000)
		if !ok {
			continue
		}

		if events == nil || len(events) == 0 {
			continue
		}

		// Process events
		for event in events {
			if event.fd == server.listen_fd {
				// New connection
				server_accept(server)
			} else {
				// Existing connection
				if .Read in event.flags {
					server_handle_connection_read(server, event.fd)
				}
				if .Write in event.flags {
					server_handle_connection_write(server, event.fd)
				}
				if .Error in event.flags || .HangUp in event.flags {
					server_remove_connection(server, event.fd)
				}
			}
		}
	}

	return true
}

// server_stop stops the server
server_stop :: proc(server: ^Server) {
	server.running = false
}
