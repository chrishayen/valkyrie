package hpack

// integer_encode encodes an integer using the variable-length format from RFC 7541 Section 5.1.
// prefix_bits: number of bits available in the first byte (1-8)
// prefix_value: existing value in the first byte's prefix bits (must fit in prefix_bits)
// value: the integer to encode
// Returns: encoded bytes
//
// Example: If prefix_bits=5 and the first byte is 01100000 (prefix bits are the top 3 bits = 011),
// then we have 5 bits available (the bottom 5 bits) to encode the integer.
integer_encode :: proc(prefix_bits: u8, prefix_value: u8, value: int, allocator := context.allocator) -> (output: []byte, ok: bool) {
	if prefix_bits < 1 || prefix_bits > 8 {
		return nil, false
	}

	if value < 0 {
		return nil, false
	}

	context.allocator = allocator

	// Calculate maximum value that can fit in prefix_bits
	max_prefix := (1 << prefix_bits) - 1

	// Shift prefix_value to the upper bits (bits that aren't part of the integer)
	first_byte := prefix_value << prefix_bits

	if value < max_prefix {
		// Value fits in prefix bits
		result := make([]byte, 1)
		if result == nil {
			return nil, false
		}
		result[0] = first_byte | u8(value)
		return result, true
	}

	// Value doesn't fit in prefix bits - use multi-byte encoding
	result := make([dynamic]byte, 0, 5, allocator)
	if result == nil {
		return nil, false
	}
	defer if !ok { delete(result) }

	// First byte: prefix value in upper bits, all 1's in lower prefix_bits
	append(&result, first_byte | u8(max_prefix))

	// Remaining value to encode
	remaining := value - max_prefix

	// Encode remaining value in 7-bit chunks with continuation bit
	for remaining >= 128 {
		// Set continuation bit (bit 7) and encode lower 7 bits
		append(&result, u8(remaining % 128) | 0x80)
		remaining /= 128
	}

	// Final byte (no continuation bit)
	append(&result, u8(remaining))

	return result[:], true
}

// Maximum allowed integer value to prevent DoS attacks
MAX_INTEGER_VALUE :: 1 << 30  // ~1 billion, reasonable limit for HPACK integers

// integer_decode decodes a variable-length integer from RFC 7541 Section 5.1.
// input: the bytes to decode
// prefix_bits: number of bits in the first byte that contain the integer (1-8)
// Returns: (decoded value, number of bytes consumed, success)
integer_decode :: proc(input: []byte, prefix_bits: u8) -> (value: int, bytes_consumed: int, ok: bool) {
	if len(input) == 0 {
		return 0, 0, false
	}

	if prefix_bits < 1 || prefix_bits > 8 {
		return 0, 0, false
	}

	// Calculate maximum value that can fit in prefix_bits
	max_prefix := (1 << prefix_bits) - 1

	// Extract value from first byte's lower prefix_bits
	first_byte_mask := u8(max_prefix)
	value = int(input[0] & first_byte_mask)
	bytes_consumed = 1

	// If value is less than max_prefix, it fit in the prefix bits
	if value < max_prefix {
		return value, bytes_consumed, true
	}

	// Multi-byte encoding
	multiplier := 1
	for {
		if bytes_consumed >= len(input) {
			// Need more bytes
			return 0, 0, false
		}

		b := input[bytes_consumed]
		bytes_consumed += 1

		// Calculate the addition value
		add_value := int(b & 0x7F) * multiplier

		// Check for overflow before addition
		if add_value < 0 || value > MAX_INTEGER_VALUE - add_value {
			// Overflow would occur
			return 0, 0, false
		}

		value += add_value

		// Additional safety check
		if value > MAX_INTEGER_VALUE {
			return 0, 0, false
		}

		// Check continuation bit
		if (b & 0x80) == 0 {
			// No continuation bit, we're done
			return value, bytes_consumed, true
		}

		// Check for multiplier overflow before multiplication
		if multiplier > MAX_INTEGER_VALUE / 128 {
			return 0, 0, false
		}

		multiplier *= 128
	}
}
