package valkyrie_tests

import "core:testing"
import "core:sys/linux"
import "core:time"
import valkyrie ".."

@(test)
test_connection_init :: proc(t: ^testing.T) {
	// Positive test: valid fd
	{
		pipes: [2]linux.Fd
		result := linux.pipe2(&pipes, {.CLOEXEC})
		testing.expect_value(t, result, linux.Errno.NONE)
		defer {
			linux.close(pipes[0])
			linux.close(pipes[1])
		}

		conn, ok := valkyrie.connection_init(pipes[0])
		defer valkyrie.connection_destroy(&conn)

		testing.expect(t, ok, "connection_init should succeed with valid fd")
		testing.expect_value(t, conn.fd, pipes[0])
		testing.expect_value(t, conn.state, valkyrie.Connection_State.New)
		testing.expect(t, !conn.error, "new connection should not have error")
		testing.expect(t, conn.read_buffer.capacity > 0, "read buffer should be initialized")
		testing.expect(t, conn.write_buffer.capacity > 0, "write buffer should be initialized")
	}

	// Negative test: invalid fd
	{
		_, ok := valkyrie.connection_init(linux.Fd(-1))
		testing.expect(t, !ok, "connection_init should fail with invalid fd")
	}
}

@(test)
test_connection_destroy :: proc(t: ^testing.T) {
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer linux.close(pipes[1])

	conn, ok := valkyrie.connection_init(pipes[0])
	testing.expect(t, ok)

	valkyrie.connection_destroy(&conn)

	testing.expect_value(t, conn.fd, linux.Fd(-1))
	testing.expect_value(t, conn.state, valkyrie.Connection_State.Closed)
	// Note: pipes[0] is closed by connection_destroy, so we don't close it in defer
}

@(test)
test_connection_set_nonblocking :: proc(t: ^testing.T) {
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	conn, ok := valkyrie.connection_init(pipes[0])
	defer valkyrie.connection_destroy(&conn)
	testing.expect(t, ok)

	// Set non-blocking
	success := valkyrie.connection_set_nonblocking(&conn)
	testing.expect(t, success, "should set non-blocking mode")

	// Verify by checking flags
	flags, get_err := linux.fcntl_getfl(conn.fd, .GETFL)
	testing.expect(t, get_err == .NONE, "should get flags")
	testing.expect(t, .NONBLOCK in flags, "NONBLOCK should be set")
}

@(test)
test_connection_queue_write :: proc(t: ^testing.T) {
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	conn, ok := valkyrie.connection_init(pipes[0])
	defer valkyrie.connection_destroy(&conn)
	testing.expect(t, ok)

	// Queue some data
	data := []u8{1, 2, 3, 4, 5}
	queued := valkyrie.connection_queue_write(&conn, data)
	testing.expect_value(t, queued, 5)

	// Verify data is in buffer
	testing.expect(t, valkyrie.connection_has_write_pending(&conn), "should have pending write")
	testing.expect_value(t, valkyrie.buffer_available_read(&conn.write_buffer), 5)
}

@(test)
test_connection_write_pending :: proc(t: ^testing.T) {
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	// Use write end for connection (pipes[1])
	conn, ok := valkyrie.connection_init(pipes[1])
	defer valkyrie.connection_destroy(&conn)
	testing.expect(t, ok)

	// Queue data
	write_data := []u8{1, 2, 3, 4, 5}
	valkyrie.connection_queue_write(&conn, write_data)

	// Write pending data
	written := valkyrie.connection_write_pending(&conn)
	testing.expect(t, written == 5, "should write all queued data")

	// Verify no more pending writes
	testing.expect(t, !valkyrie.connection_has_write_pending(&conn), "should have no pending writes")

	// Read from read end to verify
	read_buf := make([]u8, 5)
	defer delete(read_buf)
	n, read_err := linux.read(pipes[0], read_buf)
	testing.expect(t, read_err == .NONE && n == 5, "should read written data")

	for i in 0..<5 {
		testing.expect_value(t, read_buf[i], write_data[i])
	}
}

@(test)
test_connection_read_available :: proc(t: ^testing.T) {
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	conn, ok := valkyrie.connection_init(pipes[0])
	defer valkyrie.connection_destroy(&conn)
	testing.expect(t, ok)

	// Write data to the pipe
	test_data := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	n, write_err := linux.write(pipes[1], test_data)
	testing.expect(t, write_err == .NONE && n == len(test_data), "should write test data")

	// Read available data
	read := valkyrie.connection_read_available(&conn)
	testing.expect(t, read == 8, "should read all available data")

	// Verify data is in buffer
	testing.expect_value(t, valkyrie.connection_available_data(&conn), 8)

	// Read from buffer
	read_buf := make([]u8, 8)
	defer delete(read_buf)
	valkyrie.connection_read_data(&conn, read_buf)

	for i in 0..<8 {
		testing.expect_value(t, read_buf[i], test_data[i])
	}
}

@(test)
test_connection_read_available_closed :: proc(t: ^testing.T) {
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer linux.close(pipes[0])

	conn, ok := valkyrie.connection_init(pipes[0])
	defer valkyrie.connection_destroy(&conn)
	testing.expect(t, ok)

	// Close write end to signal EOF
	linux.close(pipes[1])

	// Read should return 0 and mark connection as closing
	read := valkyrie.connection_read_available(&conn)
	testing.expect_value(t, read, 0)
	testing.expect_value(t, conn.state, valkyrie.Connection_State.Closing)
}

@(test)
test_connection_peek_data :: proc(t: ^testing.T) {
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	conn, ok := valkyrie.connection_init(pipes[0])
	defer valkyrie.connection_destroy(&conn)
	testing.expect(t, ok)

	// Write and read some data
	test_data := []u8{1, 2, 3, 4, 5}
	linux.write(pipes[1], test_data)
	valkyrie.connection_read_available(&conn)

	// Peek at data
	peek_buf := make([]u8, 3)
	defer delete(peek_buf)
	peeked := valkyrie.connection_peek_data(&conn, peek_buf)
	testing.expect_value(t, peeked, 3)
	testing.expect_value(t, peek_buf[0], u8(1))
	testing.expect_value(t, peek_buf[1], u8(2))
	testing.expect_value(t, peek_buf[2], u8(3))

	// Data should still be available
	testing.expect_value(t, valkyrie.connection_available_data(&conn), 5)

	// Read all data
	read_buf := make([]u8, 5)
	defer delete(read_buf)
	valkyrie.connection_read_data(&conn, read_buf)

	for i in 0..<5 {
		testing.expect_value(t, read_buf[i], test_data[i])
	}
}

@(test)
test_connection_is_idle :: proc(t: ^testing.T) {
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	conn, ok := valkyrie.connection_init(pipes[0])
	defer valkyrie.connection_destroy(&conn)
	testing.expect(t, ok)

	// Should not be idle immediately
	testing.expect(t, !valkyrie.connection_is_idle(&conn, 100 * time.Millisecond), "should not be idle")

	// Wait a bit
	time.sleep(150 * time.Millisecond)

	// Should be idle now
	testing.expect(t, valkyrie.connection_is_idle(&conn, 100 * time.Millisecond), "should be idle")

	// Mark active
	valkyrie.connection_mark_active(&conn)

	// Should not be idle anymore
	testing.expect(t, !valkyrie.connection_is_idle(&conn, 100 * time.Millisecond), "should not be idle after mark_active")
}

@(test)
test_connection_close :: proc(t: ^testing.T) {
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	conn, ok := valkyrie.connection_init(pipes[0])
	defer valkyrie.connection_destroy(&conn)
	testing.expect(t, ok)

	// Initially not closed
	testing.expect(t, !valkyrie.connection_is_closed(&conn), "should not be closed initially")

	// Close connection
	valkyrie.connection_close(&conn)

	testing.expect_value(t, conn.state, valkyrie.Connection_State.Closing)
	testing.expect(t, !valkyrie.connection_is_closed(&conn), "Closing state is not fully closed")

	// Destroy to fully close
	valkyrie.connection_destroy(&conn)
	testing.expect(t, valkyrie.connection_is_closed(&conn), "should be closed after destroy")
}

@(test)
test_connection_queue_write_buffer_growth :: proc(t: ^testing.T) {
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	conn, ok := valkyrie.connection_init(pipes[0])
	defer valkyrie.connection_destroy(&conn)
	testing.expect(t, ok)

	initial_capacity := conn.write_buffer.capacity

	// Queue a lot of data to trigger growth
	large_data := make([]u8, initial_capacity + 1000)
	defer delete(large_data)
	for i in 0..<len(large_data) {
		large_data[i] = u8(i % 256)
	}

	queued := valkyrie.connection_queue_write(&conn, large_data)
	testing.expect(t, queued > initial_capacity, "should queue more than initial capacity")
	testing.expect(t, conn.write_buffer.capacity > initial_capacity, "buffer should have grown")
}

@(test)
test_connection_state_transitions :: proc(t: ^testing.T) {
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	conn, ok := valkyrie.connection_init(pipes[0])
	defer valkyrie.connection_destroy(&conn)
	testing.expect(t, ok)

	// Initial state
	testing.expect_value(t, conn.state, valkyrie.Connection_State.New)

	// Transition to Active
	conn.state = .Active
	testing.expect_value(t, conn.state, valkyrie.Connection_State.Active)

	// Transition to Closing
	valkyrie.connection_close(&conn)
	testing.expect_value(t, conn.state, valkyrie.Connection_State.Closing)

	// Multiple closes should keep it in Closing
	valkyrie.connection_close(&conn)
	testing.expect_value(t, conn.state, valkyrie.Connection_State.Closing)
}
