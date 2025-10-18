package http

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:sync"
import linux "core:sys/linux"
import "core:thread"
import http2 "http2"

// Signal handling
foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	signal :: proc(sig: c.int, handler: rawptr) -> rawptr ---
}

SIG_IGN :: rawptr(uintptr(1))
SIGPIPE :: c.int(13)

// Constants
QUEUE_SIZE :: 4096
DEFAULT_NUM_WORKERS :: 10

// TLS_Handshake_State tracks the progress of TLS handshake
TLS_Handshake_State :: enum {
	Handshaking, // TLS handshake in progress
	Ready, // Handshake complete, ready for HTTP/2
	Error, // Handshake failed
}

// Connection_Metadata tracks per-connection state
Connection_Metadata :: struct {
	tls_conn:        Maybe(TLS_Connection), // TLS connection (if TLS enabled)
	handshake_state: TLS_Handshake_State, // TLS handshake progress
	is_tls:          bool, // Whether this is a TLS connection
}

// Work_Item represents a unit of work for the thread pool and responses from workers
Work_Item :: struct {
	fd:   linux.Fd,
	data: []u8,
	len:  int,
}

// MPSC_Queue is a Multi-Producer Single-Consumer queue using a fixed-size ring buffer
MPSC_Queue :: struct($T: typeid) {
	items:  [QUEUE_SIZE]T,
	head:   int,
	tail:   int,
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	closed: bool,
}

// Handler_Entry contains a protocol handler with its own mutex for per-connection locking
Handler_Entry :: struct {
	handler: http2.Protocol_Handler,
	mutex:   sync.Mutex,
}

// Global queues and workers
io_to_worker_queue: MPSC_Queue(Work_Item)
worker_to_io_queue: MPSC_Queue(Work_Item)
workers: [dynamic]^thread.Thread
wakeup_fd: linux.Fd // eventfd for waking up I/O thread when responses are ready

// HTTP/2 connection handlers (one per file descriptor)
handlers: map[linux.Fd]^Handler_Entry
handlers_mutex: sync.Mutex // Only protects map operations, not handler access

// TLS support
tls_ctx: Maybe(TLS_Context) // Global TLS context (if TLS enabled)
conn_metadata: map[linux.Fd]Connection_Metadata // Per-connection metadata
conn_metadata_mutex: sync.Mutex

// mpsc_queue_init initializes an MPSC queue
mpsc_queue_init :: proc($T: typeid) -> MPSC_Queue(T) {
	return MPSC_Queue(T){head = 0, tail = 0, closed = false}
}

// mpsc_queue_is_full checks if the queue is full
mpsc_queue_is_full :: proc(queue: ^MPSC_Queue($T)) -> bool {
	return (queue.tail + 1) % QUEUE_SIZE == queue.head
}

// mpsc_queue_is_empty checks if the queue is empty
mpsc_queue_is_empty :: proc(queue: ^MPSC_Queue($T)) -> bool {
	return queue.head == queue.tail
}

// mpsc_queue_push adds an item to the queue (producer side)
mpsc_queue_push :: proc(queue: ^MPSC_Queue($T), item: T) -> bool {
	sync.mutex_lock(&queue.mutex)
	defer sync.mutex_unlock(&queue.mutex)

	if queue.closed {
		return false
	}

	if mpsc_queue_is_full(queue) {
		return false
	}

	queue.items[queue.tail] = item
	queue.tail = (queue.tail + 1) % QUEUE_SIZE
	sync.cond_signal(&queue.cond)
	return true
}

// mpsc_queue_pop removes an item from the queue (consumer side)
mpsc_queue_pop :: proc(queue: ^MPSC_Queue($T)) -> (item: T, ok: bool) {
	sync.mutex_lock(&queue.mutex)
	defer sync.mutex_unlock(&queue.mutex)

	for mpsc_queue_is_empty(queue) && !queue.closed {
		sync.cond_wait(&queue.cond, &queue.mutex)
	}

	if mpsc_queue_is_empty(queue) {
		return {}, false
	}

	item = queue.items[queue.head]
	queue.head = (queue.head + 1) % QUEUE_SIZE
	return item, true
}

// mpsc_queue_try_pop tries to pop without blocking
mpsc_queue_try_pop :: proc(queue: ^MPSC_Queue($T)) -> (item: T, ok: bool) {
	sync.mutex_lock(&queue.mutex)
	defer sync.mutex_unlock(&queue.mutex)

	if mpsc_queue_is_empty(queue) {
		return {}, false
	}

	item = queue.items[queue.head]
	queue.head = (queue.head + 1) % QUEUE_SIZE
	return item, true
}

// worker_thread_proc is the main loop for worker threads
worker_thread_proc :: proc() {
	for {
		work_item, ok := mpsc_queue_pop(&io_to_worker_queue)
		if !ok {
			break
		}

		// Process HTTP/2 data
		if work_item.len > 0 {
			// Get handler entry pointer from map (only lock for map access)
			sync.mutex_lock(&handlers_mutex)
			entry, found := handlers[work_item.fd]
			sync.mutex_unlock(&handlers_mutex)

			if !found {
				delete(work_item.data)
				continue
			}

			// Lock this specific handler for the entire processing duration
			// This prevents concurrent access to the same connection's state
			sync.mutex_lock(&entry.mutex)

			// Process incoming HTTP/2 data
			ok := http2.protocol_handler_process_data(&entry.handler, work_item.data)

			// Free the incoming data
			delete(work_item.data)

			if !ok {
				sync.mutex_unlock(&entry.mutex)

				// Queue a zero-length item to signal connection should be closed
				close_item := Work_Item {
					fd   = work_item.fd,
					data = nil,
					len  = -1, // Special marker for "close connection"
				}
				mpsc_queue_push(&worker_to_io_queue, close_item)

				// Wake up I/O thread
				val: u64 = 1
				linux.write(wakeup_fd, transmute([]u8)mem.ptr_to_bytes(&val))
				continue
			}

			// Get response data if there's anything to write
			response_data := http2.protocol_handler_get_write_data(&entry.handler)
			if response_data != nil && len(response_data) > 0 {
				// Make a copy of response data
				response_copy := make([]u8, len(response_data))
				copy(response_copy, response_data)

				// Consume the write data from handler's buffer
				http2.protocol_handler_consume_write_data(&entry.handler, len(response_data))

				// Unlock handler before queuing response
				sync.mutex_unlock(&entry.mutex)

				// Queue response back to IO
				response_item := Work_Item {
					fd   = work_item.fd,
					data = response_copy,
					len  = len(response_copy),
				}
				mpsc_queue_push(&worker_to_io_queue, response_item)

				// Wake up I/O thread
				val: u64 = 1
				linux.write(wakeup_fd, transmute([]u8)mem.ptr_to_bytes(&val))
			} else {
				// No response data, just unlock
				sync.mutex_unlock(&entry.mutex)
			}
		}
	}
}

// enqueue_to_workers sends data to worker threads for processing
enqueue_to_workers :: proc(client_fd: linux.Fd, data: []u8, len: int) {
	work_item := Work_Item {
		fd   = client_fd,
		data = data,
		len  = len,
	}
	if !mpsc_queue_push(&io_to_worker_queue, work_item) {
		// Queue is full, drop the work
		delete(data)
	}
}

// drain_response_queue drains all pending responses from worker threads
drain_response_queue :: proc(epoll_fd: linux.Fd) {
	count := 0
	for {
		work_item, ok := mpsc_queue_try_pop(&worker_to_io_queue)
		if !ok {
			break
		}
		count += 1

		// Check if this is a close signal
		if work_item.len < 0 {
			// Close the connection due to protocol error
			linux.epoll_ctl(epoll_fd, .DEL, work_item.fd, nil)
			linux.close(work_item.fd)

			// Cleanup HTTP/2 handler (thread-safe)
			sync.mutex_lock(&handlers_mutex)
			if entry, found := handlers[work_item.fd]; found {
				http2.protocol_handler_destroy(&entry.handler)
				free(entry)
				delete_key(&handlers, work_item.fd)
			}
			sync.mutex_unlock(&handlers_mutex)

			// Cleanup TLS connection (thread-safe)
			sync.mutex_lock(&conn_metadata_mutex)
			if metadata, found := conn_metadata[work_item.fd]; found {
				if tls_conn, ok := metadata.tls_conn.?; ok {
					tls_conn_mut := tls_conn
					tls_connection_free(&tls_conn_mut)
				}
				delete_key(&conn_metadata, work_item.fd)
			}
			sync.mutex_unlock(&conn_metadata_mutex)
			continue
		}

		// Write response back to client
		if work_item.len > 0 {
			// Check if this is a TLS connection
			sync.mutex_lock(&conn_metadata_mutex)
			metadata, found := conn_metadata[work_item.fd]
			sync.mutex_unlock(&conn_metadata_mutex)

			n_written := 0
			write_failed := false

			if found && metadata.is_tls {
				// Use TLS send
				if tls_conn, ok := metadata.tls_conn.?; ok {
					tls_conn_mut := tls_conn
					n_written = tls_send(&tls_conn_mut, work_item.data[:work_item.len])
					if n_written < 0 {
						write_failed = true
					}
				}
			} else {
				// Use plain write
				n, write_err := linux.write(work_item.fd, work_item.data[:work_item.len])
				if write_err != .NONE {
					write_failed = true
				} else {
					n_written = int(n)
				}
			}

			if write_failed {
				// Write error - close connection
				linux.epoll_ctl(epoll_fd, .DEL, work_item.fd, nil)
				linux.close(work_item.fd)

				// Cleanup HTTP/2 handler (thread-safe)
				sync.mutex_lock(&handlers_mutex)
				if entry, found := handlers[work_item.fd]; found {
					http2.protocol_handler_destroy(&entry.handler)
					free(entry)
					delete_key(&handlers, work_item.fd)
				}
				sync.mutex_unlock(&handlers_mutex)

				// Cleanup TLS connection (thread-safe)
				sync.mutex_lock(&conn_metadata_mutex)
				if metadata, found := conn_metadata[work_item.fd]; found {
					if tls_conn, ok := metadata.tls_conn.?; ok {
						tls_conn_mut := tls_conn
						tls_connection_free(&tls_conn_mut)
					}
					delete_key(&conn_metadata, work_item.fd)
				}
				sync.mutex_unlock(&conn_metadata_mutex)
			}
			delete(work_item.data)
		}
	}
}

main :: proc() {
	// Parse command-line arguments
	host := "0.0.0.0"
	port := 8080
	max_connections := 1024
	enable_tls := false
	cert_path := "dev_server.crt"
	key_path := "dev_server.key"
	num_workers := DEFAULT_NUM_WORKERS

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		arg := args[i]

		switch arg {
		case "-h", "--host":
			if i + 1 < len(args) {
				i += 1
				host = args[i]
			}
		case "-p", "--port":
			if i + 1 < len(args) {
				i += 1
				port_val, ok := strconv.parse_int(args[i])
				if ok {
					port = port_val
				}
			}
		case "-m", "--max-connections":
			if i + 1 < len(args) {
				i += 1
				max_val, ok := strconv.parse_int(args[i])
				if ok {
					max_connections = max_val
				}
			}
		case "-w", "--workers":
			if i + 1 < len(args) {
				i += 1
				workers_val, ok := strconv.parse_int(args[i])
				if ok {
					num_workers = workers_val
				}
			}
		case "--tls":
			enable_tls = true
		case "--cert":
			if i + 1 < len(args) {
				i += 1
				cert_path = args[i]
			}
		case "--key":
			if i + 1 < len(args) {
				i += 1
				key_path = args[i]
			}
		case "--help":
			print_usage()
			return
		}
	}

	// Setup signal handler
	signal(SIGPIPE, SIG_IGN)

	// Initialize TLS if enabled
	if enable_tls {
		ctx, ok := tls_init(cert_path, key_path)
		if !ok {
			fmt.eprintln("Failed to initialize TLS")
			return
		}
		tls_ctx = ctx
		fmt.printfln("TLS initialized (cert: %s, key: %s)", cert_path, key_path)
	}

	// Initialize queues
	io_to_worker_queue = mpsc_queue_init(Work_Item)
	worker_to_io_queue = mpsc_queue_init(Work_Item)

	// Initialize handlers and connection metadata maps
	handlers = make(map[linux.Fd]^Handler_Entry)
	conn_metadata = make(map[linux.Fd]Connection_Metadata)

	// Start worker threads
	workers = make([dynamic]^thread.Thread, num_workers)
	for i in 0 ..< num_workers {
		workers[i] = thread.create_and_start(worker_thread_proc)
	}

	// Create epoll instance
	epoll_fd, epoll_err := linux.epoll_create1({.FDCLOEXEC})
	if epoll_err != .NONE {
		fmt.eprintln("Failed to create epoll")
		return
	}

	// Create eventfd for waking up I/O thread when workers have responses
	EFD_NONBLOCK :: 0o04000
	EFD_CLOEXEC :: 0o02000000
	eventfd_result := linux.syscall(linux.SYS_eventfd2, 0, EFD_NONBLOCK | EFD_CLOEXEC)
	if eventfd_result < 0 {
		fmt.eprintln("Failed to create eventfd")
		return
	}
	wakeup_fd = linux.Fd(eventfd_result)

	// Add eventfd to epoll
	wakeup_event := linux.EPoll_Event {
		events = {.IN},
		data = linux.EPoll_Data{fd = wakeup_fd},
	}
	wakeup_add_err := linux.epoll_ctl(epoll_fd, .ADD, wakeup_fd, &wakeup_event)
	if wakeup_add_err != .NONE {
		fmt.eprintln("Failed to add eventfd to epoll")
		return
	}

	// Create listening socket
	listen_fd, sock_err := linux.socket(.INET, .STREAM, {.CLOEXEC}, .TCP)
	if sock_err != .NONE {
		fmt.eprintln("Failed to create socket")
		return
	}

	// Enable address reuse with SO_REUSEADDR
	{
		opt_val: c.int = 1
		result := linux.setsockopt_sock(listen_fd, .SOCKET, .REUSEADDR, &opt_val)
		if result != .NONE {
			linux.close(listen_fd)
			fmt.eprintln("Failed to set SO_REUSEADDR")
			return
		}
	}

	// Bind to address
	addr: linux.Sock_Addr_In
	addr.sin_family = .INET
	addr.sin_port = u16be(port)
	addr.sin_addr = {0, 0, 0, 0} // INADDR_ANY (0.0.0.0)

	bind_err := linux.bind(listen_fd, &addr)
	if bind_err != .NONE {
		linux.close(listen_fd)
		fmt.eprintfln("Failed to bind to %s:%d", host, port)
		return
	}

	// Start listening with backlog of 128
	listen_err := linux.listen(listen_fd, 128)
	if listen_err != .NONE {
		linux.close(listen_fd)
		fmt.eprintln("Failed to listen")
		return
	}

	// Add listen socket to epoll
	event := linux.EPoll_Event {
		events = {.IN},
		data = linux.EPoll_Data{fd = listen_fd},
	}
	epoll_add_err := linux.epoll_ctl(epoll_fd, .ADD, listen_fd, &event)
	if epoll_add_err != .NONE {
		linux.close(listen_fd)
		fmt.eprintln("Failed to add listen socket to epoll")
		return
	}

	protocol := enable_tls ? "HTTPS" : "HTTP"
	fmt.printfln("%s/2 server listening on %s:%d", protocol, host, port)
	fmt.printfln("Max connections: %d", max_connections)
	fmt.printfln("Worker threads: %d", num_workers)
	if enable_tls {
		fmt.printfln("TLS enabled (cert: %s, key: %s)", cert_path, key_path)
	}
	fmt.println("Press Ctrl+C to stop...")

	// Create events array
	events: [128]linux.EPoll_Event

	// Main event loop
	for {
		drain_response_queue(epoll_fd)

		nfds, wait_err := linux.epoll_wait(epoll_fd, raw_data(events[:]), 128, -1)
		if wait_err != .NONE {
			continue
		}

		for i in 0 ..< nfds {
			fd := events[i].data.fd

			if fd == wakeup_fd {
				// Wakeup event from worker - read to clear the eventfd counter
				buf: [8]u8
				linux.read(wakeup_fd, buf[:])
				// drain_response_queue already runs at top of loop, so nothing else needed
			} else if fd == listen_fd {
				// Accept the client connection
				client_addr: linux.Sock_Addr_In
				client_fd, accept_err := linux.accept(listen_fd, &client_addr)
				if accept_err != .NONE {
					continue
				}

				// Set socket to non-blocking mode (required for edge-triggered epoll)
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

				// Set SO_REUSEADDR on client socket
				{
					opt_val: c.int = 1
					result := linux.setsockopt_sock(client_fd, .SOCKET, .REUSEADDR, &opt_val)
					if result != .NONE {
						linux.close(client_fd)
						continue
					}
				}

				// Add client socket to epoll
				client_event := linux.EPoll_Event {
					events = {.IN, .ET},
					data = linux.EPoll_Data{fd = client_fd},
				}
				epoll_ctl_err := linux.epoll_ctl(epoll_fd, .ADD, client_fd, &client_event)
				if epoll_ctl_err != .NONE {
					linux.close(client_fd)
					continue
				}

				// Create connection metadata
				metadata := Connection_Metadata {
					is_tls          = enable_tls,
					handshake_state = enable_tls ? .Handshaking : .Ready,
				}

				// Create TLS connection if enabled
				if enable_tls {
					if ctx, ok := tls_ctx.?; ok {
						tls_conn, tls_ok := tls_connection_new(&ctx, c.int(client_fd))
						if !tls_ok {
							linux.epoll_ctl(epoll_fd, .DEL, client_fd, nil)
							linux.close(client_fd)
							continue
						}
						metadata.tls_conn = tls_conn
					}
				}

				// Store metadata in map (thread-safe)
				sync.mutex_lock(&conn_metadata_mutex)
				conn_metadata[client_fd] = metadata
				sync.mutex_unlock(&conn_metadata_mutex)

				// Create HTTP/2 protocol handler for this connection (only if not TLS or handshake will complete)
				if !enable_tls {
					handler, handler_ok := http2.protocol_handler_init(true) // true = server
					if !handler_ok {
						linux.epoll_ctl(epoll_fd, .DEL, client_fd, nil)
						linux.close(client_fd)
						continue
					}

					// Store handler in map (thread-safe)
					sync.mutex_lock(&handlers_mutex)
					// Allocate handler entry
					entry := new(Handler_Entry)
					entry.handler = handler
					handlers[client_fd] = entry
					sync.mutex_unlock(&handlers_mutex)
				}
			} else {
				// Client socket event - check TLS handshake state first
				// Get connection metadata (thread-safe)
				sync.mutex_lock(&conn_metadata_mutex)
				metadata, found := conn_metadata[fd]
				sync.mutex_unlock(&conn_metadata_mutex)

				if !found {
					continue
				}

				// Handle TLS handshake if in progress
				if metadata.is_tls && metadata.handshake_state == .Handshaking {
					if tls_conn, ok := metadata.tls_conn.?; ok {
						tls_conn_mut := tls_conn
						result := tls_negotiate(&tls_conn_mut)

						switch result {
						case .Success:
							metadata.handshake_state = .Ready

							// Create HTTP/2 protocol handler now that handshake is done
							handler, handler_ok := http2.protocol_handler_init(true)
							if !handler_ok {
								metadata.handshake_state = .Error
							} else {
								sync.mutex_lock(&handlers_mutex)
								// Allocate handler entry
								entry := new(Handler_Entry)
								entry.handler = handler
								handlers[fd] = entry
								sync.mutex_unlock(&handlers_mutex)
							}

							// Update metadata with new TLS connection state
							metadata.tls_conn = tls_conn_mut
							sync.mutex_lock(&conn_metadata_mutex)
							conn_metadata[fd] = metadata
							sync.mutex_unlock(&conn_metadata_mutex)

						case .WouldBlock:
							// Just wait for next epoll event
							continue

						case .Error:
							metadata.handshake_state = .Error
							sync.mutex_lock(&conn_metadata_mutex)
							conn_metadata[fd] = metadata
							sync.mutex_unlock(&conn_metadata_mutex)

							// Close connection
							linux.epoll_ctl(epoll_fd, .DEL, fd, nil)
							linux.close(fd)
							continue
						}
					}
				}

				// If handshake failed, skip this connection
				if metadata.handshake_state == .Error {
					continue
				}

				// If TLS handshake still in progress, wait for next event
				if metadata.is_tls && metadata.handshake_state != .Ready {
					continue
				}

				// Read data from socket
				temp_buf: [4096]u8
				data_buf: [dynamic]u8
				total: int
				last_err: linux.Errno
				got_eof := false

				// Use TLS recv if TLS connection, otherwise plain read
				if metadata.is_tls {
					if tls_conn, ok := metadata.tls_conn.?; ok {
						tls_conn_mut := tls_conn
						for {
							n_bytes := tls_recv(&tls_conn_mut, temp_buf[:])

							if n_bytes > 0 {
								append(&data_buf, ..temp_buf[:n_bytes])
								total += n_bytes
							} else if n_bytes == 0 {
								// Would block - just wait for next event
								// DON'T set got_eof, as 0 can mean "would block"
								break
							} else {
								// Actual error (-1)
								got_eof = true
								break
							}
						}
					}
				} else {
					for {
						n_bytes, read_err := linux.read(fd, temp_buf[:])
						if read_err != .NONE {
							last_err = read_err
							if read_err == .EAGAIN || read_err == .EWOULDBLOCK {
								break
							}
							break
						}

						if n_bytes == 0 {
							got_eof = true
							break
						}

						// Append to buffer
						append(&data_buf, ..temp_buf[:n_bytes])
						total += int(n_bytes)
					}
				}

				if total > 0 {
					enqueue_to_workers(fd, data_buf[:], total)
				} else if got_eof {
					linux.epoll_ctl(epoll_fd, .DEL, fd, nil)
					linux.close(fd)
					delete(data_buf)

					// Cleanup HTTP/2 handler (thread-safe)
					sync.mutex_lock(&handlers_mutex)
					if entry, found := handlers[fd]; found {
						http2.protocol_handler_destroy(&entry.handler)
						free(entry)
						delete_key(&handlers, fd)
					}
					sync.mutex_unlock(&handlers_mutex)

					// Cleanup TLS connection (thread-safe)
					sync.mutex_lock(&conn_metadata_mutex)
					if metadata, found := conn_metadata[fd]; found {
						if tls_conn, ok := metadata.tls_conn.?; ok {
							tls_conn_mut := tls_conn
							tls_connection_free(&tls_conn_mut)
						}
						delete_key(&conn_metadata, fd)
					}
					sync.mutex_unlock(&conn_metadata_mutex)
				} else {
					// EAGAIN with no data - just wait for more
					delete(data_buf)
				}
			}
		}
	}
}

// print_usage displays usage information
print_usage :: proc() {
	fmt.println("HTTP/2 Server")
	fmt.println()
	fmt.println("Usage:")
	fmt.println("  http2_server [options]")
	fmt.println()
	fmt.println("Options:")
	fmt.println("  -h, --host <host>              Host to bind to (default: 0.0.0.0)")
	fmt.println("  -p, --port <port>              Port to listen on (default: 8080)")
	fmt.println("  -m, --max-connections <count>  Maximum concurrent connections (default: 1024)")
	fmt.println("  -w, --workers <count>          Number of worker threads (default: 4)")
	fmt.println("  --tls                          Enable TLS/HTTPS")
	fmt.println(
		"  --cert <path>                  Path to TLS certificate (default: certs/server.crt)",
	)
	fmt.println(
		"  --key <path>                   Path to TLS private key (default: certs/server.key)",
	)
	fmt.println("  --help                         Show this help message")
}

