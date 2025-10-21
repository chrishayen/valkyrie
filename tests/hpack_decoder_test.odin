package valkyrie_tests

import "core:testing"
import "core:slice"
import hpack "../http/hpack"

@(test)
test_decoder_init :: proc(t: ^testing.T) {
	ctx, ok := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	testing.expect(t, ok, "Should initialize successfully")
}

@(test)
test_decode_indexed_static_table :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	// Index 2 = :method GET (0x82 = 10000010)
	input := []byte{0x82}

	header, consumed, err := hpack.decoder_decode_header(&ctx, input)
	defer delete(header.name)
	defer delete(header.value)

	testing.expect(t, err == .None, "Should decode successfully")
	testing.expect(t, consumed == 1, "Should consume 1 byte")
	testing.expect(t, header.name == ":method", "Should have correct name")
	testing.expect(t, header.value == "GET", "Should have correct value")
}

@(test)
test_decode_indexed_invalid :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	// Index 0 is invalid
	input := []byte{0x80}

	_, _, err := hpack.decoder_decode_header(&ctx, input)
	testing.expect(t, err != .None, "Should fail with invalid index")
}

@(test)
test_decode_literal_incremental_new_name :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	// Literal with incremental indexing, new name
	// 0x40 (pattern) + name length + name + value length + value
	input := []byte{
		0x40,           // Literal incremental, new name
		0x0a,           // Name length 10
		'c','u','s','t','o','m','-','k','e','y',
		0x0c,           // Value length 12
		'c','u','s','t','o','m','-','v','a','l','u','e',
	}

	header, consumed, err := hpack.decoder_decode_header(&ctx, input)
	defer delete(header.name)
	defer delete(header.value)

	testing.expect(t, err == .None, "Should decode successfully")
	testing.expect(t, consumed == len(input), "Should consume all bytes")
	testing.expect(t, header.name == "custom-key", "Should have correct name")
	testing.expect(t, header.value == "custom-value", "Should have correct value")

	// Should be added to dynamic table
	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 1, "Should add to dynamic table")
}

@(test)
test_decode_literal_incremental_indexed_name :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	// Literal with incremental indexing, indexed name (:method = index 2)
	// 0x42 (pattern + index 2) + value length + value
	input := []byte{
		0x42,           // Literal incremental, name index 2
		0x06,           // Value length 6
		'D','E','L','E','T','E',
	}

	header, consumed, err := hpack.decoder_decode_header(&ctx, input)
	defer delete(header.name)
	defer delete(header.value)

	testing.expect(t, err == .None, "Should decode successfully")
	testing.expect(t, consumed == len(input), "Should consume all bytes")
	testing.expect(t, header.name == ":method", "Should have correct name from static table")
	testing.expect(t, header.value == "DELETE", "Should have correct value")

	// Should be added to dynamic table
	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 1, "Should add to dynamic table")
}

@(test)
test_decode_literal_never_indexed :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	// Literal never indexed, new name
	// 0x10 (pattern) + name length + name + value length + value
	input := []byte{
		0x10,           // Never indexed, new name
		0x08,           // Name length 8
		'p','a','s','s','w','o','r','d',
		0x06,           // Value length 6
		's','e','c','r','e','t',
	}

	header, consumed, err := hpack.decoder_decode_header(&ctx, input)
	defer delete(header.name)
	defer delete(header.value)

	testing.expect(t, err == .None, "Should decode successfully")
	testing.expect(t, consumed == len(input), "Should consume all bytes")
	testing.expect(t, header.name == "password", "Should have correct name")
	testing.expect(t, header.value == "secret", "Should have correct value")
	testing.expect(t, header.sensitive == true, "Should mark as sensitive")

	// Should NOT be added to dynamic table
	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 0, "Should NOT add to dynamic table")
}

@(test)
test_decode_literal_without_indexing :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	// Literal without indexing, new name
	// 0x00 (pattern) + name length + name + value length + value
	input := []byte{
		0x00,           // Without indexing, new name
		0x04,           // Name length 4
		't','e','s','t',
		0x05,           // Value length 5
		'v','a','l','u','e',
	}

	header, consumed, err := hpack.decoder_decode_header(&ctx, input)
	defer delete(header.name)
	defer delete(header.value)

	testing.expect(t, err == .None, "Should decode successfully")
	testing.expect(t, consumed == len(input), "Should consume all bytes")
	testing.expect(t, header.name == "test", "Should have correct name")
	testing.expect(t, header.value == "value", "Should have correct value")

	// Should NOT be added to dynamic table
	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 0, "Should NOT add to dynamic table")
}

@(test)
test_decode_multiple_headers :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	// Two headers: :method GET (indexed) + custom literal
	input := []byte{
		0x82,           // Index 2 (:method GET)
		0x40,           // Literal incremental, new name
		0x03,           // Name length 3
		'k','e','y',
		0x05,           // Value length 5
		'v','a','l','u','e',
	}

	headers, err := hpack.decoder_decode_headers(&ctx, input)
	defer {
		for h in headers {
			delete(h.name)
			delete(h.value)
		}
		delete(headers)
	}

	testing.expect(t, err == .None, "Should decode successfully")
	testing.expect(t, len(headers) == 2, "Should have 2 headers")

	testing.expect(t, headers[0].name == ":method", "First header name")
	testing.expect(t, headers[0].value == "GET", "First header value")

	testing.expect(t, headers[1].name == "key", "Second header name")
	testing.expect(t, headers[1].value == "value", "Second header value")
}

@(test)
test_decode_huffman_string :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	// "www.example.com" Huffman encoded: f1e3 c2e5 f23a 6ba0 ab90 f4ff
	// With Huffman bit set and length
	input := []byte{
		0x40,           // Literal incremental, new name
		0x8c,           // Huffman bit set, length 12
		0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff,
		0x00,           // Empty value
	}

	header, consumed, err := hpack.decoder_decode_header(&ctx, input)
	defer delete(header.name)
	defer delete(header.value)

	testing.expect(t, err == .None, "Should decode Huffman string")
	testing.expect(t, header.name == "www.example.com", "Should decode correctly")
}

@(test)
test_decode_table_size_update :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	// Add an entry first
	input1 := []byte{
		0x40, 0x03, 'k','e','y', 0x05, 'v','a','l','u','e',
	}
	header1, _, _ := hpack.decoder_decode_header(&ctx, input1)
	defer delete(header1.name)
	defer delete(header1.value)

	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 1, "Should have 1 entry")

	// Table size update to 0 (should clear table)
	// Pattern 001, size 0 = 0x20
	input2 := []byte{0x20}

	_, consumed, err := hpack.decoder_decode_header(&ctx, input2)
	testing.expect(t, err == .None, "Should decode table size update")
	testing.expect(t, consumed == 1, "Should consume 1 byte")
	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 0, "Should clear table")
}

@(test)
test_decode_dynamic_table_lookup :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	// Add header to dynamic table
	input1 := []byte{
		0x40, 0x03, 'k','e','y', 0x05, 'v','a','l','u','e',
	}
	header1, _, _ := hpack.decoder_decode_header(&ctx, input1)
	defer delete(header1.name)
	defer delete(header1.value)

	// Now reference it by index (62 = first dynamic table entry)
	// 62 in indexed representation: 10111110 = 0xBE
	input2 := []byte{0xBE}

	header, consumed, err := hpack.decoder_decode_header(&ctx, input2)
	defer delete(header.name)
	defer delete(header.value)

	testing.expect(t, err == .None, "Should decode indexed from dynamic table")
	testing.expect(t, consumed == 1, "Should consume 1 byte")
	testing.expect(t, header.name == "key", "Should have correct name")
	testing.expect(t, header.value == "value", "Should have correct value")
}

@(test)
test_decoder_encode_decode_roundtrip :: proc(t: ^testing.T) {
	// Test encoder/decoder roundtrip
	enc_ctx, _ := hpack.encoder_init(4096, false)
	defer hpack.encoder_destroy(&enc_ctx)

	dec_ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&dec_ctx)

	original_headers := []hpack.Header{
		{name = ":method", value = "GET"},
		{name = ":path", value = "/test"},
		{name = "custom-key", value = "custom-value"},
	}

	// Encode
	encoded, enc_ok := hpack.encoder_encode_headers(&enc_ctx, original_headers)
	defer delete(encoded)
	testing.expect(t, enc_ok, "Should encode")

	// Decode
	decoded_headers, dec_err := hpack.decoder_decode_headers(&dec_ctx, encoded)
	defer {
		for h in decoded_headers {
			delete(h.name)
			delete(h.value)
		}
		delete(decoded_headers)
	}

	testing.expect(t, dec_err == .None, "Should decode")
	testing.expect(t, len(decoded_headers) == len(original_headers), "Should have same number of headers")

	for i in 0..<len(original_headers) {
		testing.expect(t, decoded_headers[i].name == original_headers[i].name, "Names should match")
		testing.expect(t, decoded_headers[i].value == original_headers[i].value, "Values should match")
	}
}

@(test)
test_decode_incomplete_data :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	// Incomplete literal (missing value)
	input := []byte{
		0x40, 0x03, 'k','e','y',
		// Missing value length and data
	}

	_, _, err := hpack.decoder_decode_header(&ctx, input)
	testing.expect(t, err != .None, "Should fail with incomplete data")
}

@(test)
test_decode_header_size_limit :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096, 50) // Very small max header size
	defer hpack.decoder_destroy(&ctx)

	// Header larger than limit
	input := []byte{
		0x40,
		0x20, // Name length 32
		'a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p',
		'q','r','s','t','u','v','w','x','y','z','1','2','3','4','5','6',
		0x20, // Value length 32
		'a','b','c','d','e','f','g','h','i','j','k','l','m','n','o','p',
		'q','r','s','t','u','v','w','x','y','z','1','2','3','4','5','6',
	}

	_, err := hpack.decoder_decode_headers(&ctx, input)
	testing.expect(t, err == .Header_Too_Large, "Should fail with header too large")
}

@(test)
test_decoder_set_max_table_size :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	// Add entry
	input := []byte{
		0x40, 0x03, 'k','e','y', 0x05, 'v','a','l','u','e',
	}
	header, _, _ := hpack.decoder_decode_header(&ctx, input)
	defer delete(header.name)
	defer delete(header.value)

	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 1, "Should have 1 entry")

	// Resize to 0
	ok := hpack.decoder_set_max_table_size(&ctx, 0)
	testing.expect(t, ok, "Should resize")
	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 0, "Should clear table")
}

@(test)
test_decode_empty_input :: proc(t: ^testing.T) {
	ctx, _ := hpack.decoder_init(4096)
	defer hpack.decoder_destroy(&ctx)

	input := []byte{}

	headers, err := hpack.decoder_decode_headers(&ctx, input)
	defer delete(headers)

	testing.expect(t, err == .None, "Empty input should succeed")
	testing.expect(t, len(headers) == 0, "Should have no headers")
}
