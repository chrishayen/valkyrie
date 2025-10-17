package http_tests

import "core:testing"
import "core:slice"
import "core:fmt"
import hpack "../http2/hpack"

@(test)
test_huffman_table_size :: proc(t: ^testing.T) {
	testing.expect(t, len(hpack.HUFFMAN_CODES) == 256, "Huffman table should have 256 entries")
}

@(test)
test_huffman_codes_valid :: proc(t: ^testing.T) {
	// Verify all codes have valid lengths (5-30 bits per RFC 7541)
	for code, i in hpack.HUFFMAN_CODES {
		testing.expect(t, code.length >= 5 && code.length <= 30, "Code length should be between 5-30 bits")
	}
}

@(test)
test_huffman_common_chars :: proc(t: ^testing.T) {
	// Common characters should have shorter codes
	// Space (32) should have 6 bits
	testing.expect(t, hpack.HUFFMAN_CODES[' '].length == 6, "Space should have 6-bit code")

	// Digits '0'-'9' should have short codes (5-6 bits)
	for c in '0'..='9' {
		length := hpack.HUFFMAN_CODES[c].length
		testing.expect(t, length <= 6, "Digits should have short codes")
	}

	// Lowercase letters 'a'-'z' should have short codes
	for c in 'a'..='z' {
		length := hpack.HUFFMAN_CODES[c].length
		testing.expect(t, length <= 7, "Lowercase letters should have short codes")
	}
}

@(test)
test_huffman_decode_tree_build :: proc(t: ^testing.T) {
	tree, ok := hpack.huffman_decode_tree_build()
	defer hpack.huffman_decode_tree_destroy(tree)

	testing.expect(t, ok, "Should build decode tree successfully")
	testing.expect(t, tree != nil, "Tree root should not be nil")
	testing.expect(t, !tree.is_leaf, "Root should not be a leaf")
}

@(test)
test_huffman_encode_empty :: proc(t: ^testing.T) {
	output, padding, ok := hpack.huffman_encode(nil)
	defer delete(output)

	testing.expect(t, ok, "Should encode empty input")
	testing.expect(t, len(output) == 0, "Empty input should produce empty output")
	testing.expect(t, padding == 0, "Empty input should have no padding")
}

@(test)
test_huffman_decode_empty :: proc(t: ^testing.T) {
	tree, _ := hpack.huffman_decode_tree_build()
	defer hpack.huffman_decode_tree_destroy(tree)

	output, ok := hpack.huffman_decode(nil, tree)
	defer delete(output)

	testing.expect(t, ok, "Should decode empty input")
	testing.expect(t, len(output) == 0, "Empty input should produce empty output")
}

@(test)
test_huffman_encode_single_char :: proc(t: ^testing.T) {
	input := []byte{'a'}
	output, padding, ok := hpack.huffman_encode(input)
	defer delete(output)

	testing.expect(t, ok, "Should encode single character")
	testing.expect(t, len(output) > 0, "Output should not be empty")

	// 'a' has code 0x3 with length 5, so it should fit in 1 byte with padding
	testing.expect(t, len(output) == 1, "Single char should fit in one byte")
	testing.expect(t, padding == 3, "'a' (5 bits) should have 3 padding bits")
}

@(test)
test_huffman_roundtrip_single_char :: proc(t: ^testing.T) {
	tree, _ := hpack.huffman_decode_tree_build()
	defer hpack.huffman_decode_tree_destroy(tree)

	input := []byte{'a'}
	encoded, _, ok := hpack.huffman_encode(input)
	defer delete(encoded)
	testing.expect(t, ok, "Should encode")

	decoded, ok2 := hpack.huffman_decode(encoded, tree)
	defer delete(decoded)
	testing.expect(t, ok2, "Should decode")

	testing.expect(t, slice.equal(decoded, input), "Decoded should match input")
}

@(test)
test_huffman_roundtrip_simple_string :: proc(t: ^testing.T) {
	tree, _ := hpack.huffman_decode_tree_build()
	defer hpack.huffman_decode_tree_destroy(tree)

	input := transmute([]byte)string("hello")
	encoded, _, ok := hpack.huffman_encode(input)
	defer delete(encoded)
	testing.expect(t, ok, "Should encode")

	decoded, ok2 := hpack.huffman_decode(encoded, tree)
	defer delete(decoded)
	testing.expect(t, ok2, "Should decode")

	testing.expect(t, slice.equal(decoded, input), "Decoded should match input")
}

@(test)
test_huffman_roundtrip_all_ascii :: proc(t: ^testing.T) {
	tree, _ := hpack.huffman_decode_tree_build()
	defer hpack.huffman_decode_tree_destroy(tree)

	// Test all printable ASCII characters
	input := make([]byte, 95)
	defer delete(input)

	for i in 0..<95 {
		input[i] = byte(32 + i) // ASCII 32-126
	}

	encoded, _, ok := hpack.huffman_encode(input)
	defer delete(encoded)
	testing.expect(t, ok, "Should encode all ASCII")

	decoded, ok2 := hpack.huffman_decode(encoded, tree)
	defer delete(decoded)
	testing.expect(t, ok2, "Should decode all ASCII")

	testing.expect(t, slice.equal(decoded, input), "Decoded should match input")
}

@(test)
test_huffman_rfc_example_1 :: proc(t: ^testing.T) {
	// RFC 7541 Appendix C.4.1: "www.example.com"
	tree, _ := hpack.huffman_decode_tree_build()
	defer hpack.huffman_decode_tree_destroy(tree)

	input := transmute([]byte)string("www.example.com")
	encoded, _, ok := hpack.huffman_encode(input)
	defer delete(encoded)
	testing.expect(t, ok, "Should encode")

	// RFC specifies the encoded form is: f1e3 c2e5 f23a 6ba0 ab90 f4ff
	expected := []byte{0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff}

	testing.expect(t, slice.equal(encoded, expected), "Encoded should match RFC example")

	decoded, ok2 := hpack.huffman_decode(encoded, tree)
	defer delete(decoded)
	testing.expect(t, ok2, "Should decode")

	testing.expect(t, slice.equal(decoded, input), "Decoded should match input")
}

@(test)
test_huffman_rfc_example_2 :: proc(t: ^testing.T) {
	// RFC 7541 Appendix C.4.2: "no-cache"
	tree, _ := hpack.huffman_decode_tree_build()
	defer hpack.huffman_decode_tree_destroy(tree)

	input := transmute([]byte)string("no-cache")
	encoded, _, ok := hpack.huffman_encode(input)
	defer delete(encoded)
	testing.expect(t, ok, "Should encode")

	// RFC specifies: a8eb 1064 9cbf
	expected := []byte{0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf}

	testing.expect(t, slice.equal(encoded, expected), "Encoded should match RFC example")

	decoded, ok2 := hpack.huffman_decode(encoded, tree)
	defer delete(decoded)
	testing.expect(t, ok2, "Should decode")

	testing.expect(t, slice.equal(decoded, input), "Decoded should match input")
}

@(test)
test_huffman_rfc_example_3 :: proc(t: ^testing.T) {
	// RFC 7541 Appendix C.4.3: "custom-key"
	tree, _ := hpack.huffman_decode_tree_build()
	defer hpack.huffman_decode_tree_destroy(tree)

	input := transmute([]byte)string("custom-key")
	encoded, _, ok := hpack.huffman_encode(input)
	defer delete(encoded)
	testing.expect(t, ok, "Should encode")

	// RFC specifies: 25a8 49e9 5ba9 7d7f
	// Wait, the comment says 2586... but that seems wrong. Let me check RFC 7541 Appendix C.4.3
	// Actually it's C.4.1, C.4.2, C.4.3 are the actual examples
	// Looking at actual RFC... "custom-key" encodes to: 25a8 49e9 5ba9 7d7f
	expected := []byte{0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f}

	if !slice.equal(encoded, expected) {
		// Debug
		fmt.printf("Got:      ")
		for b in encoded {
			fmt.printf("%02x ", b)
		}
		fmt.printf("\n")
		fmt.printf("Expected: ")
		for b in expected {
			fmt.printf("%02x ", b)
		}
		fmt.printf("\n")
	}

	testing.expect(t, slice.equal(encoded, expected), "Encoded should match RFC example")

	decoded, ok2 := hpack.huffman_decode(encoded, tree)
	defer delete(decoded)
	testing.expect(t, ok2, "Should decode")

	testing.expect(t, slice.equal(decoded, input), "Decoded should match input")
}

@(test)
test_huffman_compression_ratio :: proc(t: ^testing.T) {
	// Huffman encoding should compress typical HTTP header text
	tree, _ := hpack.huffman_decode_tree_build()
	defer hpack.huffman_decode_tree_destroy(tree)

	input := transmute([]byte)string("accept-encoding: gzip, deflate")
	encoded, _, ok := hpack.huffman_encode(input)
	defer delete(encoded)
	testing.expect(t, ok, "Should encode")

	// Verify compression occurred
	testing.expect(t, len(encoded) < len(input), "Should compress the text")

	// Verify roundtrip
	decoded, ok2 := hpack.huffman_decode(encoded, tree)
	defer delete(decoded)
	testing.expect(t, ok2, "Should decode")

	testing.expect(t, slice.equal(decoded, input), "Decoded should match input")
}

@(test)
test_huffman_decode_invalid_tree :: proc(t: ^testing.T) {
	input := []byte{0xff}
	output, ok := hpack.huffman_decode(input, nil)
	defer delete(output)

	testing.expect(t, !ok, "Should fail with nil tree")
}

@(test)
test_huffman_roundtrip_numbers :: proc(t: ^testing.T) {
	tree, _ := hpack.huffman_decode_tree_build()
	defer hpack.huffman_decode_tree_destroy(tree)

	input := transmute([]byte)string("0123456789")
	encoded, _, ok := hpack.huffman_encode(input)
	defer delete(encoded)
	testing.expect(t, ok, "Should encode")

	decoded, ok2 := hpack.huffman_decode(encoded, tree)
	defer delete(decoded)
	testing.expect(t, ok2, "Should decode")

	testing.expect(t, slice.equal(decoded, input), "Decoded should match input")
}

@(test)
test_huffman_roundtrip_symbols :: proc(t: ^testing.T) {
	tree, _ := hpack.huffman_decode_tree_build()
	defer hpack.huffman_decode_tree_destroy(tree)

	input := transmute([]byte)string("/:@?&=")
	encoded, _, ok := hpack.huffman_encode(input)
	defer delete(encoded)
	testing.expect(t, ok, "Should encode")

	decoded, ok2 := hpack.huffman_decode(encoded, tree)
	defer delete(decoded)
	testing.expect(t, ok2, "Should decode")

	testing.expect(t, slice.equal(decoded, input), "Decoded should match input")
}
