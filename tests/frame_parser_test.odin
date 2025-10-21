package valkyrie_tests

import "core:testing"
import http "../http"

@(test)
test_parse_frame_header :: proc(t: ^testing.T) {
	// Valid frame header: 6 byte payload, DATA frame, no flags, stream 1
	data := []u8{
		0x00, 0x00, 0x06,  // Length: 6
		0x00,               // Type: DATA
		0x00,               // Flags: none
		0x00, 0x00, 0x00, 0x01,  // Stream ID: 1
	}

	header, consumed, err := http.parse_frame_header(data)
	testing.expect_value(t, err, http.Parse_Error.None)
	testing.expect_value(t, consumed, 9)
	testing.expect_value(t, header.length, u32(6))
	testing.expect_value(t, header.type, http.Frame_Type.DATA)
	testing.expect_value(t, header.flags, u8(0))
	testing.expect_value(t, http.frame_get_stream_id(&header), u32(1))
}

@(test)
test_parse_frame_header_incomplete :: proc(t: ^testing.T) {
	// Incomplete header (only 5 bytes)
	data := []u8{0x00, 0x00, 0x06, 0x00, 0x00}

	_, _, err := http.parse_frame_header(data)
	testing.expect_value(t, err, http.Parse_Error.Incomplete_Frame)
}

@(test)
test_parse_data_frame_simple :: proc(t: ^testing.T) {
	// Simple DATA frame without padding
	header := http.Frame_Header{
		length = 5,
		type = .DATA,
		flags = 0,
		stream_id = 1,
	}

	payload := []u8{0x48, 0x65, 0x6c, 0x6c, 0x6f}  // "Hello"

	frame, err := http.parse_data_frame(header, payload)
	testing.expect_value(t, err, http.Parse_Error.None)
	testing.expect_value(t, len(frame.data), 5)
	testing.expect_value(t, frame.data[0], u8(0x48))
}

@(test)
test_parse_data_frame_padded :: proc(t: ^testing.T) {
	// DATA frame with padding
	header := http.Frame_Header{
		length = 8,
		type = .DATA,
		flags = 0x08,  // PADDED flag
		stream_id = 1,
	}

	// Payload: pad_length(2) + "Hello"(5) + padding(2)
	payload := []u8{0x02, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00}

	frame, err := http.parse_data_frame(header, payload)
	testing.expect_value(t, err, http.Parse_Error.None)
	testing.expect_value(t, frame.pad_length, u8(2))
	testing.expect_value(t, len(frame.data), 5)
	testing.expect_value(t, len(frame.padding), 2)
}

@(test)
test_parse_headers_frame_simple :: proc(t: ^testing.T) {
	// Simple HEADERS frame without padding or priority
	header := http.Frame_Header{
		length = 4,
		type = .HEADERS,
		flags = 0x04,  // END_HEADERS
		stream_id = 1,
	}

	payload := []u8{0x01, 0x02, 0x03, 0x04}  // Header block fragment

	frame, err := http.parse_headers_frame(header, payload)
	testing.expect_value(t, err, http.Parse_Error.None)
	testing.expect_value(t, len(frame.header_block), 4)
	testing.expect_value(t, frame.header_block[0], u8(0x01))
}

@(test)
test_parse_headers_frame_with_priority :: proc(t: ^testing.T) {
	// HEADERS frame with priority
	header := http.Frame_Header{
		length = 9,  // 5 bytes priority + 4 bytes header block
		type = .HEADERS,
		flags = 0x20,  // PRIORITY flag
		stream_id = 3,
	}

	// Payload: stream_dep(exclusive bit set, stream 0) + weight(16) + header block
	payload := []u8{
		0x80, 0x00, 0x00, 0x00,  // Stream dependency: exclusive, stream 0
		0x10,                     // Weight: 16
		0x01, 0x02, 0x03, 0x04,  // Header block
	}

	frame, err := http.parse_headers_frame(header, payload)
	testing.expect_value(t, err, http.Parse_Error.None)
	testing.expect(t, frame.exclusive, "should be exclusive")
	testing.expect_value(t, frame.stream_dependency, u32(0))
	testing.expect_value(t, frame.weight, u8(16))
	testing.expect_value(t, len(frame.header_block), 4)
}

@(test)
test_parse_priority_frame :: proc(t: ^testing.T) {
	header := http.Frame_Header{
		length = 5,
		type = .PRIORITY,
		flags = 0,
		stream_id = 3,
	}

	// Stream dependency: non-exclusive, stream 1, weight 64
	payload := []u8{0x00, 0x00, 0x00, 0x01, 0x40}

	frame, err := http.parse_priority_frame(header, payload)
	testing.expect_value(t, err, http.Parse_Error.None)
	testing.expect(t, !frame.exclusive, "should not be exclusive")
	testing.expect_value(t, frame.stream_dependency, u32(1))
	testing.expect_value(t, frame.weight, u8(64))
}

@(test)
test_parse_rst_stream_frame :: proc(t: ^testing.T) {
	header := http.Frame_Header{
		length = 4,
		type = .RST_STREAM,
		flags = 0,
		stream_id = 1,
	}

	// Error code: PROTOCOL_ERROR (0x1)
	payload := []u8{0x00, 0x00, 0x00, 0x01}

	frame, err := http.parse_rst_stream_frame(header, payload)
	testing.expect_value(t, err, http.Parse_Error.None)
	testing.expect_value(t, frame.error_code, http.Error_Code.PROTOCOL_ERROR)
}

@(test)
test_parse_settings_frame :: proc(t: ^testing.T) {
	header := http.Frame_Header{
		length = 12,  // 2 settings * 6 bytes each
		type = .SETTINGS,
		flags = 0,
		stream_id = 0,
	}

	// Two settings: HEADER_TABLE_SIZE=8192, MAX_CONCURRENT_STREAMS=100
	payload := []u8{
		0x00, 0x01,  // ID: HEADER_TABLE_SIZE
		0x00, 0x00, 0x20, 0x00,  // Value: 8192
		0x00, 0x03,  // ID: MAX_CONCURRENT_STREAMS
		0x00, 0x00, 0x00, 0x64,  // Value: 100
	}

	frame, err := http.parse_settings_frame(header, payload)
	defer delete(frame.settings)

	testing.expect_value(t, err, http.Parse_Error.None)
	testing.expect_value(t, len(frame.settings), 2)
	testing.expect_value(t, frame.settings[0].id, http.Settings_ID.HEADER_TABLE_SIZE)
	testing.expect_value(t, frame.settings[0].value, u32(8192))
	testing.expect_value(t, frame.settings[1].id, http.Settings_ID.MAX_CONCURRENT_STREAMS)
	testing.expect_value(t, frame.settings[1].value, u32(100))
}

@(test)
test_parse_settings_frame_ack :: proc(t: ^testing.T) {
	header := http.Frame_Header{
		length = 0,
		type = .SETTINGS,
		flags = 0x01,  // ACK
		stream_id = 0,
	}

	payload := []u8{}

	frame, err := http.parse_settings_frame(header, payload)
	testing.expect_value(t, err, http.Parse_Error.None)
	testing.expect_value(t, len(frame.settings), 0)
}

@(test)
test_parse_ping_frame :: proc(t: ^testing.T) {
	header := http.Frame_Header{
		length = 8,
		type = .PING,
		flags = 0,
		stream_id = 0,
	}

	payload := []u8{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}

	frame, err := http.parse_ping_frame(header, payload)
	testing.expect_value(t, err, http.Parse_Error.None)
	testing.expect_value(t, frame.opaque_data[0], u8(0x01))
	testing.expect_value(t, frame.opaque_data[7], u8(0x08))
}

@(test)
test_parse_goaway_frame :: proc(t: ^testing.T) {
	header := http.Frame_Header{
		length = 8,
		type = .GOAWAY,
		flags = 0,
		stream_id = 0,
	}

	// Last stream ID: 7, Error code: NO_ERROR
	payload := []u8{
		0x00, 0x00, 0x00, 0x07,  // Last stream ID
		0x00, 0x00, 0x00, 0x00,  // Error code: NO_ERROR
	}

	frame, err := http.parse_goaway_frame(header, payload)
	testing.expect_value(t, err, http.Parse_Error.None)
	testing.expect_value(t, frame.last_stream_id, u32(7))
	testing.expect_value(t, frame.error_code, http.Error_Code.NO_ERROR)
}

@(test)
test_parse_window_update_frame :: proc(t: ^testing.T) {
	header := http.Frame_Header{
		length = 4,
		type = .WINDOW_UPDATE,
		flags = 0,
		stream_id = 1,
	}

	// Window size increment: 1024
	payload := []u8{0x00, 0x00, 0x04, 0x00}

	frame, err := http.parse_window_update_frame(header, payload)
	testing.expect_value(t, err, http.Parse_Error.None)
	testing.expect_value(t, frame.window_size_increment, u32(1024))
}

@(test)
test_parse_window_update_frame_zero :: proc(t: ^testing.T) {
	header := http.Frame_Header{
		length = 4,
		type = .WINDOW_UPDATE,
		flags = 0,
		stream_id = 1,
	}

	// Window size increment: 0 (invalid)
	payload := []u8{0x00, 0x00, 0x00, 0x00}

	_, err := http.parse_window_update_frame(header, payload)
	testing.expect_value(t, err, http.Parse_Error.Protocol_Error)
}

@(test)
test_parse_continuation_frame :: proc(t: ^testing.T) {
	header := http.Frame_Header{
		length = 5,
		type = .CONTINUATION,
		flags = 0,
		stream_id = 1,
	}

	payload := []u8{0x01, 0x02, 0x03, 0x04, 0x05}

	frame, err := http.parse_continuation_frame(header, payload)
	testing.expect_value(t, err, http.Parse_Error.None)
	testing.expect_value(t, len(frame.header_block), 5)
	testing.expect_value(t, frame.header_block[0], u8(0x01))
}

@(test)
test_frame_flags :: proc(t: ^testing.T) {
	header := http.Frame_Header{
		length = 0,
		type = .DATA,
		flags = 0,
		stream_id = 1,
	}

	// Initially no flags
	testing.expect(t, !http.frame_has_flag(&header, .END_STREAM), "should not have END_STREAM")

	// Set flag
	http.frame_set_flag(&header, .END_STREAM)
	testing.expect(t, http.frame_has_flag(&header, .END_STREAM), "should have END_STREAM")

	// Clear flag
	http.frame_clear_flag(&header, .END_STREAM)
	testing.expect(t, !http.frame_has_flag(&header, .END_STREAM), "should not have END_STREAM")
}
