package http

import "core:mem"

// Ring_Buffer is a circular buffer for efficient I/O operations.
// It maintains read and write positions to avoid data copying.
Ring_Buffer :: struct {
	data:     []u8,
	read_pos: int,
	write_pos: int,
	size:     int,
	capacity: int,
}

// buffer_init creates a new ring buffer with the specified initial capacity.
buffer_init :: proc(capacity: int, allocator := context.allocator) -> (rb: Ring_Buffer, ok: bool) {
	if capacity <= 0 {
		return {}, false
	}

	data, data_err := make([]u8, capacity, allocator)
	if data_err != nil {
		return {}, false
	}

	return Ring_Buffer{
		data = data,
		read_pos = 0,
		write_pos = 0,
		size = 0,
		capacity = capacity,
	}, true
}

// buffer_destroy frees the ring buffer's memory.
buffer_destroy :: proc(rb: ^Ring_Buffer) {
	if rb.data != nil {
		delete(rb.data)
		rb.data = nil
		rb.read_pos = 0
		rb.write_pos = 0
		rb.size = 0
		rb.capacity = 0
	}
}

// buffer_available_write returns the number of bytes available for writing.
buffer_available_write :: proc(rb: ^Ring_Buffer) -> int {
	return rb.capacity - rb.size
}

// buffer_available_read returns the number of bytes available for reading.
buffer_available_read :: proc(rb: ^Ring_Buffer) -> int {
	return rb.size
}

// buffer_is_empty returns true if the buffer contains no data.
buffer_is_empty :: proc(rb: ^Ring_Buffer) -> bool {
	return rb.size == 0
}

// buffer_is_full returns true if the buffer is at capacity.
buffer_is_full :: proc(rb: ^Ring_Buffer) -> bool {
	return rb.size == rb.capacity
}

// buffer_write writes data to the ring buffer.
// Returns the number of bytes written.
buffer_write :: proc(rb: ^Ring_Buffer, data: []u8) -> int {
	if len(data) == 0 {
		return 0
	}

	available := buffer_available_write(rb)
	if available == 0 {
		return 0
	}

	to_write := min(len(data), available)

	// Write in up to two chunks due to wraparound
	end_space := rb.capacity - rb.write_pos
	first_chunk := min(to_write, end_space)

	copy(rb.data[rb.write_pos:], data[:first_chunk])

	if first_chunk < to_write {
		// Wraparound: write remaining data at beginning
		second_chunk := to_write - first_chunk
		copy(rb.data[0:], data[first_chunk:to_write])
		rb.write_pos = second_chunk
	} else {
		rb.write_pos = (rb.write_pos + first_chunk) % rb.capacity
	}

	rb.size += to_write
	return to_write
}

// buffer_read reads data from the ring buffer.
// Returns the number of bytes read.
buffer_read :: proc(rb: ^Ring_Buffer, dest: []u8) -> int {
	if len(dest) == 0 {
		return 0
	}

	available := buffer_available_read(rb)
	if available == 0 {
		return 0
	}

	to_read := min(len(dest), available)

	// Read in up to two chunks due to wraparound
	end_space := rb.capacity - rb.read_pos
	first_chunk := min(to_read, end_space)

	copy(dest[0:], rb.data[rb.read_pos:rb.read_pos + first_chunk])

	if first_chunk < to_read {
		// Wraparound: read remaining data from beginning
		second_chunk := to_read - first_chunk
		copy(dest[first_chunk:], rb.data[0:second_chunk])
		rb.read_pos = second_chunk
	} else {
		rb.read_pos = (rb.read_pos + first_chunk) % rb.capacity
	}

	rb.size -= to_read
	return to_read
}

// buffer_peek reads data from the ring buffer without advancing the read position.
// Returns the number of bytes read.
buffer_peek :: proc(rb: ^Ring_Buffer, dest: []u8) -> int {
	if len(dest) == 0 {
		return 0
	}

	available := buffer_available_read(rb)
	if available == 0 {
		return 0
	}

	to_read := min(len(dest), available)

	// Read in up to two chunks due to wraparound
	end_space := rb.capacity - rb.read_pos
	first_chunk := min(to_read, end_space)

	copy(dest[0:], rb.data[rb.read_pos:rb.read_pos + first_chunk])

	if first_chunk < to_read {
		// Wraparound: read remaining data from beginning
		second_chunk := to_read - first_chunk
		copy(dest[first_chunk:], rb.data[0:second_chunk])
	}

	return to_read
}

// buffer_consume advances the read position without copying data.
// This is useful after peeking at data to consume it.
buffer_consume :: proc(rb: ^Ring_Buffer, count: int) -> int {
	if count <= 0 {
		return 0
	}

	available := buffer_available_read(rb)
	to_consume := min(count, available)

	rb.read_pos = (rb.read_pos + to_consume) % rb.capacity
	rb.size -= to_consume

	return to_consume
}

// buffer_clear resets the buffer to empty state without deallocating.
buffer_clear :: proc(rb: ^Ring_Buffer) {
	rb.read_pos = 0
	rb.write_pos = 0
	rb.size = 0
}

// buffer_grow increases the buffer capacity.
// Returns true if growth was successful.
buffer_grow :: proc(rb: ^Ring_Buffer, new_capacity: int) -> bool {
	if new_capacity <= rb.capacity {
		return false
	}

	// Allocate new buffer
	new_data, new_data_err := make([]u8, new_capacity, context.allocator)
	if new_data_err != nil {
		return false
	}

	// Copy existing data to new buffer (linearized)
	if rb.size > 0 {
		end_space := rb.capacity - rb.read_pos
		if rb.read_pos + rb.size <= rb.capacity {
			// No wraparound in source
			copy(new_data[0:], rb.data[rb.read_pos:rb.read_pos + rb.size])
		} else {
			// Wraparound in source
			first_chunk := end_space
			copy(new_data[0:], rb.data[rb.read_pos:rb.capacity])
			second_chunk := rb.size - first_chunk
			copy(new_data[first_chunk:], rb.data[0:second_chunk])
		}
	}

	// Free old buffer and update structure
	delete(rb.data)
	rb.data = new_data
	rb.capacity = new_capacity
	rb.read_pos = 0
	rb.write_pos = rb.size

	return true
}
