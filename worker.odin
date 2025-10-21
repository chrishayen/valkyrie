package valkyrie

import "base:intrinsics"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import linux "core:sys/linux"
import "core:time"
import http "http"

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

// Worker manages the parent process and tracks child processes.
// Each Worker spawns multiple child processes that handle
// network I/O independently using SO_REUSEPORT for load balancing.
Worker :: struct {
	child_pids:   []c.int,
	enable_tls:   bool,
	num_children: int,
	host:         string,
	port:         int,
	cert_path:    string,
	key_path:     string,
}

// Worker_Init initializes the worker (parent process).
// If TLS is enabled, certificate paths are resolved to absolute paths before forking.
// Returns nil on failure (e.g., invalid certificate paths).
Worker_Init :: proc(
	host: string,
	port: int,
	enable_tls: bool,
	cert_path: string,
	key_path: string,
) -> (
	^Worker,
	bool,
) {
	w := new(Worker)
	w.host = host
	w.port = port
	w.enable_tls = enable_tls
	w.num_children = 1
	w.child_pids = make([]c.int, w.num_children)

	if !enable_tls {
		return w, true
	}

	abs_cert_path, cert_ok := filepath.abs(cert_path)
	abs_key_path, key_ok := filepath.abs(key_path)

	if !cert_ok || !key_ok {
		fmt.eprintln("Failed to resolve certificate")
		return nil, false
	}

	w.cert_path = abs_cert_path
	w.key_path = abs_key_path

	return w, true
}

// shutdown cleans up worker resources.
shutdown :: proc(w: ^Worker) {
	if w == nil {
		return
	}

	delete(w.child_pids)
	free(w)
}

// Worker_Run starts the worker in single-core mode (no child processes).
// Sets up signal handlers and runs the reactor event loop directly.
Worker_Run :: proc(using w: ^Worker) {
	// Setup signal handlers
	signal(SIGTERM, rawptr(sigterm_handler))
	signal(SIGINT, rawptr(sigterm_handler))

	// Run reactor directly (no fork)
	run(w, 0, 0)
}

// Worker_Run_With_Forks forks multiple child processes and distributes work across them.
// Each child process runs its own reactor event loop with CPU affinity.
// The parent process waits for shutdown signals and manages child lifecycle.
Worker_Run_With_Forks :: proc(w: ^Worker, num_children: int) {
	// Setup signal handlers in parent
	signal(SIGTERM, rawptr(sigterm_handler))
	signal(SIGINT, rawptr(sigterm_handler))

	// Update child tracking
	delete(w.child_pids)
	w.num_children = num_children
	w.child_pids = make([]c.int, num_children)

	// Fork child processes
	for i in 0 ..< num_children {
		pid := fork()

		// Child - run the worker
		if pid == 0 {
			set_affinity(w, i)
			run(w, i, i)
			os.exit(0)
		}

		// Parent - store child PID
		if pid > 0 {
			w.child_pids[i] = pid
			continue
		}

		// Fail - cleanup and exit
		fmt.eprintfln("Failed to fork child process %d", i)
		cleanup_children(w, i)
		return
	}

	// Parent waits here until signal
	for !global_shutdown {
		time.sleep(100 * time.Millisecond)
	}

	// Exiting. Cleanup all children
	cleanup_children(w)
}

// run is the internal method that creates and runs a reactor instance.
// This is called by both Worker_Run (directly) and Worker_Run_With_Forks (in child processes).
run :: proc(using w: ^Worker, process_id: int, cpu_id: int) {
	// Create connection for listening with TLS if enabled
	listen_conn, conn_ok := Init_With_TLS(0, enable_tls, cert_path, key_path)
	if !conn_ok {
		fmt.eprintfln("[Worker %d] Failed to initialize connection", process_id)
		return
	}
	defer Destroy(listen_conn)

	// Setup listening socket and epoll
	epoll_fd, listen_ok := Listen(listen_conn, host, port, enable_tls, process_id)
	if !listen_ok {
		fmt.eprintfln("[Worker %d] Failed to setup listener", process_id)
		return
	}
	defer linux.close(epoll_fd)

	// Run event loop
	event_loop(w, epoll_fd, listen_conn, process_id)
}

// event_loop is the main event loop for handling connections.
event_loop :: proc(w: ^Worker, epoll_fd: linux.Fd, listen_conn: ^Connection, process_id: int) {
	when ODIN_ARCH == .arm64 {
		events: [128]EPoll_Event_ARM64
	} else {
		events: [128]linux.EPoll_Event
	}
	connections := make(map[linux.Fd]^Connection_Context)
	defer delete(connections)

	for !global_shutdown {
		nfds: i32
		wait_err: linux.Errno

		when ODIN_ARCH == .arm64 {
			nfds, wait_err = linux.epoll_wait(epoll_fd, cast([^]linux.EPoll_Event)raw_data(events[:]), 128, 1000)
		} else {
			nfds, wait_err = linux.epoll_wait(epoll_fd, raw_data(events[:]), 128, 1000)
		}

		if wait_err != .NONE {
			continue
		}

		for i in 0 ..< int(nfds) {
			event := events[i]
			fd := event.data.fd


			// This is an event from our listener socket
			// so accept the connection
			if fd == listen_conn.fd {
				log_debug("Listener event on fd=%d, accepting connections", fd)
				Accept(listen_conn, epoll_fd, &connections)
				continue
			}

			// Event from a client so get connection context
			// and process it
			conn_ctx, found := connections[fd]
			if !found {
				log_debug("Event for unknown fd=%d", fd)
				continue
			}

			log_debug("Event on fd=%d, is_tls=%v, handshake_state=%v", fd, conn_ctx.is_tls, conn_ctx.handshake_state)

			// Handle TLS handshake if in progress
			if conn_ctx.is_tls && conn_ctx.handshake_state == .Handshaking {
				log_debug("Calling Handle_TLS_Handshake for fd=%d", fd)
				if !Handle_TLS_Handshake(conn_ctx, epoll_fd, fd) {
					log_debug("Handle_TLS_Handshake failed for fd=%d, closing", fd)
					Close_Connection(epoll_fd, fd, &connections)
					continue
				}
				// If handshake is still in progress, wait for more events
				if conn_ctx.handshake_state != .Ready {
					log_debug("Handshake still in progress for fd=%d", fd)
					continue
				}
				log_debug("Handshake complete for fd=%d", fd)
			}

			// Read data from connection
			data, read_ok := Read(conn_ctx, fd)
			if !read_ok {
				Close_Connection(epoll_fd, fd, &connections)
				continue
			}
			defer delete(data)

			// Process HTTP/2 data
			if !handle_http(conn_ctx, fd, data) {
				Close_Connection(epoll_fd, fd, &connections)
				continue
			}
		}
	}
}

// handle_http processes HTTP/2 data and sends responses.
handle_http :: proc(conn_ctx: ^Connection_Context, fd: linux.Fd, data: []u8) -> bool {
	// Skip if handshake failed or still in progress
	if conn_ctx.is_tls && conn_ctx.handshake_state != .Ready {
		return true
	}

	// Initialize HTTP/2 handler for non-TLS connections on first data
	if !conn_ctx.handler_ready {
		handler, handler_ok := http.protocol_handler_init(true)
		if !handler_ok {
			return false
		}
		conn_ctx.handler = handler
		conn_ctx.handler_ready = true
	}

	// Process HTTP/2 data if we got any
	if len(data) > 0 {
		ok := http.protocol_handler_process_data(&conn_ctx.handler, data)
		if !ok {
			return false
		}

		// Get response data
		response_data := http.protocol_handler_get_write_data(&conn_ctx.handler)
		if response_data != nil && len(response_data) > 0 {
			// Send response
			if conn_ctx.is_tls {
				if conn_ctx.tls_conn != nil {
					tls_send(conn_ctx.tls_conn, response_data)
				}
			} else {
				linux.write(fd, response_data)
			}

			// Consume write data from handler
			http.protocol_handler_consume_write_data(&conn_ctx.handler, len(response_data))
		}
	}

	return true
}

// set_affinity sets CPU affinity for the current process.
set_affinity :: proc(w: ^Worker, cpu_id: int) {
	cpu_mask: u64 = 1 << u64(cpu_id)
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
		fmt.eprintfln("Failed to set CPU affinity to %d", cpu_id)
	}
}

// cleanup_children signals and waits for child processes to terminate.
// If count is provided, only cleans up the first 'count' children (for fork failures).
// Otherwise, cleans up all children.
cleanup_children :: proc(using w: ^Worker, count: int = -1) {
	num_to_cleanup := count if count >= 0 else len(child_pids)

	// Signal children to shut down
	for i in 0 ..< num_to_cleanup {
		if child_pids[i] > 0 {
			kill(child_pids[i], SIGTERM)
		}
	}

	// Wait for children to exit
	for i in 0 ..< num_to_cleanup {
		if child_pids[i] > 0 {
			waitpid(child_pids[i], nil, 0)
		}
	}
}

