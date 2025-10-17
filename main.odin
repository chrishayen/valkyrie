package http

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:thread"
import "core:sync"
import linux "core:sys/linux"

// Signal handling
foreign import libc "system:c"

@(default_calling_convention="c")
foreign libc {
	signal :: proc(sig: c.int, handler: rawptr) -> rawptr ---
}

SIG_IGN :: rawptr(uintptr(1))
SIGPIPE :: c.int(13)

// Constants
QUEUE_SIZE :: 4096
DEFAULT_NUM_WORKERS :: 4

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

// Global queues and workers
io_to_worker_queue: MPSC_Queue(Work_Item)
worker_to_io_queue: MPSC_Queue(Work_Item)
workers: [dynamic]^thread.Thread
wakeup_fd: linux.Fd  // eventfd for waking up I/O thread when responses are ready

// mpsc_queue_init initializes an MPSC queue
mpsc_queue_init :: proc($T: typeid) -> MPSC_Queue(T) {
	return MPSC_Queue(T){
		head = 0,
		tail = 0,
		closed = false,
	}
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

		// This is where we do the CPU-heavy frame processing and make responses
		// Parse HTTP/2 frames, handle headers, process requests, generate responses
		if work_item.len > 0 {
			fmt.printfln("[WORKER] Processing %d bytes from fd=%d", work_item.len, work_item.fd)

			// Free the incoming data
			delete(work_item.data)

			// Create HTTP/2 response with "hello world"
			response := "hello world"
			response_data := make([]u8, len(response))
			copy(response_data, response)

			fmt.printfln("[WORKER] Queueing response (%d bytes) for fd=%d", len(response_data), work_item.fd)

			// Queue response back to IO
			response_item := Work_Item{
				fd = work_item.fd,
				data = response_data,
				len = len(response_data),
			}
			mpsc_queue_push(&worker_to_io_queue, response_item)

			// Wake up I/O thread
			val: u64 = 1
			linux.write(wakeup_fd, transmute([]u8)mem.ptr_to_bytes(&val))
		} else {
			// Connection notification (len == 0)
			fmt.printfln("[WORKER] New connection notification for fd=%d", work_item.fd)
		}
	}
}

// enqueue_to_workers sends data to worker threads for processing
enqueue_to_workers :: proc(client_fd: linux.Fd, data: []u8, len: int) {
	work_item := Work_Item{
		fd = client_fd,
		data = data,
		len = len,
	}
	if !mpsc_queue_push(&io_to_worker_queue, work_item) {
		// Queue is full, drop the work
		fmt.printfln("[IO] WARNING: Work queue full, dropping %d bytes from fd=%d", len, client_fd)
		delete(data)
	} else {
		fmt.printfln("[IO] Enqueued %d bytes from fd=%d to worker queue", len, client_fd)
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

		// Write response back to client
		if work_item.len > 0 {
			fmt.printfln("[IO] Draining response: %d bytes to fd=%d", work_item.len, work_item.fd)
			n_written, write_err := linux.write(work_item.fd, work_item.data[:work_item.len])
			if write_err != .NONE {
				// Write error - close connection
				fmt.printfln("[IO] Write error %v on fd=%d, closing connection", write_err, work_item.fd)
				linux.epoll_ctl(epoll_fd, .DEL, work_item.fd, nil)
				linux.close(work_item.fd)
			} else {
				fmt.printfln("[IO] Wrote %d bytes to fd=%d", n_written, work_item.fd)
			}
			delete(work_item.data)
		}
	}
	if count > 0 {
		fmt.printfln("[IO] Drained %d responses from queue", count)
	}
}

main :: proc() {
	// Parse command-line arguments
	host := "0.0.0.0"
	port := 8080
	max_connections := 1024
	enable_tls := false
	cert_path := "certs/server.crt"
	key_path := "certs/server.key"
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

	// Initialize queues
	io_to_worker_queue = mpsc_queue_init(Work_Item)
	worker_to_io_queue = mpsc_queue_init(Work_Item)

	// Start worker threads
	workers = make([dynamic]^thread.Thread, num_workers)
	for i in 0..<num_workers {
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
	EFD_CLOEXEC  :: 0o02000000
	eventfd_result := linux.syscall(linux.SYS_eventfd2, 0, EFD_NONBLOCK | EFD_CLOEXEC)
	if eventfd_result < 0 {
		fmt.eprintln("Failed to create eventfd")
		return
	}
	wakeup_fd = linux.Fd(eventfd_result)

	// Add eventfd to epoll
	wakeup_event := linux.EPoll_Event{
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
	event := linux.EPoll_Event{
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
				fmt.println("[IO] Accepting new connection...")
				client_addr: linux.Sock_Addr_In
				client_fd, accept_err := linux.accept(listen_fd, &client_addr)
				if accept_err != .NONE {
					fmt.printfln("[IO] Accept error: %v", accept_err)
					continue
				}

				fmt.printfln("[IO] Accepted connection on fd=%d", client_fd)

				// Set socket to non-blocking mode (required for edge-triggered epoll)
				{
					flags, fcntl_err := linux.fcntl_getfl(client_fd, .GETFL)
					if fcntl_err != .NONE {
						linux.close(client_fd)
						fmt.printfln("[IO] Failed to get flags for fd=%d", client_fd)
						continue
					}
					fcntl_err2 := linux.fcntl_setfl(client_fd, .SETFL, flags + {.NONBLOCK})
					if fcntl_err2 != .NONE {
						linux.close(client_fd)
						fmt.printfln("[IO] Failed to set O_NONBLOCK on fd=%d", client_fd)
						continue
					}
				}

				// Set SO_REUSEADDR on client socket
				{
					opt_val: c.int = 1
					result := linux.setsockopt_sock(client_fd, .SOCKET, .REUSEADDR, &opt_val)
					if result != .NONE {
						linux.close(client_fd)
						fmt.printfln("[IO] Failed to set SO_REUSEADDR on fd=%d", client_fd)
						continue
					}
				}

				// Add client socket to epoll
				client_event := linux.EPoll_Event{
					events = {.IN, .ET},
					data = linux.EPoll_Data{fd = client_fd},
				}
				epoll_ctl_err := linux.epoll_ctl(epoll_fd, .ADD, client_fd, &client_event)
				if epoll_ctl_err != .NONE {
					linux.close(client_fd)
					fmt.printfln("[IO] Failed to add fd=%d to epoll", client_fd)
					continue
				}

				fmt.printfln("[IO] Added fd=%d to epoll with edge-triggered mode", client_fd)
				enqueue_to_workers(client_fd, nil, 0)
			} else {
				// Client socket event - read fully to buffer
				fmt.printfln("[IO] Read event on fd=%d", fd)
				temp_buf: [4096]u8
				data_buf: [dynamic]u8
				total: int
				last_err: linux.Errno
				got_eof := false

				for {
					n_bytes, read_err := linux.read(fd, temp_buf[:])
					if read_err != .NONE {
						last_err = read_err
						if read_err == .EAGAIN || read_err == .EWOULDBLOCK {
							fmt.printfln("[IO] EAGAIN on fd=%d after reading %d bytes", fd, total)
							break
						}
						fmt.printfln("[IO] Read error %v on fd=%d", read_err, fd)
						break
					}

					if n_bytes == 0 {
						fmt.printfln("[IO] EOF on fd=%d after reading %d bytes", fd, total)
						got_eof = true
						break
					}

					// Append to buffer
					append(&data_buf, ..temp_buf[:n_bytes])
					total += int(n_bytes)
				}

				if total > 0 {
					fmt.printfln("[IO] Read %d bytes total from fd=%d", total, fd)
					enqueue_to_workers(fd, data_buf[:], total)
				} else if got_eof {
					fmt.printfln("[IO] Connection closed by peer on fd=%d", fd)
					linux.epoll_ctl(epoll_fd, .DEL, fd, nil)
					linux.close(fd)
					delete(data_buf)
				} else {
					// EAGAIN with no data - just wait for more
					fmt.printfln("[IO] No data yet on fd=%d (EAGAIN)", fd)
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
	fmt.println("  --cert <path>                  Path to TLS certificate (default: certs/server.crt)")
	fmt.println("  --key <path>                   Path to TLS private key (default: certs/server.key)")
	fmt.println("  --help                         Show this help message")
}
