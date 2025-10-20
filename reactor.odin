package valkyrie

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import linux "core:sys/linux"
import "core:time"
import http2 "http2"

// Signal handling
foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	fork :: proc() -> c.int ---
	kill :: proc(pid: c.int, sig: c.int) -> c.int ---
	waitpid :: proc(pid: c.int, status: ^c.int, options: c.int) -> c.int ---
}

SIGTERM :: c.int(15)
SIGINT :: c.int(2)

// Global shutdown flag (set by signal handler)
@(private = "file")
global_shutdown: bool = false

// Signal handler for graceful shutdown
sigterm_handler :: proc "c" (sig: c.int) {
	global_shutdown = true
}

// Main_Reactor manages the parent process and tracks child processes
Main_Reactor :: struct {
	child_pids: []c.int,
	enable_tls: bool,
	num_cores:  int,
	host:       string,
	port:       int,
	cert_path:  string,
	key_path:   string,
}

// Reactor_Start_Context contains initialization parameters for each reactor
Reactor_Start_Context :: struct {
	process_id: int,
	cpu_id:     int,
	host:       string,
	port:       int,
	enable_tls: bool,
	cert_path:  string,
	key_path:   string,
}

// Reactor represents a single event-driven I/O reactor
Reactor :: struct {
	process_id:  int,
	cpu_id:      int,
	enable_tls:  bool,
	tls_ctx:     ^TLS_Context,
	epoll_fd:    linux.Fd,
	listen_fd:   linux.Fd,
	connections: map[linux.Fd]^Connection_Context,
	shutdown:    bool,
}

// TLS_Handshake_State tracks the progress of TLS handshake
TLS_Handshake_State :: enum {
	Handshaking,
	Ready,
	Error,
}

// Connection_Context tracks per-connection state
Connection_Context :: struct {
	fd:              linux.Fd,
	tls_conn:        ^TLS_Connection,
	handshake_state: TLS_Handshake_State,
	is_tls:          bool,
	handler:         http2.Protocol_Handler,
	handler_ready:   bool,
}

// main_reactor_init initializes the main reactor (parent process)
main_reactor_init :: proc(
	host: string,
	port: int,
	enable_tls: bool,
	cert_path: string,
	key_path: string,
	num_cores: int,
) -> (
	^Main_Reactor,
	bool,
) {
	mr := new(Main_Reactor)
	mr.host = host
	mr.port = port
	mr.enable_tls = enable_tls
	mr.num_cores = num_cores
	mr.child_pids = make([]c.int, num_cores)

	// Convert relative certificate paths to absolute paths in the parent process
	// This ensures the paths are resolved correctly before forking
	if enable_tls {
		abs_cert_path, cert_ok := filepath.abs(cert_path)
		abs_key_path, key_ok := filepath.abs(key_path)

		if !cert_ok || !key_ok {
			fmt.eprintln("Failed to resolve certificate paths to absolute paths")
			return nil, false
		}

		mr.cert_path = abs_cert_path
		mr.key_path = abs_key_path
	}

	return mr, true
}

// main_reactor_run forks child processes and waits for them
main_reactor_run :: proc(mr: ^Main_Reactor) {
	// Setup signal handler in parent
	signal(SIGTERM, rawptr(sigterm_handler))
	signal(SIGINT, rawptr(sigterm_handler))

	// Fork child processes
	for i in 0 ..< mr.num_cores {
		pid := fork()

		if pid == 0 {
			// Child process - run reactor
			ctx := Reactor_Start_Context {
				process_id = i,
				cpu_id     = i,
				host       = mr.host,
				port       = mr.port,
				enable_tls = mr.enable_tls,
				cert_path  = mr.cert_path,
				key_path   = mr.key_path,
			}
			reactor_process_proc(&ctx)
			os.exit(0)
		} else if pid > 0 {
			// Parent process - track child PID
			mr.child_pids[i] = pid
		} else {
			// Fork failed
			fmt.eprintfln("Failed to fork reactor process %d", i)
			// Kill any already-forked children
			for j in 0 ..< i {
				if mr.child_pids[j] > 0 {
					kill(mr.child_pids[j], SIGTERM)
				}
			}
			return
		}
	}

	// Parent waits for signal
	for !global_shutdown {
		// Sleep for a bit to avoid busy-waiting
		time.sleep(100 * time.Millisecond)
	}

	// Signal all children to shut down
	for pid in mr.child_pids {
		if pid > 0 {
			kill(pid, SIGTERM)
		}
	}
}

// main_reactor_shutdown cleans up and waits for all children
main_reactor_shutdown :: proc(mr: ^Main_Reactor) {
	// Wait for all children to exit
	for pid in mr.child_pids {
		if pid > 0 {
			waitpid(pid, nil, 0)
		}
	}

	delete(mr.child_pids)
	free(mr)
}

// reactor_process_proc is the entry point for each reactor process
reactor_process_proc :: proc(ctx: ^Reactor_Start_Context) {
	fmt.printfln("[Reactor %d] Starting", ctx.process_id)

	// Create reactor
	reactor := Reactor {
		process_id = ctx.process_id,
		cpu_id     = ctx.cpu_id,
		enable_tls = ctx.enable_tls,
		shutdown   = false,
	}
	reactor.connections = make(map[linux.Fd]^Connection_Context)
	defer delete(reactor.connections)

	// Set CPU affinity
	reactor_set_affinity(&reactor)

	// IMPORTANT: Do NOT call tls_init() here!
	// s2n_init() was already called once in the parent process.
	// Each child only needs to create its own TLS config.
	// The cert paths are already absolute (converted in parent process).
	if reactor.enable_tls {
		tls_ctx, tls_ok := tls_config_new(ctx.cert_path, ctx.key_path)
		if !tls_ok {
			fmt.eprintfln("[Reactor %d] Failed to create TLS config", reactor.process_id)
			return
		}

		// Allocate on heap to maintain stable pointer
		reactor.tls_ctx = new(TLS_Context)
		reactor.tls_ctx^ = tls_ctx
	}

	// Cleanup TLS context when reactor exits (after event loop finishes)
	defer {
		if reactor.enable_tls && reactor.tls_ctx != nil {
			tls_destroy(reactor.tls_ctx)
			free(reactor.tls_ctx)
		}
	}

	// Create epoll instance for this reactor
	epoll_fd, epoll_err := linux.epoll_create1({.FDCLOEXEC})
	if epoll_err != .NONE {
		fmt.eprintfln("[Reactor %d] Failed to create epoll", reactor.process_id)
		return
	}
	reactor.epoll_fd = epoll_fd
	defer linux.close(epoll_fd)

	// Create this reactor's own listening socket with SO_REUSEPORT
	// IMPORTANT: Socket must be non-blocking so accept() doesn't hang
	listen_fd, sock_err := linux.socket(.INET, .STREAM, {.CLOEXEC, .NONBLOCK}, .TCP)
	if sock_err != .NONE {
		fmt.eprintfln("[Reactor %d] Failed to create socket", reactor.process_id)
		return
	}
	reactor.listen_fd = listen_fd
	defer linux.close(listen_fd)

	// Enable SO_REUSEADDR
	{
		opt_val: c.int = 1
		result := linux.setsockopt_sock(listen_fd, .SOCKET, .REUSEADDR, &opt_val)
		if result != .NONE {
			fmt.eprintfln("[Reactor %d] Failed to set SO_REUSEADDR", reactor.process_id)
			return
		}
	}

	// Enable SO_REUSEPORT - allows multiple sockets to bind to same port
	{
		SO_REUSEPORT :: 15
		SOL_SOCKET :: 1
		opt_val: c.int = 1
		result := int(
			intrinsics.syscall(
				linux.SYS_setsockopt,
				uintptr(listen_fd),
				uintptr(SOL_SOCKET),
				uintptr(SO_REUSEPORT),
				uintptr(&opt_val),
				size_of(c.int),
			),
		)
		if result < 0 {
			fmt.eprintfln("[Reactor %d] Failed to set SO_REUSEPORT", reactor.process_id)
			return
		}
	}

	// Bind to address
	addr: linux.Sock_Addr_In
	addr.sin_family = .INET
	addr.sin_port = u16be(u16(ctx.port))
	addr.sin_addr = {0, 0, 0, 0} // INADDR_ANY

	bind_err := linux.bind(listen_fd, &addr)
	if bind_err != .NONE {
		fmt.eprintfln("[Reactor %d] Failed to bind to port %d", reactor.process_id, ctx.port)
		return
	}

	// Listen for connections
	listen_err := linux.listen(listen_fd, 128)
	if listen_err != .NONE {
		fmt.eprintfln("[Reactor %d] Failed to listen", reactor.process_id)
		return
	}

	// Add listen socket to epoll
	listen_event := linux.EPoll_Event {
		events = {.IN},
		data = linux.EPoll_Data{fd = listen_fd},
	}
	epoll_add_err := linux.epoll_ctl(epoll_fd, .ADD, listen_fd, &listen_event)
	if epoll_add_err != .NONE {
		fmt.eprintfln("[Reactor %d] Failed to add listen socket to epoll", reactor.process_id)
		return
	}

	// Run event loop
	reactor_event_loop(&reactor)
}

// reactor_set_affinity sets CPU affinity for the current process
reactor_set_affinity :: proc(reactor: ^Reactor) {
	cpu_mask: u64 = 1 << u64(reactor.cpu_id)
	// pid=0 means current process
	result := int(
		intrinsics.syscall(
			linux.SYS_sched_setaffinity,
			uintptr(0),
			size_of(u64),
			uintptr(&cpu_mask),
		),
	)

	if result < 0 {
		fmt.eprintfln("[Reactor %d] Failed to set CPU affinity", reactor.process_id)
	}
}

// reactor_event_loop is the main event loop for each reactor
reactor_event_loop :: proc(reactor: ^Reactor) {
	events: [128]linux.EPoll_Event

	for !global_shutdown && !reactor.shutdown {
		nfds, wait_err := linux.epoll_wait(reactor.epoll_fd, raw_data(events[:]), 128, 1000)
		if wait_err != .NONE {
			continue
		}

		for i in 0 ..< int(nfds) {
			event := events[i]
			fd := event.data.fd

			if fd == reactor.listen_fd {
				// Accept new connection
				reactor_accept_connection(reactor)
			} else {
				// Handle client data
				if !reactor_handle_client_data(reactor, fd) {
					reactor_close_connection(reactor, fd)
				}
			}
		}
	}
}

// reactor_accept_connection accepts a new client connection
reactor_accept_connection :: proc(reactor: ^Reactor) {
	for {
		client_addr: linux.Sock_Addr_In
		client_fd, accept_err := linux.accept(reactor.listen_fd, &client_addr)
		if accept_err != .NONE {
			break
		}

		// Set non-blocking mode
		{
			flags, fcntl_err := linux.fcntl_getfl(client_fd, .GETFL)
			if fcntl_err != .NONE {
				linux.close(client_fd)
				continue
			}
			fcntl_err2 := linux.fcntl_setfl(client_fd, .SETFL, flags + {.NONBLOCK})
			if fcntl_err2 != .NONE {
				linux.close(client_fd)
				continue
			}
		}

		// Create connection context
		conn_ctx := new(Connection_Context)
		conn_ctx.fd = client_fd
		conn_ctx.is_tls = reactor.enable_tls
		conn_ctx.handshake_state = reactor.enable_tls ? .Handshaking : .Ready

		// Create TLS connection if enabled
		if reactor.enable_tls && reactor.tls_ctx != nil {
			tls_conn, tls_ok := tls_connection_new(reactor.tls_ctx, c.int(client_fd))
			if !tls_ok {
				linux.close(client_fd)
				free(conn_ctx)
				continue
			}
			// Allocate on heap to maintain stable pointer for s2n
			conn_ctx.tls_conn = new(TLS_Connection)
			conn_ctx.tls_conn^ = tls_conn
		}

		// Add client socket to epoll
		// Watch for read events - client will send ClientHello first
		client_event := linux.EPoll_Event {
			events = {.IN},
			data = linux.EPoll_Data{fd = client_fd},
		}
		epoll_ctl_err := linux.epoll_ctl(reactor.epoll_fd, .ADD, client_fd, &client_event)
		if epoll_ctl_err != .NONE {
			if reactor.enable_tls && conn_ctx.tls_conn != nil {
				tls_connection_free(conn_ctx.tls_conn)
				free(conn_ctx.tls_conn)
			}
			linux.close(client_fd)
			free(conn_ctx)
			continue
		}

		// Store connection - handshake will happen when we get the first read event
		reactor.connections[client_fd] = conn_ctx
	}
}

// reactor_handle_client_data handles data from a client connection
reactor_handle_client_data :: proc(reactor: ^Reactor, fd: linux.Fd) -> bool {
	conn, found := reactor.connections[fd]

	if !found {
		return false
	}

	// Handle TLS handshake if in progress
	if conn.is_tls && conn.handshake_state == .Handshaking {
		if conn.tls_conn != nil {
			result := tls_negotiate(conn.tls_conn)

			switch result {
			case .Success:
				conn.handshake_state = .Ready

				// After handshake, switch epoll to read-only events
				event := linux.EPoll_Event {
					events = {.IN},
					data = linux.EPoll_Data{fd = fd},
				}
				linux.epoll_ctl(reactor.epoll_fd, .MOD, fd, &event)

				// Initialize HTTP/2 handler now that TLS is ready
				handler, handler_ok := http2.protocol_handler_init(true)
				if !handler_ok {
					return false
				}
				conn.handler = handler
				conn.handler_ready = true

			case .WouldBlock_Read:
				// Need more data to read - ensure we're watching for read events
				event := linux.EPoll_Event {
					events = {.IN},
					data = linux.EPoll_Data{fd = fd},
				}
				linux.epoll_ctl(reactor.epoll_fd, .MOD, fd, &event)
				return true

			case .WouldBlock_Write:
				// Need to write data - watch for write events
				event := linux.EPoll_Event {
					events = {.OUT},
					data = linux.EPoll_Data{fd = fd},
				}
				linux.epoll_ctl(reactor.epoll_fd, .MOD, fd, &event)
				return true

			case .Error:
				conn.handshake_state = .Error
				return false
			}
		} else {
			return false
		}
	}

	// If handshake failed or still in progress, skip reading
	if conn.handshake_state == .Error {
		return false
	}

	if conn.is_tls && conn.handshake_state != .Ready {
		return true
	}

	// Initialize HTTP/2 handler for non-TLS connections on first data
	if !conn.handler_ready {
		handler, handler_ok := http2.protocol_handler_init(true)
		if !handler_ok {
			return false
		}
		conn.handler = handler
		conn.handler_ready = true
	}

	// Read data from socket
	temp_buf: [4096]u8
	data_buf: [dynamic]u8
	total: int
	got_eof := false

	// Use TLS recv if TLS connection, otherwise plain read
	if conn.is_tls {
		if conn.tls_conn != nil {
			for {
				n_bytes := tls_recv(conn.tls_conn, temp_buf[:])

				if n_bytes > 0 {
					append(&data_buf, ..temp_buf[:n_bytes])
					total += n_bytes
				} else if n_bytes == 0 {
					// Would block
					break
				} else {
					// Error
					got_eof = true
					break
				}
			}
		}
	} else {
		for {
			n_bytes, read_err := linux.read(fd, temp_buf[:])

			if read_err == .NONE && n_bytes > 0 {
				append(&data_buf, ..temp_buf[:n_bytes])
				total += n_bytes
			} else if read_err == .EAGAIN || read_err == .EWOULDBLOCK {
				// Would block, no more data
				break
			} else {
				// Error or EOF
				got_eof = true
				break
			}
		}
	}

	if got_eof {
		delete(data_buf)
		return false
	}

	// Process HTTP/2 data if we got any
	if total > 0 {
		ok := http2.protocol_handler_process_data(&conn.handler, data_buf[:])
		delete(data_buf)

		if !ok {
			return false
		}

		// Get response data
		response_data := http2.protocol_handler_get_write_data(&conn.handler)
		if response_data != nil && len(response_data) > 0 {
			// Send response
			if conn.is_tls {
				if conn.tls_conn != nil {
					tls_send(conn.tls_conn, response_data)
				}
			} else {
				linux.write(fd, response_data)
			}

			// Consume write data from handler
			http2.protocol_handler_consume_write_data(&conn.handler, len(response_data))
		}
	}

	return true
}

// reactor_close_connection closes and cleans up a connection
reactor_close_connection :: proc(reactor: ^Reactor, fd: linux.Fd) {
	conn, found := reactor.connections[fd]
	if !found {
		return
	}

	// Shutdown TLS if enabled
	if conn.is_tls && conn.tls_conn != nil {
		tls_shutdown(conn.tls_conn)
		tls_connection_free(conn.tls_conn)
		free(conn.tls_conn)
	}

	// Destroy HTTP/2 handler if initialized
	if conn.handler_ready {
		http2.protocol_handler_destroy(&conn.handler)
	}

	// Remove from epoll
	linux.epoll_ctl(reactor.epoll_fd, .DEL, fd, nil)

	// Close socket
	linux.close(fd)

	// Free connection context
	free(conn)
	delete_key(&reactor.connections, fd)
}

