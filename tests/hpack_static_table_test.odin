package valkyrie_tests

import "core:testing"
import hpack "../http2/hpack"

@(test)
test_static_table_size :: proc(t: ^testing.T) {
	testing.expect(t, len(hpack.STATIC_TABLE) == 61, "Static table should have 61 entries")
}

@(test)
test_static_table_lookup_valid :: proc(t: ^testing.T) {
	// Test first entry (index 1)
	entry, ok := hpack.static_table_lookup(1)
	testing.expect(t, ok, "Should find index 1")
	testing.expect(t, entry.name == ":authority", "Index 1 should be :authority")
	testing.expect(t, entry.value == "", "Index 1 should have empty value")

	// Test :method GET (index 2)
	entry, ok = hpack.static_table_lookup(2)
	testing.expect(t, ok, "Should find index 2")
	testing.expect(t, entry.name == ":method", "Index 2 should be :method")
	testing.expect(t, entry.value == "GET", "Index 2 should have value GET")

	// Test :status 200 (index 8)
	entry, ok = hpack.static_table_lookup(8)
	testing.expect(t, ok, "Should find index 8")
	testing.expect(t, entry.name == ":status", "Index 8 should be :status")
	testing.expect(t, entry.value == "200", "Index 8 should have value 200")

	// Test last entry (index 61)
	entry, ok = hpack.static_table_lookup(61)
	testing.expect(t, ok, "Should find index 61")
	testing.expect(t, entry.name == "www-authenticate", "Index 61 should be www-authenticate")
	testing.expect(t, entry.value == "", "Index 61 should have empty value")
}

@(test)
test_static_table_lookup_invalid :: proc(t: ^testing.T) {
	// Test index 0 (invalid)
	_, ok := hpack.static_table_lookup(0)
	testing.expect(t, !ok, "Index 0 should be invalid")

	// Test index 62 (out of range)
	_, ok = hpack.static_table_lookup(62)
	testing.expect(t, !ok, "Index 62 should be invalid")

	// Test negative index
	_, ok = hpack.static_table_lookup(-1)
	testing.expect(t, !ok, "Negative index should be invalid")
}

@(test)
test_static_table_find_exact_match :: proc(t: ^testing.T) {
	// Test exact match with value
	index := hpack.static_table_find_exact(":method", "GET")
	testing.expect(t, index == 2, "Should find :method GET at index 2")

	index = hpack.static_table_find_exact(":method", "POST")
	testing.expect(t, index == 3, "Should find :method POST at index 3")

	index = hpack.static_table_find_exact(":status", "200")
	testing.expect(t, index == 8, "Should find :status 200 at index 8")

	// Test exact match with empty value
	index = hpack.static_table_find_exact(":authority", "")
	testing.expect(t, index == 1, "Should find :authority with empty value at index 1")
}

@(test)
test_static_table_find_exact_no_match :: proc(t: ^testing.T) {
	// Test name exists but value doesn't match
	index := hpack.static_table_find_exact(":method", "DELETE")
	testing.expect(t, index == 0, "Should not find :method DELETE")

	// Test name doesn't exist
	index = hpack.static_table_find_exact("x-custom-header", "value")
	testing.expect(t, index == 0, "Should not find custom header")

	// Test empty name
	index = hpack.static_table_find_exact("", "")
	testing.expect(t, index == 0, "Should not find empty name")
}

@(test)
test_static_table_find_name :: proc(t: ^testing.T) {
	// Test finding by name only
	index := hpack.static_table_find_name(":authority")
	testing.expect(t, index == 1, "Should find :authority at index 1")

	index = hpack.static_table_find_name(":method")
	testing.expect(t, index == 2, "Should find first :method at index 2")

	index = hpack.static_table_find_name("content-type")
	testing.expect(t, index == 31, "Should find content-type at index 31")

	index = hpack.static_table_find_name("www-authenticate")
	testing.expect(t, index == 61, "Should find www-authenticate at index 61")
}

@(test)
test_static_table_find_name_no_match :: proc(t: ^testing.T) {
	index := hpack.static_table_find_name("x-custom-header")
	testing.expect(t, index == 0, "Should not find custom header")

	index = hpack.static_table_find_name("")
	testing.expect(t, index == 0, "Should not find empty name")
}

@(test)
test_static_table_pseudo_headers :: proc(t: ^testing.T) {
	// Verify all pseudo-headers (starting with ':') are present
	pseudo_headers := []string{":authority", ":method", ":path", ":scheme", ":status"}

	for header in pseudo_headers {
		index := hpack.static_table_find_name(header)
		testing.expect(t, index > 0, "Should find pseudo-header")
	}
}

@(test)
test_static_table_common_headers :: proc(t: ^testing.T) {
	// Verify common HTTP headers are present
	common_headers := []string{
		"content-type",
		"content-length",
		"cache-control",
		"accept",
		"user-agent",
		"cookie",
		"set-cookie",
	}

	for header in common_headers {
		index := hpack.static_table_find_name(header)
		testing.expect(t, index > 0, "Should find common header")
	}
}

@(test)
test_static_table_accept_encoding :: proc(t: ^testing.T) {
	// RFC 7541 Appendix A specifies accept-encoding with value "gzip, deflate"
	entry, ok := hpack.static_table_lookup(16)
	testing.expect(t, ok, "Should find index 16")
	testing.expect(t, entry.name == "accept-encoding", "Should be accept-encoding")
	testing.expect(t, entry.value == "gzip, deflate", "Should have value 'gzip, deflate'")

	// Test exact match
	index := hpack.static_table_find_exact("accept-encoding", "gzip, deflate")
	testing.expect(t, index == 16, "Should find exact match at index 16")
}
