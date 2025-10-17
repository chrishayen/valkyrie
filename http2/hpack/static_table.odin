package hpack

// Static_Table_Entry represents a header name-value pair in the static table
Static_Table_Entry :: struct {
	name:  string,
	value: string,
}

// STATIC_TABLE contains all 61 predefined entries per RFC 7541 Appendix A.
// Indices are 1-based (index 0 is not used in HPACK).
// The table is organized with frequently used headers at lower indices.
STATIC_TABLE := [61]Static_Table_Entry{
	// Index 1-14: Special pseudo-headers and common headers
	{":authority", ""},
	{":method", "GET"},
	{":method", "POST"},
	{":path", "/"},
	{":path", "/index.html"},
	{":scheme", "http"},
	{":scheme", "https"},
	{":status", "200"},
	{":status", "204"},
	{":status", "206"},
	{":status", "304"},
	{":status", "400"},
	{":status", "404"},
	{":status", "500"},

	// Index 15-32: Common request/response headers
	{"accept-charset", ""},
	{"accept-encoding", "gzip, deflate"},
	{"accept-language", ""},
	{"accept-ranges", ""},
	{"accept", ""},
	{"access-control-allow-origin", ""},
	{"age", ""},
	{"allow", ""},
	{"authorization", ""},
	{"cache-control", ""},
	{"content-disposition", ""},
	{"content-encoding", ""},
	{"content-language", ""},
	{"content-length", ""},
	{"content-location", ""},
	{"content-range", ""},
	{"content-type", ""},
	{"cookie", ""},

	// Index 33-61: Additional headers
	{"date", ""},
	{"etag", ""},
	{"expect", ""},
	{"expires", ""},
	{"from", ""},
	{"host", ""},
	{"if-match", ""},
	{"if-modified-since", ""},
	{"if-none-match", ""},
	{"if-range", ""},
	{"if-unmodified-since", ""},
	{"last-modified", ""},
	{"link", ""},
	{"location", ""},
	{"max-forwards", ""},
	{"proxy-authenticate", ""},
	{"proxy-authorization", ""},
	{"range", ""},
	{"referer", ""},
	{"refresh", ""},
	{"retry-after", ""},
	{"server", ""},
	{"set-cookie", ""},
	{"strict-transport-security", ""},
	{"transfer-encoding", ""},
	{"user-agent", ""},
	{"vary", ""},
	{"via", ""},
	{"www-authenticate", ""},
}

// static_table_lookup returns the entry at the given index (1-based).
// Returns nil if index is out of range.
static_table_lookup :: proc(index: int) -> (entry: Static_Table_Entry, ok: bool) {
	if index < 1 || index > len(STATIC_TABLE) {
		return {}, false
	}
	return STATIC_TABLE[index - 1], true
}

// static_table_find_exact searches for an exact match of both name and value.
// Returns the 1-based index if found, 0 otherwise.
static_table_find_exact :: proc(name: string, value: string) -> int {
	for entry, i in STATIC_TABLE {
		if entry.name == name && entry.value == value {
			return i + 1
		}
	}
	return 0
}

// static_table_find_name searches for a name match (value may be empty).
// Returns the 1-based index of the first match, 0 otherwise.
static_table_find_name :: proc(name: string) -> int {
	for entry, i in STATIC_TABLE {
		if entry.name == name {
			return i + 1
		}
	}
	return 0
}
