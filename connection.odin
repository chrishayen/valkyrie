package http

import "core:sys/linux"
import "core:time"

// Connection_State represents the state of a connection
Connection_State :: enum {
	New,           // Just accepted, no data exchanged
	Active,        // Actively exchanging data
	Closing,       // Gracefully closing
	Closed,        // Fully closed
}

// Connection represents a client connection
Connection :: struct {
	fd:            linux.Fd,
	state:         Connection_State,
	read_buffer:   Ring_Buffer,
	write_buffer:  Ring_Buffer,
	last_activity: time.Time,
	error:         bool,
	user_data:     rawptr,  // For application-specific data
	tls_conn:      ^TLS_Connection,  // Optional TLS connection
	tls_handshake_complete: bool,    // TLS handshake state
}

// Default buffer sizes
DEFAULT_READ_BUFFER_SIZE :: 16384   // 16KB
DEFAULT_WRITE_BUFFER_SIZE :: 16384  // 16KB

// connection_init creates a new connection for the given file descriptor
connection_init :: proc(fd: linux.Fd, allocator := context.allocator) -> (conn: Connection, ok: bool) {
	if fd < 0 {
		return {}, false
	}

	read_buffer := buffer_init(DEFAULT_READ_BUFFER_SIZE, allocator) or_return
	write_buffer := buffer_init(DEFAULT_WRITE_BUFFER_SIZE, allocator) or_return

	return Connection{
		fd = fd,
		state = .New,
		read_buffer = read_buffer,
		write_buffer = write_buffer,
		last_activity = time.now(),
		error = false,
		user_data = nil,
		tls_conn = nil,
	}, true
}

// connection_destroy cleans up connection resources
connection_destroy :: proc(conn: ^Connection) {
	// Shutdown TLS if active
	if conn.tls_conn != nil {
		tls_shutdown(conn.tls_conn)
		tls_connection_free(conn.tls_conn)
		free(conn.tls_conn)
		conn.tls_conn = nil
	}

	if conn.fd >= 0 {
		// Shutdown socket before closing to ensure proper TCP FIN handshake
		linux.shutdown(conn.fd, .RDWR)
		linux.close(conn.fd)
		conn.fd = -1
	}

	buffer_destroy(&conn.read_buffer)
	buffer_destroy(&conn.write_buffer)

	conn.state = .Closed
	conn.user_data = nil
}

// connection_set_nonblocking sets the connection socket to non-blocking mode
connection_set_nonblocking :: proc(conn: ^Connection) -> bool {
	if conn.fd < 0 {
		return false
	}

	// Get current flags
	flags, get_err := linux.fcntl_getfl(conn.fd, .GETFL)
	if get_err != .NONE {
		return false
	}

	// Set non-blocking flag
	set_err := linux.fcntl_setfl(conn.fd, .SETFL, flags | {.NONBLOCK})
	return set_err == .NONE
}

// connection_read_available reads available data from the socket into the read buffer.
// Returns the number of bytes read, or -1 on error.
// Returns 0 if the connection was closed by peer.
connection_read_available :: proc(conn: ^Connection) -> int {
	if conn.fd < 0 || conn.state == .Closed {
		return -1
	}

	total_read := 0

	// Read until we get EAGAIN or buffer is full
	for {
		available := buffer_available_write(&conn.read_buffer)
		if available == 0 {
			// Buffer full, need to grow or process data
			break
		}

		// Prepare temporary buffer for reading
		temp_buf, buf_err := make([]u8, min(available, 4096), context.temp_allocator)
		if buf_err != nil {
			break
		}

		// Read from socket or TLS
		n: int
		read_err: linux.Errno

		if conn.tls_conn != nil {
			// TLS mode
			n = tls_recv(conn.tls_conn, temp_buf)
			if n < 0 {
				read_err = .EIO  // Generic I/O error for TLS
			}
		} else {
			// Plain TCP
			n_bytes, err := linux.read(conn.fd, temp_buf)
			n = int(n_bytes)
			read_err = err
		}

		if n > 0 {
			// Got data, write to buffer
			written := buffer_write(&conn.read_buffer, temp_buf[:n])
			total_read += written
			conn.last_activity = time.now()

			if written < int(n) {
				// Buffer couldn't hold all data (shouldn't happen with our logic)
				break
			}
		} else if n == 0 {
			// Connection closed by peer or would block
			if total_read > 0 {
				// We read something, return it
				break
			}
			if conn.tls_conn == nil {
				// Plain TCP, 0 means closed
				conn.state = .Closing
			}
			return total_read
		} else {
			// Error or would block
			if read_err == .EAGAIN || read_err == .EWOULDBLOCK {
				// No more data available right now
				break
			} else {
				// Real error
				conn.error = true
				return -1
			}
		}
	}

	return total_read
}

// connection_write_pending writes pending data from the write buffer to the socket.
// Returns the number of bytes written, or -1 on error.
connection_write_pending :: proc(conn: ^Connection) -> int {
	if conn.fd < 0 || conn.state == .Closed {
		return -1
	}

	total_written := 0

	// Write until we get EAGAIN or buffer is empty
	for {
		available := buffer_available_read(&conn.write_buffer)
		if available == 0 {
			// Nothing to write
			break
		}

		// Prepare temporary buffer for peeking
		temp_buf, buf_err := make([]u8, min(available, 4096), context.temp_allocator)
		if buf_err != nil {
			break
		}
		peeked := buffer_peek(&conn.write_buffer, temp_buf)

		if peeked == 0 {
			break
		}

		// Write to socket or TLS
		n: int
		write_err: linux.Errno

		if conn.tls_conn != nil {
			// TLS mode
			n = tls_send(conn.tls_conn, temp_buf[:peeked])
			if n < 0 {
				write_err = .EIO  // Generic I/O error for TLS
			}
		} else {
			// Plain TCP
			n_bytes, err := linux.write(conn.fd, temp_buf[:peeked])
			n = int(n_bytes)
			write_err = err
		}

		if n > 0 {
			// Consume the data we successfully wrote
			buffer_consume(&conn.write_buffer, int(n))
			total_written += int(n)
			conn.last_activity = time.now()

			if int(n) < peeked {
				// Partial write, socket buffer is full
				break
			}
		} else if n == 0 {
			// Shouldn't happen with sockets, but can happen with TLS
			break
		} else {
			// Error or would block
			if write_err == .EAGAIN || write_err == .EWOULDBLOCK {
				// Socket buffer full
				break
			} else {
				// Real error
				conn.error = true
				return -1
			}
		}
	}

	return total_written
}

// connection_queue_write queues data to be written to the socket.
// Returns the number of bytes queued.
connection_queue_write :: proc(conn: ^Connection, data: []u8) -> int {
	if conn.state == .Closed || conn.error {
		return 0
	}

	written := buffer_write(&conn.write_buffer, data)

	// If buffer is full, try to grow it
	if written < len(data) {
		available := buffer_available_write(&conn.write_buffer)
		if available == 0 {
			new_capacity := conn.write_buffer.capacity * 2
			if buffer_grow(&conn.write_buffer, new_capacity) {
				// Try writing again
				remaining := data[written:]
				additional := buffer_write(&conn.write_buffer, remaining)
				written += additional
			}
		}
	}

	return written
}

// connection_has_write_pending returns true if there's data waiting to be written
connection_has_write_pending :: proc(conn: ^Connection) -> bool {
	return buffer_available_read(&conn.write_buffer) > 0
}

// connection_read_data reads data from the connection's read buffer.
// This reads already-buffered data that was read from the socket.
connection_read_data :: proc(conn: ^Connection, dest: []u8) -> int {
	return buffer_read(&conn.read_buffer, dest)
}

// connection_peek_data peeks at data from the connection's read buffer without consuming it.
connection_peek_data :: proc(conn: ^Connection, dest: []u8) -> int {
	return buffer_peek(&conn.read_buffer, dest)
}

// connection_available_data returns the number of bytes available to read from the read buffer.
connection_available_data :: proc(conn: ^Connection) -> int {
	return buffer_available_read(&conn.read_buffer)
}

// connection_is_idle returns true if the connection has been idle for the given duration.
connection_is_idle :: proc(conn: ^Connection, idle_duration: time.Duration) -> bool {
	return time.since(conn.last_activity) > idle_duration
}

// connection_mark_active updates the last activity time.
connection_mark_active :: proc(conn: ^Connection) {
	conn.last_activity = time.now()
}

// connection_is_closed returns true if the connection is closed or in error state.
connection_is_closed :: proc(conn: ^Connection) -> bool {
	return conn.state == .Closed || conn.error
}

// connection_close marks the connection for closing.
connection_close :: proc(conn: ^Connection) {
	if conn.state != .Closed {
		conn.state = .Closing
	}
}
