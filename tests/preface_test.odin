package valkyrie_tests

import "core:testing"
import http2 "../http2"

@(test)
test_preface_valid :: proc(t: ^testing.T) {
	// Valid HTTP/2 connection preface
	data := []byte{
		0x50, 0x52, 0x49, 0x20, 0x2a, 0x20, 0x48, 0x54,
		0x54, 0x50, 0x2f, 0x32, 0x2e, 0x30, 0x0d, 0x0a,
		0x0d, 0x0a, 0x53, 0x4d, 0x0d, 0x0a, 0x0d, 0x0a,
	}

	valid, bytes_needed := http2.preface_validate(data)
	testing.expect(t, valid == true, "Should validate valid preface")
	testing.expect(t, bytes_needed == 0, "Should not need more bytes")
}

@(test)
test_preface_incomplete :: proc(t: ^testing.T) {
	// Incomplete preface (only first 10 bytes)
	data := []byte{
		0x50, 0x52, 0x49, 0x20, 0x2a, 0x20, 0x48, 0x54,
		0x54, 0x50,
	}

	valid, bytes_needed := http2.preface_validate(data)
	testing.expect(t, valid == false, "Should not validate incomplete preface")
	testing.expect(t, bytes_needed == 14, "Should need 14 more bytes")
}

@(test)
test_preface_invalid :: proc(t: ^testing.T) {
	// Invalid preface (wrong bytes)
	data := []byte{
		0x48, 0x54, 0x54, 0x50, 0x2f, 0x31, 0x2e, 0x31,
		0x20, 0x32, 0x30, 0x30, 0x20, 0x4f, 0x4b, 0x0d,
		0x0a, 0x0d, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00,
	}

	valid, bytes_needed := http2.preface_validate(data)
	testing.expect(t, valid == false, "Should not validate invalid preface")
	testing.expect(t, bytes_needed == 0, "Should not need more bytes (it's invalid)")
}

@(test)
test_preface_with_extra_data :: proc(t: ^testing.T) {
	// Valid preface followed by extra data
	data := []byte{
		0x50, 0x52, 0x49, 0x20, 0x2a, 0x20, 0x48, 0x54,
		0x54, 0x50, 0x2f, 0x32, 0x2e, 0x30, 0x0d, 0x0a,
		0x0d, 0x0a, 0x53, 0x4d, 0x0d, 0x0a, 0x0d, 0x0a,
		0x00, 0x00, 0x00, 0x00,  // Extra bytes (start of SETTINGS frame)
	}

	valid, bytes_needed := http2.preface_validate(data)
	testing.expect(t, valid == true, "Should validate preface even with extra data")
	testing.expect(t, bytes_needed == 0, "Should not need more bytes")
}

@(test)
test_preface_empty :: proc(t: ^testing.T) {
	data := []byte{}

	valid, bytes_needed := http2.preface_validate(data)
	testing.expect(t, valid == false, "Should not validate empty data")
	testing.expect(t, bytes_needed == 24, "Should need all 24 bytes")
}

@(test)
test_preface_length :: proc(t: ^testing.T) {
	length := http2.preface_bytes_consumed()
	testing.expect(t, length == 24, "Preface should be 24 bytes")
}
