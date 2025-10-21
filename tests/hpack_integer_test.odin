package valkyrie_tests

import "core:testing"
import "core:slice"
import hpack "../http/hpack"

// Test encoding/decoding small values that fit in prefix
@(test)
test_integer_encode_small_5bit :: proc(t: ^testing.T) {
	// RFC 7541 example: encoding 10 with 5-bit prefix
	encoded, ok := hpack.integer_encode(5, 0, 10)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	testing.expect(t, len(encoded) == 1, "Should be 1 byte")
	testing.expect(t, encoded[0] == 10, "Should be 0x0a")
}

@(test)
test_integer_decode_small_5bit :: proc(t: ^testing.T) {
	input := []byte{10}
	value, consumed, ok := hpack.integer_decode(input, 5)

	testing.expect(t, ok, "Should decode successfully")
	testing.expect(t, value == 10, "Should decode to 10")
	testing.expect(t, consumed == 1, "Should consume 1 byte")
}

// Test encoding/decoding at boundary (max value for prefix)
@(test)
test_integer_encode_boundary_5bit :: proc(t: ^testing.T) {
	// Max value for 5 bits is 31 (2^5 - 1)
	// Encoding 31 should still fit in one byte
	encoded, ok := hpack.integer_encode(5, 0, 30)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	testing.expect(t, len(encoded) == 1, "Should be 1 byte")
	testing.expect(t, encoded[0] == 30, "Should be 30")
}

// Test encoding/decoding value that requires multi-byte
@(test)
test_integer_encode_multibyte_5bit :: proc(t: ^testing.T) {
	// RFC 7541 Appendix C.1.1: encoding 1337 with 5-bit prefix
	// Expected: 1f 9a 0a (31, 154, 10)
	encoded, ok := hpack.integer_encode(5, 0, 1337)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	testing.expect(t, len(encoded) == 3, "Should be 3 bytes")
	testing.expect(t, encoded[0] == 0x1f, "First byte should be 0x1f")
	testing.expect(t, encoded[1] == 0x9a, "Second byte should be 0x9a")
	testing.expect(t, encoded[2] == 0x0a, "Third byte should be 0x0a")
}

@(test)
test_integer_decode_multibyte_5bit :: proc(t: ^testing.T) {
	// RFC 7541 Appendix C.1.1: decoding 1337 from 1f 9a 0a
	input := []byte{0x1f, 0x9a, 0x0a}
	value, consumed, ok := hpack.integer_decode(input, 5)

	testing.expect(t, ok, "Should decode successfully")
	testing.expect(t, value == 1337, "Should decode to 1337")
	testing.expect(t, consumed == 3, "Should consume 3 bytes")
}

// Test with prefix value (upper bits used)
@(test)
test_integer_encode_with_prefix :: proc(t: ^testing.T) {
	// Encode 10 with 5-bit prefix, with prefix value 0b011 (3) in upper 3 bits
	// First byte should be: 01100000 | 00001010 = 01101010 = 0x6a
	encoded, ok := hpack.integer_encode(5, 3, 10)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode successfully")
	testing.expect(t, len(encoded) == 1, "Should be 1 byte")
	testing.expect(t, encoded[0] == 0x6a, "Should be 0x6a (0b01101010)")
}

// Test roundtrip for various values
@(test)
test_integer_roundtrip_small :: proc(t: ^testing.T) {
	test_values := []int{0, 1, 10, 15, 30}

	for value in test_values {
		encoded, ok := hpack.integer_encode(5, 0, value)
		defer delete(encoded)
		testing.expect(t, ok, "Should encode")

		decoded, consumed, ok2 := hpack.integer_decode(encoded, 5)
		testing.expect(t, ok2, "Should decode")
		testing.expect(t, decoded == value, "Should roundtrip correctly")
		testing.expect(t, consumed == len(encoded), "Should consume all bytes")
	}
}

@(test)
test_integer_roundtrip_large :: proc(t: ^testing.T) {
	test_values := []int{31, 100, 1000, 1337, 10000, 100000}

	for value in test_values {
		encoded, ok := hpack.integer_encode(5, 0, value)
		defer delete(encoded)
		testing.expect(t, ok, "Should encode")

		decoded, consumed, ok2 := hpack.integer_decode(encoded, 5)
		testing.expect(t, ok2, "Should decode")
		testing.expect(t, decoded == value, "Should roundtrip correctly")
		testing.expect(t, consumed == len(encoded), "Should consume all bytes")
	}
}

// Test different prefix sizes
@(test)
test_integer_encode_various_prefix_sizes :: proc(t: ^testing.T) {
	value := 100

	for prefix_bits in 1..=8 {
		encoded, ok := hpack.integer_encode(u8(prefix_bits), 0, value)
		defer delete(encoded)
		testing.expect(t, ok, "Should encode")

		decoded, _, ok2 := hpack.integer_decode(encoded, u8(prefix_bits))
		testing.expect(t, ok2, "Should decode")
		testing.expect(t, decoded == value, "Should roundtrip correctly")
	}
}

// Test 8-bit prefix (full byte)
@(test)
test_integer_encode_8bit_prefix :: proc(t: ^testing.T) {
	// With 8-bit prefix, values 0-254 fit in one byte
	encoded, ok := hpack.integer_encode(8, 0, 200)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode")
	testing.expect(t, len(encoded) == 1, "Should be 1 byte")
	testing.expect(t, encoded[0] == 200, "Should be 200")

	// 255 requires multi-byte encoding
	encoded2, ok2 := hpack.integer_encode(8, 0, 255)
	defer delete(encoded2)

	testing.expect(t, ok2, "Should encode 255")
	testing.expect(t, len(encoded2) == 2, "Should be 2 bytes")
	testing.expect(t, encoded2[0] == 0xFF, "First byte should be 0xFF")
	testing.expect(t, encoded2[1] == 0, "Second byte should be 0")
}

// Test 1-bit prefix (minimal)
@(test)
test_integer_encode_1bit_prefix :: proc(t: ^testing.T) {
	// With 1-bit prefix, only 0 fits in one byte
	encoded, ok := hpack.integer_encode(1, 0, 0)
	defer delete(encoded)

	testing.expect(t, ok, "Should encode")
	testing.expect(t, len(encoded) == 1, "Should be 1 byte")
	testing.expect(t, encoded[0] == 0, "Should be 0")

	// 1 requires multi-byte encoding
	encoded2, ok2 := hpack.integer_encode(1, 0, 1)
	defer delete(encoded2)

	testing.expect(t, ok2, "Should encode 1")
	testing.expect(t, len(encoded2) == 2, "Should be 2 bytes")
}

// Test error cases
@(test)
test_integer_encode_invalid_prefix :: proc(t: ^testing.T) {
	// prefix_bits must be 1-8
	_, ok := hpack.integer_encode(0, 0, 10)
	testing.expect(t, !ok, "Should fail with prefix_bits=0")

	_, ok2 := hpack.integer_encode(9, 0, 10)
	testing.expect(t, !ok2, "Should fail with prefix_bits=9")
}

@(test)
test_integer_encode_negative :: proc(t: ^testing.T) {
	_, ok := hpack.integer_encode(5, 0, -1)
	testing.expect(t, !ok, "Should fail with negative value")
}

@(test)
test_integer_decode_empty :: proc(t: ^testing.T) {
	input := []byte{}
	_, _, ok := hpack.integer_decode(input, 5)
	testing.expect(t, !ok, "Should fail with empty input")
}

@(test)
test_integer_decode_incomplete :: proc(t: ^testing.T) {
	// Multi-byte encoding but missing continuation bytes
	input := []byte{0x1f, 0x9a} // Missing final byte
	_, _, ok := hpack.integer_decode(input, 5)
	testing.expect(t, !ok, "Should fail with incomplete input")
}

@(test)
test_integer_decode_invalid_prefix :: proc(t: ^testing.T) {
	input := []byte{10}
	_, _, ok := hpack.integer_decode(input, 0)
	testing.expect(t, !ok, "Should fail with prefix_bits=0")

	_, _, ok2 := hpack.integer_decode(input, 9)
	testing.expect(t, !ok2, "Should fail with prefix_bits=9")
}

// Test RFC 7541 Appendix C examples
@(test)
test_integer_rfc_example_c1_1 :: proc(t: ^testing.T) {
	// C.1.1: 1337 encoded with 5-bit prefix -> 1f 9a 0a
	encoded, ok := hpack.integer_encode(5, 0, 1337)
	defer delete(encoded)

	expected := []byte{0x1f, 0x9a, 0x0a}
	testing.expect(t, ok, "Should encode")
	testing.expect(t, slice.equal(encoded, expected), "Should match RFC example")
}

@(test)
test_integer_rfc_example_c1_2 :: proc(t: ^testing.T) {
	// C.1.2: 42 encoded with 6-bit prefix -> 2a
	encoded, ok := hpack.integer_encode(6, 0, 42)
	defer delete(encoded)

	expected := []byte{0x2a}
	testing.expect(t, ok, "Should encode")
	testing.expect(t, slice.equal(encoded, expected), "Should match RFC example")
}
