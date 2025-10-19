package valkyrie_tests

import "core:testing"
import valkyrie ".."

@(test)
test_buffer_init :: proc(t: ^testing.T) {
	// Positive test: valid capacity
	{
		rb, ok := valkyrie.buffer_init(1024)
		defer valkyrie.buffer_destroy(&rb)

		testing.expect(t, ok, "buffer_init should succeed with valid capacity")
		testing.expect_value(t, rb.capacity, 1024)
		testing.expect_value(t, rb.size, 0)
		testing.expect_value(t, rb.read_pos, 0)
		testing.expect_value(t, rb.write_pos, 0)
	}

	// Negative test: zero capacity
	{
		_, ok := valkyrie.buffer_init(0)
		testing.expect(t, !ok, "buffer_init should fail with zero capacity")
	}

	// Negative test: negative capacity
	{
		_, ok := valkyrie.buffer_init(-100)
		testing.expect(t, !ok, "buffer_init should fail with negative capacity")
	}
}

@(test)
test_buffer_is_empty :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(64)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Initially empty
	testing.expect(t, valkyrie.buffer_is_empty(&rb), "new buffer should be empty")

	// Not empty after write
	data := []u8{1, 2, 3}
	valkyrie.buffer_write(&rb, data)
	testing.expect(t, !valkyrie.buffer_is_empty(&rb), "buffer should not be empty after write")

	// Empty after reading all data
	buf := make([]u8, 3)
	defer delete(buf)
	valkyrie.buffer_read(&rb, buf)
	testing.expect(t, valkyrie.buffer_is_empty(&rb), "buffer should be empty after reading all data")
}

@(test)
test_buffer_is_full :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(4)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Initially not full
	testing.expect(t, !valkyrie.buffer_is_full(&rb), "new buffer should not be full")

	// Full after writing to capacity
	data := []u8{1, 2, 3, 4}
	written := valkyrie.buffer_write(&rb, data)
	testing.expect_value(t, written, 4)
	testing.expect(t, valkyrie.buffer_is_full(&rb), "buffer should be full after writing to capacity")

	// Not full after partial read
	buf := make([]u8, 2)
	defer delete(buf)
	valkyrie.buffer_read(&rb, buf)
	testing.expect(t, !valkyrie.buffer_is_full(&rb), "buffer should not be full after partial read")
}

@(test)
test_buffer_write_and_read :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(64)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Write and read simple data
	write_data := []u8{1, 2, 3, 4, 5}
	written := valkyrie.buffer_write(&rb, write_data)
	testing.expect_value(t, written, 5)
	testing.expect_value(t, valkyrie.buffer_available_read(&rb), 5)

	read_data := make([]u8, 5)
	defer delete(read_data)
	read := valkyrie.buffer_read(&rb, read_data)
	testing.expect_value(t, read, 5)

	for i in 0..<5 {
		testing.expect_value(t, read_data[i], write_data[i])
	}

	testing.expect(t, valkyrie.buffer_is_empty(&rb), "buffer should be empty after reading all data")
}

@(test)
test_buffer_write_partial :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(10)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Fill buffer partially
	data1 := []u8{1, 2, 3, 4, 5}
	written := valkyrie.buffer_write(&rb, data1)
	testing.expect_value(t, written, 5)

	// Try to write more than available space
	data2 := []u8{6, 7, 8, 9, 10, 11, 12}
	written = valkyrie.buffer_write(&rb, data2)
	testing.expect_value(t, written, 5)
	testing.expect(t, valkyrie.buffer_is_full(&rb), "buffer should be full")
}

@(test)
test_buffer_wraparound :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(8)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Write initial data
	data1 := []u8{1, 2, 3, 4, 5}
	valkyrie.buffer_write(&rb, data1)

	// Read some data to advance read position
	buf := make([]u8, 3)
	defer delete(buf)
	valkyrie.buffer_read(&rb, buf)

	// Now write more data that will wrap around
	data2 := []u8{6, 7, 8, 9, 10, 11}
	written := valkyrie.buffer_write(&rb, data2)
	testing.expect_value(t, written, 6)

	// Read all data and verify
	result := make([]u8, 8)
	defer delete(result)
	read := valkyrie.buffer_read(&rb, result)
	testing.expect_value(t, read, 8)

	expected := []u8{4, 5, 6, 7, 8, 9, 10, 11}
	for i in 0..<8 {
		testing.expect_value(t, result[i], expected[i])
	}
}

@(test)
test_buffer_peek :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(64)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Write data
	write_data := []u8{1, 2, 3, 4, 5}
	valkyrie.buffer_write(&rb, write_data)

	// Peek at data
	peek_buf := make([]u8, 3)
	defer delete(peek_buf)
	peeked := valkyrie.buffer_peek(&rb, peek_buf)
	testing.expect_value(t, peeked, 3)
	testing.expect_value(t, peek_buf[0], u8(1))
	testing.expect_value(t, peek_buf[1], u8(2))
	testing.expect_value(t, peek_buf[2], u8(3))

	// Size should not change
	testing.expect_value(t, valkyrie.buffer_available_read(&rb), 5)

	// Read should still get all data
	read_buf := make([]u8, 5)
	defer delete(read_buf)
	read := valkyrie.buffer_read(&rb, read_buf)
	testing.expect_value(t, read, 5)
	for i in 0..<5 {
		testing.expect_value(t, read_buf[i], write_data[i])
	}
}

@(test)
test_buffer_consume :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(64)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Write data
	write_data := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	valkyrie.buffer_write(&rb, write_data)

	// Consume some bytes
	consumed := valkyrie.buffer_consume(&rb, 3)
	testing.expect_value(t, consumed, 3)
	testing.expect_value(t, valkyrie.buffer_available_read(&rb), 5)

	// Read remaining data
	read_buf := make([]u8, 5)
	defer delete(read_buf)
	read := valkyrie.buffer_read(&rb, read_buf)
	testing.expect_value(t, read, 5)

	expected := []u8{4, 5, 6, 7, 8}
	for i in 0..<5 {
		testing.expect_value(t, read_buf[i], expected[i])
	}
}

@(test)
test_buffer_clear :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(64)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Write some data
	data := []u8{1, 2, 3, 4, 5}
	valkyrie.buffer_write(&rb, data)

	// Clear buffer
	valkyrie.buffer_clear(&rb)

	testing.expect(t, valkyrie.buffer_is_empty(&rb), "buffer should be empty after clear")
	testing.expect_value(t, rb.size, 0)
	testing.expect_value(t, rb.read_pos, 0)
	testing.expect_value(t, rb.write_pos, 0)
}

@(test)
test_buffer_grow :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(8)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Write some data
	data := []u8{1, 2, 3, 4, 5}
	valkyrie.buffer_write(&rb, data)

	// Grow buffer
	grown := valkyrie.buffer_grow(&rb, 16)
	testing.expect(t, grown, "buffer should grow successfully")
	testing.expect_value(t, rb.capacity, 16)

	// Data should be preserved
	testing.expect_value(t, valkyrie.buffer_available_read(&rb), 5)

	read_buf := make([]u8, 5)
	defer delete(read_buf)
	valkyrie.buffer_read(&rb, read_buf)
	for i in 0..<5 {
		testing.expect_value(t, read_buf[i], data[i])
	}

	// Can write more data now
	more_data := []u8{6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	written := valkyrie.buffer_write(&rb, more_data)
	testing.expect_value(t, written, 11)
}

@(test)
test_buffer_grow_with_wraparound :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(8)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Write and read to create wraparound scenario
	data1 := []u8{1, 2, 3, 4, 5}
	valkyrie.buffer_write(&rb, data1)

	buf := make([]u8, 3)
	defer delete(buf)
	valkyrie.buffer_read(&rb, buf)

	// Write more to wrap around
	data2 := []u8{6, 7, 8, 9}
	valkyrie.buffer_write(&rb, data2)

	// Now grow
	grown := valkyrie.buffer_grow(&rb, 16)
	testing.expect(t, grown, "buffer should grow with wraparound data")

	// Verify all data is preserved and linearized
	result := make([]u8, 6)
	defer delete(result)
	read := valkyrie.buffer_read(&rb, result)
	testing.expect_value(t, read, 6)

	expected := []u8{4, 5, 6, 7, 8, 9}
	for i in 0..<6 {
		testing.expect_value(t, result[i], expected[i])
	}
}

@(test)
test_buffer_grow_invalid :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(16)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Try to grow to same size
	grown := valkyrie.buffer_grow(&rb, 16)
	testing.expect(t, !grown, "should not grow to same size")

	// Try to grow to smaller size
	grown = valkyrie.buffer_grow(&rb, 8)
	testing.expect(t, !grown, "should not grow to smaller size")
}

@(test)
test_buffer_available_space :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(10)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Initially all space available for writing
	testing.expect_value(t, valkyrie.buffer_available_write(&rb), 10)
	testing.expect_value(t, valkyrie.buffer_available_read(&rb), 0)

	// Write some data
	data := []u8{1, 2, 3, 4, 5}
	valkyrie.buffer_write(&rb, data)

	testing.expect_value(t, valkyrie.buffer_available_write(&rb), 5)
	testing.expect_value(t, valkyrie.buffer_available_read(&rb), 5)

	// Read some data
	buf := make([]u8, 2)
	defer delete(buf)
	valkyrie.buffer_read(&rb, buf)

	testing.expect_value(t, valkyrie.buffer_available_write(&rb), 7)
	testing.expect_value(t, valkyrie.buffer_available_read(&rb), 3)
}

@(test)
test_buffer_empty_operations :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(64)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Read from empty buffer
	buf := make([]u8, 10)
	defer delete(buf)
	read := valkyrie.buffer_read(&rb, buf)
	testing.expect_value(t, read, 0)

	// Peek from empty buffer
	peeked := valkyrie.buffer_peek(&rb, buf)
	testing.expect_value(t, peeked, 0)

	// Consume from empty buffer
	consumed := valkyrie.buffer_consume(&rb, 5)
	testing.expect_value(t, consumed, 0)
}

@(test)
test_buffer_write_empty_data :: proc(t: ^testing.T) {
	rb, ok := valkyrie.buffer_init(64)
	defer valkyrie.buffer_destroy(&rb)
	testing.expect(t, ok)

	// Write empty slice
	empty := []u8{}
	written := valkyrie.buffer_write(&rb, empty)
	testing.expect_value(t, written, 0)
	testing.expect(t, valkyrie.buffer_is_empty(&rb), "buffer should remain empty")
}
