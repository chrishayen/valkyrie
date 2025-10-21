package hpack

import "base:runtime"

// Header represents a single HTTP header name-value pair
Header :: struct {
	name:      string,
	value:     string,
	sensitive: bool, // If true, use "never indexed" representation
}

// Encoder_Context maintains the encoding state including the dynamic table
Encoder_Context :: struct {
	dynamic_table: Dynamic_Table,
	huffman:       bool, // Whether to use Huffman encoding for strings
	allocator:     runtime.Allocator,
}

// encoder_init creates a new encoder context
encoder_init :: proc(max_table_size: int, use_huffman := true, allocator := context.allocator) -> (ctx: Encoder_Context, ok: bool) {
	table, table_ok := dynamic_table_init(max_table_size, allocator)
	if !table_ok {
		return {}, false
	}

	return Encoder_Context{
		dynamic_table = table,
		huffman = use_huffman,
		allocator = allocator,
	}, true
}

// encoder_destroy frees all resources used by the encoder
encoder_destroy :: proc(ctx: ^Encoder_Context) {
	if ctx == nil {
		return
	}

	dynamic_table_destroy(&ctx.dynamic_table)
}

// encoder_encode_headers encodes a list of headers into HPACK format
encoder_encode_headers :: proc(ctx: ^Encoder_Context, headers: []Header, allocator := context.allocator) -> (output: []byte, ok: bool) {
	if ctx == nil {
		return nil, false
	}

	context.allocator = allocator

	result := make([dynamic]byte, 0, 256, allocator)
	defer if !ok { delete(result) }

	for header in headers {
		encoded_header, header_ok := encoder_encode_header(ctx, header, allocator)
		defer delete(encoded_header, allocator)

		if !header_ok {
			return nil, false
		}

		for b in encoded_header {
			append(&result, b)
		}
	}

	return result[:], true
}

// encoder_encode_header encodes a single header
encoder_encode_header :: proc(ctx: ^Encoder_Context, header: Header, allocator := context.allocator) -> (output: []byte, ok: bool) {
	if ctx == nil {
		return nil, false
	}

	context.allocator = allocator

	// Try to find in static table first
	static_index := static_table_find_exact(header.name, header.value)
	if static_index > 0 {
		// Found exact match in static table - use indexed representation
		return encode_indexed(static_index, allocator)
	}

	// Try to find in dynamic table
	dynamic_index := dynamic_table_find_exact(&ctx.dynamic_table, header.name, header.value)
	if dynamic_index >= 0 {
		// Found exact match in dynamic table
		// Dynamic table indices start after static table (62+)
		full_index := 62 + dynamic_index
		return encode_indexed(full_index, allocator)
	}

	// No exact match - need literal representation
	// Check if name exists in static table
	static_name_index := static_table_find_name(header.name)
	dynamic_name_index := dynamic_table_find_name(&ctx.dynamic_table, header.name)

	if header.sensitive {
		// Never indexed literal
		if static_name_index > 0 {
			return encode_literal_never_indexed_name(static_name_index, header.value, ctx.huffman, allocator)
		} else if dynamic_name_index >= 0 {
			full_index := 62 + dynamic_name_index
			return encode_literal_never_indexed_name(full_index, header.value, ctx.huffman, allocator)
		} else {
			return encode_literal_never_indexed_new_name(header.name, header.value, ctx.huffman, allocator)
		}
	}

	// Use incremental indexing (add to dynamic table)
	if static_name_index > 0 {
		encoded, enc_ok := encode_literal_incremental_name(static_name_index, header.value, ctx.huffman, allocator)
		if enc_ok {
			dynamic_table_add(&ctx.dynamic_table, header.name, header.value)
		}
		return encoded, enc_ok
	} else if dynamic_name_index >= 0 {
		full_index := 62 + dynamic_name_index
		encoded, enc_ok := encode_literal_incremental_name(full_index, header.value, ctx.huffman, allocator)
		if enc_ok {
			dynamic_table_add(&ctx.dynamic_table, header.name, header.value)
		}
		return encoded, enc_ok
	} else {
		encoded, enc_ok := encode_literal_incremental_new_name(header.name, header.value, ctx.huffman, allocator)
		if enc_ok {
			dynamic_table_add(&ctx.dynamic_table, header.name, header.value)
		}
		return encoded, enc_ok
	}
}

// encode_indexed encodes an indexed header field (RFC 7541 Section 6.1)
// Format: 1xxxxxxx where xxxxxxx is the index (7-bit prefix)
encode_indexed :: proc(index: int, allocator := context.allocator) -> (output: []byte, ok: bool) {
	// Indexed representation has 1-bit pattern prefix (1), 7-bit index
	return integer_encode(7, 1, index, allocator)
}

// encode_literal_incremental_name encodes literal with incremental indexing, indexed name
// Format: 01xxxxxx where xxxxxx is the name index (6-bit prefix)
encode_literal_incremental_name :: proc(name_index: int, value: string, use_huffman: bool, allocator := context.allocator) -> (output: []byte, ok: bool) {
	context.allocator = allocator

	result := make([dynamic]byte, 0, 64, allocator)
	defer if !ok { delete(result) }

	// Encode name index with 6-bit prefix, pattern 01
	name_bytes, name_ok := integer_encode(6, 0b01, name_index, allocator)
	defer delete(name_bytes, allocator)
	if !name_ok {
		return nil, false
	}

	for b in name_bytes {
		append(&result, b)
	}

	// Encode value as string
	value_bytes, value_ok := encode_string(value, use_huffman, allocator)
	defer delete(value_bytes, allocator)
	if !value_ok {
		return nil, false
	}

	for b in value_bytes {
		append(&result, b)
	}

	return result[:], true
}

// encode_literal_incremental_new_name encodes literal with incremental indexing, new name
// Format: 01000000 (no name index) followed by name and value strings
encode_literal_incremental_new_name :: proc(name: string, value: string, use_huffman: bool, allocator := context.allocator) -> (output: []byte, ok: bool) {
	context.allocator = allocator

	result := make([dynamic]byte, 0, 64, allocator)
	defer if !ok { delete(result) }

	// Pattern 01, index 0 (6-bit prefix)
	append(&result, 0x40) // 01000000

	// Encode name as string
	name_bytes, name_ok := encode_string(name, use_huffman, allocator)
	defer delete(name_bytes, allocator)
	if !name_ok {
		return nil, false
	}

	for b in name_bytes {
		append(&result, b)
	}

	// Encode value as string
	value_bytes, value_ok := encode_string(value, use_huffman, allocator)
	defer delete(value_bytes, allocator)
	if !value_ok {
		return nil, false
	}

	for b in value_bytes {
		append(&result, b)
	}

	return result[:], true
}

// encode_literal_never_indexed_name encodes literal never indexed, indexed name
// Format: 0001xxxx where xxxx is the name index (4-bit prefix)
encode_literal_never_indexed_name :: proc(name_index: int, value: string, use_huffman: bool, allocator := context.allocator) -> (output: []byte, ok: bool) {
	context.allocator = allocator

	result := make([dynamic]byte, 0, 64, allocator)
	defer if !ok { delete(result) }

	// Encode name index with 4-bit prefix, pattern 0001
	name_bytes, name_ok := integer_encode(4, 0b0001, name_index, allocator)
	defer delete(name_bytes, allocator)
	if !name_ok {
		return nil, false
	}

	for b in name_bytes {
		append(&result, b)
	}

	// Encode value as string
	value_bytes, value_ok := encode_string(value, use_huffman, allocator)
	defer delete(value_bytes, allocator)
	if !value_ok {
		return nil, false
	}

	for b in value_bytes {
		append(&result, b)
	}

	return result[:], true
}

// encode_literal_never_indexed_new_name encodes literal never indexed, new name
// Format: 00010000 (no name index) followed by name and value strings
encode_literal_never_indexed_new_name :: proc(name: string, value: string, use_huffman: bool, allocator := context.allocator) -> (output: []byte, ok: bool) {
	context.allocator = allocator

	result := make([dynamic]byte, 0, 64, allocator)
	defer if !ok { delete(result) }

	// Pattern 0001, index 0 (4-bit prefix)
	append(&result, 0x10) // 00010000

	// Encode name as string
	name_bytes, name_ok := encode_string(name, use_huffman, allocator)
	defer delete(name_bytes, allocator)
	if !name_ok {
		return nil, false
	}

	for b in name_bytes {
		append(&result, b)
	}

	// Encode value as string
	value_bytes, value_ok := encode_string(value, use_huffman, allocator)
	defer delete(value_bytes, allocator)
	if !value_ok {
		return nil, false
	}

	for b in value_bytes {
		append(&result, b)
	}

	return result[:], true
}

// encode_string encodes a string literal (RFC 7541 Section 5.2)
// Format: H + length + data, where H is Huffman bit (1 = Huffman encoded)
encode_string :: proc(str: string, use_huffman: bool, allocator := context.allocator) -> (output: []byte, ok: bool) {
	context.allocator = allocator

	if use_huffman {
		// Huffman encode the string
		str_bytes := transmute([]byte)str
		huffman_encoded, _, huffman_ok := huffman_encode(str_bytes, allocator)
		defer delete(huffman_encoded, allocator)

		if !huffman_ok {
			return nil, false
		}

		// Encode length with Huffman bit set (7-bit prefix, pattern 1)
		length_bytes, length_ok := integer_encode(7, 1, len(huffman_encoded), allocator)
		defer delete(length_bytes, allocator)

		if !length_ok {
			return nil, false
		}

		result := make([dynamic]byte, 0, len(length_bytes) + len(huffman_encoded), allocator)
		defer if !ok { delete(result) }

		for b in length_bytes {
			append(&result, b)
		}
		for b in huffman_encoded {
			append(&result, b)
		}

		return result[:], true
	} else {
		// Literal string
		// Encode length with Huffman bit clear (7-bit prefix, pattern 0)
		length_bytes, length_ok := integer_encode(7, 0, len(str), allocator)
		defer delete(length_bytes, allocator)

		if !length_ok {
			return nil, false
		}

		result := make([dynamic]byte, 0, len(length_bytes) + len(str), allocator)
		defer if !ok { delete(result) }

		for b in length_bytes {
			append(&result, b)
		}
		str_bytes := transmute([]byte)str
		for b in str_bytes {
			append(&result, b)
		}

		return result[:], true
	}
}

// encoder_set_max_table_size updates the dynamic table maximum size
encoder_set_max_table_size :: proc(ctx: ^Encoder_Context, new_size: int) -> bool {
	if ctx == nil {
		return false
	}

	return dynamic_table_resize(&ctx.dynamic_table, new_size)
}

// encode_table_size_update encodes a dynamic table size update (RFC 7541 Section 6.3)
// Format: 001xxxxx where xxxxx is the new size (5-bit prefix)
encode_table_size_update :: proc(new_size: int, allocator := context.allocator) -> (output: []byte, ok: bool) {
	// Table size update has pattern 001, 5-bit prefix
	return integer_encode(5, 0b001, new_size, allocator)
}
