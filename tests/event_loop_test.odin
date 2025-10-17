package http_tests

import "core:testing"
import "core:sys/linux"
import "core:os"
import http ".."

@(test)
test_event_loop_init :: proc(t: ^testing.T) {
	// Positive test: valid max_events
	{
		el, ok := http.event_loop_init(128)
		defer http.event_loop_destroy(&el)

		testing.expect(t, ok, "event_loop_init should succeed")
		testing.expect(t, el.epoll_fd >= 0, "epoll_fd should be valid")
		testing.expect_value(t, el.max_events, 128)
		testing.expect(t, el.events != nil, "events buffer should be allocated")
	}

	// Negative test: zero max_events
	{
		_, ok := http.event_loop_init(0)
		testing.expect(t, !ok, "event_loop_init should fail with zero max_events")
	}

	// Negative test: negative max_events
	{
		_, ok := http.event_loop_init(-10)
		testing.expect(t, !ok, "event_loop_init should fail with negative max_events")
	}
}

@(test)
test_event_loop_destroy :: proc(t: ^testing.T) {
	el, ok := http.event_loop_init(64)
	testing.expect(t, ok)

	original_fd := el.epoll_fd

	http.event_loop_destroy(&el)

	testing.expect_value(t, el.epoll_fd, linux.Fd(-1))
	testing.expect(t, el.events == nil, "events should be nil after destroy")
	testing.expect_value(t, el.max_events, 0)

	// Verify the fd was actually closed (attempting to use it should fail)
	// This is implicit - we can't easily test this without potentially affecting other tests
}

@(test)
test_event_loop_add_remove :: proc(t: ^testing.T) {
	el, ok := http.event_loop_init(64)
	defer http.event_loop_destroy(&el)
	testing.expect(t, ok)

	// Create a pipe for testing
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	read_fd := pipes[0]
	write_fd := pipes[1]

	// Add read end to event loop
	added := http.event_loop_add(&el, read_fd, {.Read})
	testing.expect(t, added, "should add fd to event loop")

	// Remove from event loop
	removed := http.event_loop_remove(&el, read_fd)
	testing.expect(t, removed, "should remove fd from event loop")

	// Try to remove again (should fail since it's not registered)
	removed = http.event_loop_remove(&el, read_fd)
	testing.expect(t, !removed, "removing unregistered fd should fail")
}

@(test)
test_event_loop_add_invalid_fd :: proc(t: ^testing.T) {
	el, ok := http.event_loop_init(64)
	defer http.event_loop_destroy(&el)
	testing.expect(t, ok)

	// Try to add invalid fd
	added := http.event_loop_add(&el, linux.Fd(-1), {.Read})
	testing.expect(t, !added, "adding invalid fd should fail")
}

@(test)
test_event_loop_modify :: proc(t: ^testing.T) {
	el, ok := http.event_loop_init(64)
	defer http.event_loop_destroy(&el)
	testing.expect(t, ok)

	// Create a pipe
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	read_fd := pipes[0]

	// Add with Read flag
	added := http.event_loop_add(&el, read_fd, {.Read})
	testing.expect(t, added, "should add fd")

	// Modify to Read + Write
	modified := http.event_loop_modify(&el, read_fd, {.Read, .Write})
	testing.expect(t, modified, "should modify fd flags")

	// Clean up
	http.event_loop_remove(&el, read_fd)
}

@(test)
test_event_loop_modify_unregistered :: proc(t: ^testing.T) {
	el, ok := http.event_loop_init(64)
	defer http.event_loop_destroy(&el)
	testing.expect(t, ok)

	// Create a pipe
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	// Try to modify fd that's not registered
	modified := http.event_loop_modify(&el, pipes[0], {.Read})
	testing.expect(t, !modified, "modifying unregistered fd should fail")
}

@(test)
test_event_loop_wait_timeout :: proc(t: ^testing.T) {
	el, ok := http.event_loop_init(64)
	defer http.event_loop_destroy(&el)
	testing.expect(t, ok)

	// Wait with immediate timeout (non-blocking)
	events, wait_ok := http.event_loop_wait(&el, 0)
	testing.expect(t, wait_ok, "wait should succeed")
	testing.expect(t, events == nil || len(events) == 0, "should have no events")
}

@(test)
test_event_loop_wait_with_event :: proc(t: ^testing.T) {
	el, ok := http.event_loop_init(64)
	defer http.event_loop_destroy(&el)
	testing.expect(t, ok)

	// Create a pipe
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	read_fd := pipes[0]
	write_fd := pipes[1]

	// Add read end to event loop
	http.event_loop_add(&el, read_fd, {.Read})
	defer http.event_loop_remove(&el, read_fd)

	// Write data to trigger read event
	test_data := []u8{1, 2, 3, 4, 5}
	written, write_err := linux.write(write_fd, test_data)
	testing.expect(t, write_err == .NONE && written == len(test_data), "write should succeed")

	// Wait for event (small timeout to avoid hanging)
	events, wait_ok := http.event_loop_wait(&el, 100)
	testing.expect(t, wait_ok, "wait should succeed")
	testing.expect(t, len(events) == 1, "should have one event")

	if len(events) > 0 {
		event := events[0]
		testing.expect(t, .Read in event.flags, "should be a read event")
	}

	// Clean up - read the data
	buf := make([]u8, 5)
	defer delete(buf)
	linux.read(read_fd, buf)
}

@(test)
test_event_loop_multiple_events :: proc(t: ^testing.T) {
	el, ok := http.event_loop_init(64)
	defer http.event_loop_destroy(&el)
	testing.expect(t, ok)

	// Create two pipes
	pipes1: [2]linux.Fd
	pipes2: [2]linux.Fd

	result1 := linux.pipe2(&pipes1, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, result1, linux.Errno.NONE)
	defer {
		linux.close(pipes1[0])
		linux.close(pipes1[1])
	}

	result2 := linux.pipe2(&pipes2, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, result2, linux.Errno.NONE)
	defer {
		linux.close(pipes2[0])
		linux.close(pipes2[1])
	}

	// Add both read ends
	http.event_loop_add(&el, pipes1[0], {.Read})
	http.event_loop_add(&el, pipes2[0], {.Read})
	defer {
		http.event_loop_remove(&el, pipes1[0])
		http.event_loop_remove(&el, pipes2[0])
	}

	// Write to both pipes
	test_data := []u8{1, 2, 3}
	linux.write(pipes1[1], test_data)
	linux.write(pipes2[1], test_data)

	// Wait for events
	events, wait_ok := http.event_loop_wait(&el, 100)
	testing.expect(t, wait_ok, "wait should succeed")
	testing.expect(t, len(events) >= 1, "should have at least one event")
	// Note: may get 1 or 2 events depending on timing

	// Clean up - read the data
	buf := make([]u8, 3)
	defer delete(buf)
	linux.read(pipes1[0], buf)
	linux.read(pipes2[0], buf)
}

@(test)
test_event_loop_write_event :: proc(t: ^testing.T) {
	el, ok := http.event_loop_init(64)
	defer http.event_loop_destroy(&el)
	testing.expect(t, ok)

	// Create a pipe
	pipes: [2]linux.Fd
	result := linux.pipe2(&pipes, {.CLOEXEC, .NONBLOCK})
	testing.expect_value(t, result, linux.Errno.NONE)
	defer {
		linux.close(pipes[0])
		linux.close(pipes[1])
	}

	write_fd := pipes[1]

	// Add write end to event loop (should be immediately writable)
	http.event_loop_add(&el, write_fd, {.Write})
	defer http.event_loop_remove(&el, write_fd)

	// Wait for event
	events, wait_ok := http.event_loop_wait(&el, 100)
	testing.expect(t, wait_ok, "wait should succeed")
	testing.expect(t, len(events) >= 1, "should have at least one event")

	if len(events) > 0 {
		event := events[0]
		testing.expect(t, .Write in event.flags, "should be a write event")
	}
}

@(test)
test_epoll_flags_conversion :: proc(t: ^testing.T) {
	// Test event flags to epoll flags conversion
	{
		flags := http.Event_Flags{.Read}
		epoll_flags := http.epoll_flags_from_event_flags(flags)
		testing.expect(t, .IN in epoll_flags, "Read should convert to IN")
	}

	{
		flags := http.Event_Flags{.Write}
		epoll_flags := http.epoll_flags_from_event_flags(flags)
		testing.expect(t, .OUT in epoll_flags, "Write should convert to OUT")
	}

	{
		flags := http.Event_Flags{.Read, .Write}
		epoll_flags := http.epoll_flags_from_event_flags(flags)
		testing.expect(t, .IN in epoll_flags && .OUT in epoll_flags, "should convert both")
	}

	// Test epoll flags to event flags conversion
	{
		epoll_flags := linux.EPoll_Event_Set{.IN}
		flags := http.event_flags_from_epoll_flags(epoll_flags)
		testing.expect(t, .Read in flags, "IN should convert to Read")
	}

	{
		epoll_flags := linux.EPoll_Event_Set{.OUT}
		flags := http.event_flags_from_epoll_flags(epoll_flags)
		testing.expect(t, .Write in flags, "OUT should convert to Write")
	}

	{
		epoll_flags := linux.EPoll_Event_Set{.HUP}
		flags := http.event_flags_from_epoll_flags(epoll_flags)
		testing.expect(t, .HangUp in flags, "HUP should convert to HangUp")
	}

	{
		epoll_flags := linux.EPoll_Event_Set{.ERR}
		flags := http.event_flags_from_epoll_flags(epoll_flags)
		testing.expect(t, .Error in flags, "ERR should convert to Error")
	}
}
