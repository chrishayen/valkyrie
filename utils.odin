package valkyrie

import "core:strconv"
import "core:strings"

// parse_ip_address parses an IPv4 address string (e.g., "0.0.0.0") into a 4-byte array.
// Returns the parsed address and success status.
parse_ip_address :: proc(ip_str: string) -> (addr: [4]u8, ok: bool) {
	parts := strings.split(ip_str, ".")
	if len(parts) != 4 {
		delete(parts)
		return {}, false
	}
	defer delete(parts)

	for i in 0 ..< 4 {
		octet, parse_ok := strconv.parse_int(parts[i])
		if !parse_ok || octet < 0 || octet > 255 {
			return {}, false
		}
		addr[i] = u8(octet)
	}

	return addr, true
}

