package valkyrie_tests

import "core:testing"
import "core:slice"
import hpack "../http2/hpack"

@(test)
test_encoder_init :: proc(t: ^testing.T) {
	ctx, ok := hpack.encoder_init(4096)
	defer hpack.encoder_destroy(&ctx)

	testing.expect(t, ok, "Should initialize successfully")
}

@(test)
test_encode_indexed_small :: proc(t: ^testing.T) {
	// Encode index 2 (:method GET)
	encoded, ok := hpack.encode_indexed(2)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	testing.expect(t, len(encoded) == 1, "Should be 1 byte")
	testing.expect(t, encoded[0] == 0x82, "Should be 0x82 (10000010)")
}

@(test)
test_encode_indexed_large :: proc(t: ^testing.T) {
	// Encode index 127 (requires multi-byte)
	encoded, ok := hpack.encode_indexed(127)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	testing.expect(t, len(encoded) == 2, "Should be 2 bytes")
	testing.expect(t, encoded[0] == 0xFF, "First byte should be 0xFF")
	testing.expect(t, encoded[1] == 0x00, "Second byte should be 0x00")
}

@(test)
test_encode_string_literal :: proc(t: ^testing.T) {
	encoded, ok := hpack.encode_string("hello", false)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	// Length byte (5) + 5 bytes for "hello"
	testing.expect(t, len(encoded) == 6, "Should be 6 bytes")
	testing.expect(t, encoded[0] == 5, "First byte should be length 5")
	testing.expect(t, string(encoded[1:]) == "hello", "Should contain 'hello'")
}

@(test)
test_encode_string_huffman :: proc(t: ^testing.T) {
	encoded, ok := hpack.encode_string("www.example.com", true)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	// First byte should have Huffman bit set and contain length
	testing.expect(t, (encoded[0] & 0x80) != 0, "Huffman bit should be set")
}

@(test)
test_encode_literal_incremental_new_name :: proc(t: ^testing.T) {
	encoded, ok := hpack.encode_literal_incremental_new_name("custom-key", "custom-value", false)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	// First byte should be 0x40 (01000000)
	testing.expect(t, encoded[0] == 0x40, "Should start with 0x40")
}

@(test)
test_encode_literal_never_indexed_new_name :: proc(t: ^testing.T) {
	encoded, ok := hpack.encode_literal_never_indexed_new_name("password", "secret", false)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	// First byte should be 0x10 (00010000)
	testing.expect(t, encoded[0] == 0x10, "Should start with 0x10")
}

@(test)
test_encoder_static_table_exact_match :: proc(t: ^testing.T) {
	ctx, _ := hpack.encoder_init(4096, false) // Disable Huffman for simpler testing
	defer hpack.encoder_destroy(&ctx)

	// :method GET is at static table index 2
	header := hpack.Header{name = ":method", value = "GET"}
	encoded, ok := hpack.encoder_encode_header(&ctx, header)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	testing.expect(t, len(encoded) == 1, "Should be 1 byte (indexed)")
	testing.expect(t, encoded[0] == 0x82, "Should be indexed representation of index 2")
}

@(test)
test_encoder_static_table_name_match :: proc(t: ^testing.T) {
	ctx, _ := hpack.encoder_init(4096, false)
	defer hpack.encoder_destroy(&ctx)

	// :method exists in static table (index 2), but value differs
	header := hpack.Header{name = ":method", value = "DELETE"}
	encoded, ok := hpack.encoder_encode_header(&ctx, header)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	// Should use literal with incremental indexing, indexed name
	// First byte: 01xxxxxx where xxxxxx is the name index
	// For index 2: 01000010 = 0x42
	testing.expect(t, encoded[0] == 0x42, "Should use indexed name 2")

	// Should have added to dynamic table
	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 1, "Should add to dynamic table")
}

@(test)
test_encoder_new_header :: proc(t: ^testing.T) {
	ctx, _ := hpack.encoder_init(4096, false)
	defer hpack.encoder_destroy(&ctx)

	header := hpack.Header{name = "custom-key", value = "custom-value"}
	encoded, ok := hpack.encoder_encode_header(&ctx, header)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	// Should use literal with incremental indexing, new name
	testing.expect(t, encoded[0] == 0x40, "Should start with 0x40")

	// Should have added to dynamic table
	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 1, "Should add to dynamic table")

	// Verify entry in dynamic table
	entry, entry_ok := hpack.dynamic_table_lookup(&ctx.dynamic_table, 0)
	testing.expect(t, entry_ok, "Should find entry")
	testing.expect(t, entry.name == "custom-key", "Should have correct name")
	testing.expect(t, entry.value == "custom-value", "Should have correct value")
}

@(test)
test_encoder_sensitive_header :: proc(t: ^testing.T) {
	ctx, _ := hpack.encoder_init(4096, false)
	defer hpack.encoder_destroy(&ctx)

	header := hpack.Header{name = "authorization", value = "Bearer token123", sensitive = true}
	encoded, ok := hpack.encoder_encode_header(&ctx, header)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	// Should use never indexed representation (pattern 0001)
	testing.expect(t, (encoded[0] & 0xF0) == 0x10, "Should use never indexed pattern")

	// Should NOT add to dynamic table
	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 0, "Should NOT add sensitive header to table")
}

@(test)
test_encoder_dynamic_table_lookup :: proc(t: ^testing.T) {
	ctx, _ := hpack.encoder_init(4096, false)
	defer hpack.encoder_destroy(&ctx)

	// Add header twice - second time should find it in dynamic table
	header := hpack.Header{name = "custom-key", value = "custom-value"}

	// First encoding - adds to dynamic table
	encoded1, ok1 := hpack.encoder_encode_header(&ctx, header)
	defer delete(encoded1)
	testing.expect(t, ok1, "Should encode first time")
	testing.expect(t, encoded1[0] == 0x40, "First time should be literal")

	// Second encoding - should find in dynamic table
	encoded2, ok2 := hpack.encoder_encode_header(&ctx, header)
	defer delete(encoded2)
	testing.expect(t, ok2, "Should encode second time")
	// Dynamic table index 0 + 62 (static table size + 1) = 62
	// Indexed with index 62: 10111110 = 0xBE
	testing.expect(t, encoded2[0] == 0xBE, "Second time should be indexed from dynamic table")
}

@(test)
test_encoder_multiple_headers :: proc(t: ^testing.T) {
	ctx, _ := hpack.encoder_init(4096, false)
	defer hpack.encoder_destroy(&ctx)

	headers := []hpack.Header{
		{name = ":method", value = "GET"},
		{name = ":path", value = "/"},
		{name = "custom-key", value = "custom-value"},
	}

	encoded, ok := hpack.encoder_encode_headers(&ctx, headers)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode all headers")
	testing.expect(t, len(encoded) > 0, "Should have output")

	// Verify dynamic table has the custom header
	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 1, "Should have custom header in table")
}

@(test)
test_encode_table_size_update :: proc(t: ^testing.T) {
	encoded, ok := hpack.encode_table_size_update(4096)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	// Pattern 001, 5-bit prefix for size
	// 4096 = 0x1000, requires multi-byte encoding
	testing.expect(t, (encoded[0] & 0xE0) == 0x20, "Should have pattern 001")
}

@(test)
test_encoder_set_max_table_size :: proc(t: ^testing.T) {
	ctx, _ := hpack.encoder_init(4096, false)
	defer hpack.encoder_destroy(&ctx)

	// Add some entries
	header := hpack.Header{name = "key1", value = "value1"}
	encoded, _ := hpack.encoder_encode_header(&ctx, header)
	defer delete(encoded)

	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 1, "Should have 1 entry")

	// Reduce table size to 0
	ok := hpack.encoder_set_max_table_size(&ctx, 0)
	testing.expect(t, ok, "Should resize successfully")
	testing.expect(t, hpack.dynamic_table_length(&ctx.dynamic_table) == 0, "Should evict all entries")
}

@(test)
test_encoder_with_huffman :: proc(t: ^testing.T) {
	ctx, _ := hpack.encoder_init(4096, true) // Enable Huffman
	defer hpack.encoder_destroy(&ctx)

	header := hpack.Header{name = "custom-key", value = "custom-value"}
	encoded, ok := hpack.encoder_encode_header(&ctx, header)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode with Huffman")
	// Output should be smaller than literal encoding due to Huffman compression
	testing.expect(t, len(encoded) > 0, "Should have output")
}

@(test)
test_encoder_without_huffman :: proc(t: ^testing.T) {
	ctx, _ := hpack.encoder_init(4096, false) // Disable Huffman
	defer hpack.encoder_destroy(&ctx)

	header := hpack.Header{name = "custom-key", value = "custom-value"}
	encoded, ok := hpack.encoder_encode_header(&ctx, header)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode without Huffman")
	testing.expect(t, len(encoded) > 0, "Should have output")
}

// RFC 7541 Appendix C.2.1: Literal Header Field with Incremental Indexing - Indexed Name
@(test)
test_encoder_rfc_c2_1 :: proc(t: ^testing.T) {
	ctx, _ := hpack.encoder_init(4096, false)
	defer hpack.encoder_destroy(&ctx)

	// custom-key: custom-header
	// "custom-key" is not in static table, so this will be literal with new name
	header := hpack.Header{name = "custom-key", value = "custom-header"}
	encoded, ok := hpack.encoder_encode_header(&ctx, header)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	// Should start with 0x40 (literal with incremental indexing, new name)
	testing.expect(t, encoded[0] == 0x40, "Should be literal with new name")
}

// Test that encoding same header twice uses dynamic table second time
@(test)
test_encoder_reuse_dynamic_entry :: proc(t: ^testing.T) {
	ctx, _ := hpack.encoder_init(4096, false)
	defer hpack.encoder_destroy(&ctx)

	header := hpack.Header{name = "x-custom", value = "test"}

	// First time: literal with incremental indexing
	enc1, _ := hpack.encoder_encode_header(&ctx, header)
	defer delete(enc1)
	len1 := len(enc1)

	// Second time: should be indexed (much shorter)
	enc2, _ := hpack.encoder_encode_header(&ctx, header)
	defer delete(enc2)
	len2 := len(enc2)

	testing.expect(t, len2 < len1, "Second encoding should be shorter (indexed)")
	testing.expect(t, len2 <= 2, "Indexed encoding should be 1-2 bytes")
}
