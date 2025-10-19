package hpack

import "base:runtime"

// Decoder_Context maintains the decoding state including the dynamic table
Decoder_Context :: struct {
	dynamic_table:   Dynamic_Table,
	max_header_size: int, // Maximum total size of decoded headers (prevents DoS)
	huffman_tree:    ^Huffman_Decode_Node, // Cached Huffman decode tree
	allocator:       runtime.Allocator,
}

// Decoder_Error represents decoding errors
Decoder_Error :: enum {
	None,
	Invalid_Index,
	Invalid_Encoding,
	Invalid_String,
	Header_Too_Large,
	Incomplete_Data,
}

// decoder_init creates a new decoder context
decoder_init :: proc(
	max_table_size: int,
	max_header_size := 8192,
	allocator := context.allocator,
) -> (
	ctx: Decoder_Context,
	ok: bool,
) {
	table, table_ok := dynamic_table_init(max_table_size, allocator)
	if !table_ok {
		return {}, false
	}

	// Build Huffman decode tree once and cache it
	huffman_tree, tree_ok := huffman_decode_tree_build(allocator)
	if !tree_ok {
		dynamic_table_destroy(&table)
		return {}, false
	}

	return Decoder_Context {
			dynamic_table = table,
			max_header_size = max_header_size,
			huffman_tree = huffman_tree,
			allocator = allocator,
		},
		true
}

// decoder_destroy frees all resources used by the decoder
decoder_destroy :: proc(ctx: ^Decoder_Context) {
	if ctx == nil {
		return
	}

	dynamic_table_destroy(&ctx.dynamic_table)
	huffman_decode_tree_destroy(ctx.huffman_tree, ctx.allocator)
}

// decoder_decode_headers decodes HPACK-encoded headers
decoder_decode_headers :: proc(
	ctx: ^Decoder_Context,
	input: []byte,
	allocator := context.allocator,
) -> (
	headers: []Header,
	err: Decoder_Error,
) {
	if ctx == nil {
		return nil, .Invalid_Encoding
	}

	context.allocator = allocator

	result := make([dynamic]Header, 0, 16, allocator)
	defer if err != .None {
		for h in result {
			delete(h.name, allocator)
			delete(h.value, allocator)
		}
		delete(result)
	}

	offset := 0
	total_size := 0

	for offset < len(input) {
		header, bytes_consumed, decode_err := decoder_decode_header(ctx, input[offset:], allocator)
		if decode_err != .None {
			return nil, decode_err
		}

		// Skip empty headers from table size updates
		if len(header.name) == 0 && len(header.value) == 0 {
			offset += bytes_consumed
			continue
		}

		// Check header size limit
		total_size += len(header.name) + len(header.value)
		if total_size > ctx.max_header_size {
			delete(header.name, allocator)
			delete(header.value, allocator)
			return nil, .Header_Too_Large
		}

		append(&result, header)
		offset += bytes_consumed
	}

	return result[:], .None
}

// decoder_decode_header decodes a single header field
decoder_decode_header :: proc(
	ctx: ^Decoder_Context,
	input: []byte,
	allocator := context.allocator,
) -> (
	header: Header,
	bytes_consumed: int,
	err: Decoder_Error,
) {
	if ctx == nil || len(input) == 0 {
		return {}, 0, .Incomplete_Data
	}

	context.allocator = allocator

	first_byte := input[0]

	// Check representation type by examining bit pattern
	if (first_byte & 0x80) != 0 {
		// 1xxxxxxx - Indexed Header Field
		return decode_indexed_field(ctx, input, allocator)
	} else if (first_byte & 0x40) != 0 {
		// 01xxxxxx - Literal Header Field with Incremental Indexing
		return decode_literal_incremental(ctx, input, allocator)
	} else if (first_byte & 0x20) != 0 {
		// 001xxxxx - Dynamic Table Size Update
		return decode_table_size_update(ctx, input, allocator)
	} else if (first_byte & 0x10) != 0 {
		// 0001xxxx - Literal Header Field Never Indexed
		return decode_literal_never_indexed(ctx, input, allocator)
	} else {
		// 0000xxxx - Literal Header Field without Indexing
		return decode_literal_without_indexing(ctx, input, allocator)
	}
}

// decode_indexed_field decodes an indexed header field (RFC 7541 Section 6.1)
decode_indexed_field :: proc(
	ctx: ^Decoder_Context,
	input: []byte,
	allocator := context.allocator,
) -> (
	header: Header,
	bytes_consumed: int,
	err: Decoder_Error,
) {
	context.allocator = allocator

	// Decode index (7-bit prefix)
	index, consumed, decode_ok := integer_decode(input, 7)
	if !decode_ok {
		return {}, 0, .Invalid_Encoding
	}

	if index == 0 {
		return {}, 0, .Invalid_Index
	}

	// Lookup in tables
	name, value: string
	found: bool

	if index <= 61 {
		// Static table
		entry: Static_Table_Entry
		entry, found = static_table_lookup(index)
		if !found {
			return {}, 0, .Invalid_Index
		}
		name = entry.name
		value = entry.value
	} else {
		// Dynamic table
		dynamic_index := index - 62
		entry: Dynamic_Table_Entry
		entry, found = dynamic_table_lookup(&ctx.dynamic_table, dynamic_index)
		if !found {
			return {}, 0, .Invalid_Index
		}
		name = entry.name
		value = entry.value
	}

	// Copy strings for ownership
	name_copy := make([]byte, len(name), allocator)
	if name_copy == nil {
		return {}, 0, .Invalid_Encoding
	}
	copy(name_copy, transmute([]byte)name)

	value_copy := make([]byte, len(value), allocator)
	if value_copy == nil {
		delete(name_copy, allocator)
		return {}, 0, .Invalid_Encoding
	}
	copy(value_copy, transmute([]byte)value)

	return Header{name = string(name_copy), value = string(value_copy), sensitive = false},
		consumed,
		.None
}

// decode_literal_incremental decodes literal with incremental indexing
decode_literal_incremental :: proc(
	ctx: ^Decoder_Context,
	input: []byte,
	allocator := context.allocator,
) -> (
	header: Header,
	bytes_consumed: int,
	err: Decoder_Error,
) {
	context.allocator = allocator

	offset := 0

	// Decode name index (6-bit prefix)
	name_index, name_consumed, name_ok := integer_decode(input, 6)
	if !name_ok {
		return {}, 0, .Invalid_Encoding
	}
	offset += name_consumed

	name: string
	if name_index == 0 {
		// New name - decode string
		decoded_name, string_consumed, string_err := decode_string(input[offset:], ctx.huffman_tree, allocator)
		if string_err != .None {
			return {}, 0, string_err
		}
		name = decoded_name
		offset += string_consumed
	} else {
		// Indexed name
		name_str, found := lookup_name(ctx, name_index)
		if !found {
			return {}, 0, .Invalid_Index
		}

		// Copy for ownership
		name_copy := make([]byte, len(name_str), allocator)
		if name_copy == nil {
			return {}, 0, .Invalid_Encoding
		}
		copy(name_copy, transmute([]byte)name_str)
		name = string(name_copy)
	}

	// Decode value string
	value, value_consumed, value_err := decode_string(input[offset:], ctx.huffman_tree, allocator)
	if value_err != .None {
		delete(name, allocator)
		return {}, 0, value_err
	}
	offset += value_consumed

	// Add to dynamic table
	dynamic_table_add(&ctx.dynamic_table, name, value)

	return Header{name = name, value = value, sensitive = false}, offset, .None
}

// decode_literal_without_indexing decodes literal without indexing
decode_literal_without_indexing :: proc(
	ctx: ^Decoder_Context,
	input: []byte,
	allocator := context.allocator,
) -> (
	header: Header,
	bytes_consumed: int,
	err: Decoder_Error,
) {
	context.allocator = allocator

	offset := 0

	// Decode name index (4-bit prefix)
	name_index, name_consumed, name_ok := integer_decode(input, 4)
	if !name_ok {
		return {}, 0, .Invalid_Encoding
	}
	offset += name_consumed

	name: string
	if name_index == 0 {
		// New name
		decoded_name, string_consumed, string_err := decode_string(input[offset:], ctx.huffman_tree, allocator)
		if string_err != .None {
			return {}, 0, string_err
		}
		name = decoded_name
		offset += string_consumed
	} else {
		// Indexed name
		name_str, found := lookup_name(ctx, name_index)
		if !found {
			return {}, 0, .Invalid_Index
		}

		name_copy := make([]byte, len(name_str), allocator)
		if name_copy == nil {
			return {}, 0, .Invalid_Encoding
		}
		copy(name_copy, transmute([]byte)name_str)
		name = string(name_copy)
	}

	// Decode value string
	value, value_consumed, value_err := decode_string(input[offset:], ctx.huffman_tree, allocator)
	if value_err != .None {
		delete(name, allocator)
		return {}, 0, value_err
	}
	offset += value_consumed

	return Header{name = name, value = value, sensitive = false}, offset, .None
}

// decode_literal_never_indexed decodes literal never indexed
decode_literal_never_indexed :: proc(
	ctx: ^Decoder_Context,
	input: []byte,
	allocator := context.allocator,
) -> (
	header: Header,
	bytes_consumed: int,
	err: Decoder_Error,
) {
	context.allocator = allocator

	offset := 0

	// Decode name index (4-bit prefix)
	name_index, name_consumed, name_ok := integer_decode(input, 4)
	if !name_ok {
		return {}, 0, .Invalid_Encoding
	}
	offset += name_consumed

	name: string
	if name_index == 0 {
		// New name
		decoded_name, string_consumed, string_err := decode_string(input[offset:], ctx.huffman_tree, allocator)
		if string_err != .None {
			return {}, 0, string_err
		}
		name = decoded_name
		offset += string_consumed
	} else {
		// Indexed name
		name_str, found := lookup_name(ctx, name_index)
		if !found {
			return {}, 0, .Invalid_Index
		}

		name_copy := make([]byte, len(name_str), allocator)
		if name_copy == nil {
			return {}, 0, .Invalid_Encoding
		}
		copy(name_copy, transmute([]byte)name_str)
		name = string(name_copy)
	}

	// Decode value string
	value, value_consumed, value_err := decode_string(input[offset:], ctx.huffman_tree, allocator)
	if value_err != .None {
		delete(name, allocator)
		return {}, 0, value_err
	}
	offset += value_consumed

	return Header{name = name, value = value, sensitive = true}, offset, .None
}

// decode_table_size_update decodes a dynamic table size update
decode_table_size_update :: proc(
	ctx: ^Decoder_Context,
	input: []byte,
	allocator := context.allocator,
) -> (
	header: Header,
	bytes_consumed: int,
	err: Decoder_Error,
) {
	// Decode new size (5-bit prefix)
	new_size, consumed, decode_ok := integer_decode(input, 5)
	if !decode_ok {
		return {}, 0, .Invalid_Encoding
	}

	// Update table size
	resize_ok := dynamic_table_resize(&ctx.dynamic_table, new_size)
	if !resize_ok {
		return {}, 0, .Invalid_Encoding
	}

	// Table size updates don't produce a header, return empty header
	return Header{}, consumed, .None
}

// decode_string decodes a string literal (RFC 7541 Section 5.2)
decode_string :: proc(
	input: []byte,
	huffman_tree: ^Huffman_Decode_Node,
	allocator := context.allocator,
) -> (
	output: string,
	bytes_consumed: int,
	err: Decoder_Error,
) {
	if len(input) == 0 {
		return "", 0, .Incomplete_Data
	}

	context.allocator = allocator

	// Check Huffman bit
	is_huffman := (input[0] & 0x80) != 0

	// Decode length (7-bit prefix)
	length, length_consumed, length_ok := integer_decode(input, 7)
	if !length_ok {
		return "", 0, .Invalid_String
	}

	offset := length_consumed

	if offset + length > len(input) {
		return "", 0, .Incomplete_Data
	}

	string_data := input[offset:offset + length]

	if is_huffman {
		// Huffman decode using cached tree
		if huffman_tree == nil {
			return "", 0, .Invalid_String
		}

		decoded, decode_ok := huffman_decode(string_data, huffman_tree, allocator)
		if !decode_ok {
			return "", 0, .Invalid_String
		}

		return string(decoded), offset + length, .None
	} else {
		// Literal string - copy it
		if length == 0 {
			// Empty string is valid (make would return nil for 0-length)
			return "", offset, .None
		}

		str_copy := make([]byte, length, allocator)
		if str_copy == nil {
			return "", 0, .Invalid_String
		}
		copy(str_copy, string_data)

		return string(str_copy), offset + length, .None
	}
}

// lookup_name looks up a name by index in static or dynamic table
lookup_name :: proc(ctx: ^Decoder_Context, index: int) -> (name: string, found: bool) {
	if index <= 61 {
		// Static table
		entry, entry_found := static_table_lookup(index)
		return entry.name, entry_found
	} else {
		// Dynamic table
		dynamic_index := index - 62
		entry, entry_found := dynamic_table_lookup(&ctx.dynamic_table, dynamic_index)
		return entry.name, entry_found
	}
}

// decoder_set_max_table_size updates the dynamic table maximum size
decoder_set_max_table_size :: proc(ctx: ^Decoder_Context, new_size: int) -> bool {
	if ctx == nil {
		return false
	}

	return dynamic_table_resize(&ctx.dynamic_table, new_size)
}

