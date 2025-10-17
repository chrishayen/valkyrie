package http2

// preface_validate checks if the given bytes match the HTTP/2 connection preface
preface_validate :: proc(data: []byte) -> (valid: bool, bytes_needed: int) {
	if len(data) < CONNECTION_PREFACE_LENGTH {
		// Not enough data yet, need more bytes
		return false, CONNECTION_PREFACE_LENGTH - len(data)
	}

	// Check if the preface matches
	// CONNECTION_PREFACE is defined in constants.odin as a string
	// "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
	expected := [24]byte{
		0x50, 0x52, 0x49, 0x20, 0x2a, 0x20, 0x48, 0x54,
		0x54, 0x50, 0x2f, 0x32, 0x2e, 0x30, 0x0d, 0x0a,
		0x0d, 0x0a, 0x53, 0x4d, 0x0d, 0x0a, 0x0d, 0x0a,
	}

	for i in 0..<CONNECTION_PREFACE_LENGTH {
		if data[i] != expected[i] {
			return false, 0
		}
	}

	return true, 0
}

// preface_bytes_consumed returns how many bytes were consumed if preface is valid
preface_bytes_consumed :: proc() -> int {
	return CONNECTION_PREFACE_LENGTH
}
