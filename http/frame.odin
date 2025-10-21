package http

// Frame_Header represents the common 9-byte header for all HTTP/2 frames
// RFC 9113 Section 4.1
Frame_Header :: struct {
	length:    u32,        // 24-bit length (stored as u32, only lower 24 bits used)
	type:      Frame_Type,
	flags:     u8,         // Raw flags byte
	stream_id: u32,        // 31-bit stream identifier (bit 0 is reserved)
}

// DATA frame (RFC 9113 Section 6.1)
// Conveys arbitrary, variable-length sequences of octets associated with a stream
Data_Frame :: struct {
	header:      Frame_Header,
	pad_length:  u8,        // Present only if PADDED flag is set
	data:        []u8,      // Application data
	padding:     []u8,      // Padding octets (if PADDED)
}

// HEADERS frame (RFC 9113 Section 6.2)
// Opens a stream and carries a header block fragment
Headers_Frame :: struct {
	header:           Frame_Header,
	pad_length:       u8,        // Present only if PADDED flag is set
	stream_dependency: u32,       // Present only if PRIORITY flag is set (31 bits)
	exclusive:        bool,       // Exclusive flag (from bit 0 of stream_dependency)
	weight:           u8,         // Present only if PRIORITY flag is set
	header_block:     []u8,       // Header block fragment
	padding:          []u8,       // Padding octets (if PADDED)
}

// PRIORITY frame (RFC 9113 Section 6.3)
// Specifies the sender-advised priority of a stream
Priority_Frame :: struct {
	header:            Frame_Header,
	stream_dependency: u32,       // 31-bit stream identifier
	exclusive:         bool,       // Exclusive flag
	weight:            u8,         // Stream weight (1-256)
}

// RST_STREAM frame (RFC 9113 Section 6.4)
// Allows for immediate termination of a stream
Rst_Stream_Frame :: struct {
	header:     Frame_Header,
	error_code: Error_Code,
}

// SETTINGS frame (RFC 9113 Section 6.5)
// Conveys configuration parameters
Settings_Frame :: struct {
	header:   Frame_Header,
	settings: []Setting,  // Array of settings parameters
}

Setting :: struct {
	id:    Settings_ID,
	value: u32,
}

// PUSH_PROMISE frame (RFC 9113 Section 6.6)
// Notifies the peer that the sender intends to initiate a stream
Push_Promise_Frame :: struct {
	header:             Frame_Header,
	pad_length:         u8,        // Present only if PADDED flag is set
	promised_stream_id: u32,       // 31-bit promised stream ID
	header_block:       []u8,      // Header block fragment
	padding:            []u8,      // Padding octets (if PADDED)
}

// PING frame (RFC 9113 Section 6.7)
// Mechanism for measuring a minimal round-trip time
Ping_Frame :: struct {
	header:       Frame_Header,
	opaque_data:  [8]u8,   // 8 octets of opaque data
}

// GOAWAY frame (RFC 9113 Section 6.8)
// Initiates shutdown of a connection or signals serious error conditions
Goaway_Frame :: struct {
	header:             Frame_Header,
	last_stream_id:     u32,       // 31-bit last stream ID
	error_code:         Error_Code,
	additional_data:    []u8,      // Optional debug data
}

// WINDOW_UPDATE frame (RFC 9113 Section 6.9)
// Implements flow control
Window_Update_Frame :: struct {
	header:              Frame_Header,
	window_size_increment: u32,    // 31-bit window size increment
}

// CONTINUATION frame (RFC 9113 Section 6.10)
// Continues a sequence of header block fragments
Continuation_Frame :: struct {
	header:        Frame_Header,
	header_block:  []u8,       // Header block fragment
}

// Frame is a union of all possible frame types
Frame :: union {
	Data_Frame,
	Headers_Frame,
	Priority_Frame,
	Rst_Stream_Frame,
	Settings_Frame,
	Push_Promise_Frame,
	Ping_Frame,
	Goaway_Frame,
	Window_Update_Frame,
	Continuation_Frame,
}

// frame_has_flag checks if a specific flag is set in the frame header
frame_has_flag :: proc(header: ^Frame_Header, flag: Frame_Flag) -> bool {
	flag_mask := u8(1 << uint(flag))
	return (header.flags & flag_mask) != 0
}

// frame_set_flag sets a specific flag in the frame header
frame_set_flag :: proc(header: ^Frame_Header, flag: Frame_Flag) {
	flag_mask := u8(1 << uint(flag))
	header.flags |= flag_mask
}

// frame_clear_flag clears a specific flag in the frame header
frame_clear_flag :: proc(header: ^Frame_Header, flag: Frame_Flag) {
	flag_mask := u8(1 << uint(flag))
	header.flags &= ~flag_mask
}

// frame_get_stream_id extracts the stream ID (clearing the reserved bit)
frame_get_stream_id :: proc(header: ^Frame_Header) -> u32 {
	return header.stream_id & STREAM_ID_MASK
}

// frame_set_stream_id sets the stream ID (preserving the reserved bit)
frame_set_stream_id :: proc(header: ^Frame_Header, stream_id: u32) {
	header.stream_id = stream_id & STREAM_ID_MASK
}
