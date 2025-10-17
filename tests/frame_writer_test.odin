package http_tests

import "core:testing"
import http2 "../http2"

@(test)
test_write_frame_header :: proc(t: ^testing.T) {
	header := http2.Frame_Header{
		length = 6,
		type = .DATA,
		flags = 0x01,
		stream_id = 1,
	}

	buf := make([]u8, 100)
	defer delete(buf)

	written, err := http2.write_frame_header(buf, &header)
	testing.expect_value(t, err, http2.Write_Error.None)
	testing.expect_value(t, written, 9)

	// Verify bytes
	testing.expect_value(t, buf[0], u8(0x00))  // Length high
	testing.expect_value(t, buf[1], u8(0x00))  // Length mid
	testing.expect_value(t, buf[2], u8(0x06))  // Length low
	testing.expect_value(t, buf[3], u8(0x00))  // Type: DATA
	testing.expect_value(t, buf[4], u8(0x01))  // Flags
	testing.expect_value(t, buf[8], u8(0x01))  // Stream ID low
}

@(test)
test_write_and_parse_data_frame :: proc(t: ^testing.T) {
	// Create a DATA frame
	original := http2.Data_Frame{
		header = http2.Frame_Header{
			length = 5,
			type = .DATA,
			flags = 0x01,  // END_STREAM
			stream_id = 1,
		},
		data = []u8{0x48, 0x65, 0x6c, 0x6c, 0x6f},  // "Hello"
	}

	// Write to buffer
	buf := make([]u8, 100)
	defer delete(buf)

	written, write_err := http2.write_data_frame(buf, &original)
	testing.expect_value(t, write_err, http2.Write_Error.None)
	testing.expect_value(t, written, 14)  // 9 header + 5 data

	// Parse it back
	header, _, parse_header_err := http2.parse_frame_header(buf)
	testing.expect_value(t, parse_header_err, http2.Parse_Error.None)

	parsed, parse_err := http2.parse_data_frame(header, buf[9:])
	testing.expect_value(t, parse_err, http2.Parse_Error.None)

	// Verify round-trip
	testing.expect_value(t, parsed.header.length, original.header.length)
	testing.expect_value(t, len(parsed.data), len(original.data))
	for i in 0..<len(original.data) {
		testing.expect_value(t, parsed.data[i], original.data[i])
	}
}

@(test)
test_write_and_parse_headers_frame :: proc(t: ^testing.T) {
	// Create a HEADERS frame with priority
	original := http2.Headers_Frame{
		header = http2.Frame_Header{
			length = 9,
			type = .HEADERS,
			flags = 0x24,  // END_HEADERS | PRIORITY
			stream_id = 3,
		},
		exclusive = true,
		stream_dependency = 0,
		weight = 16,
		header_block = []u8{0x01, 0x02, 0x03, 0x04},
	}

	buf := make([]u8, 100)
	defer delete(buf)

	written, write_err := http2.write_headers_frame(buf, &original)
	testing.expect_value(t, write_err, http2.Write_Error.None)

	// Parse it back
	header, _, _ := http2.parse_frame_header(buf)
	parsed, parse_err := http2.parse_headers_frame(header, buf[9:])
	testing.expect_value(t, parse_err, http2.Parse_Error.None)

	// Verify round-trip
	testing.expect(t, parsed.exclusive == original.exclusive)
	testing.expect_value(t, parsed.stream_dependency, original.stream_dependency)
	testing.expect_value(t, parsed.weight, original.weight)
	testing.expect_value(t, len(parsed.header_block), len(original.header_block))
}

@(test)
test_write_and_parse_priority_frame :: proc(t: ^testing.T) {
	original := http2.Priority_Frame{
		header = http2.Frame_Header{
			length = 5,
			type = .PRIORITY,
			flags = 0,
			stream_id = 3,
		},
		exclusive = false,
		stream_dependency = 1,
		weight = 64,
	}

	buf := make([]u8, 100)
	defer delete(buf)

	written, write_err := http2.write_priority_frame(buf, &original)
	testing.expect_value(t, write_err, http2.Write_Error.None)
	testing.expect_value(t, written, 14)  // 9 header + 5 payload

	// Parse it back
	header, _, _ := http2.parse_frame_header(buf)
	parsed, parse_err := http2.parse_priority_frame(header, buf[9:])
	testing.expect_value(t, parse_err, http2.Parse_Error.None)

	// Verify round-trip
	testing.expect(t, parsed.exclusive == original.exclusive)
	testing.expect_value(t, parsed.stream_dependency, original.stream_dependency)
	testing.expect_value(t, parsed.weight, original.weight)
}

@(test)
test_write_and_parse_rst_stream_frame :: proc(t: ^testing.T) {
	original := http2.Rst_Stream_Frame{
		header = http2.Frame_Header{
			length = 4,
			type = .RST_STREAM,
			flags = 0,
			stream_id = 1,
		},
		error_code = .PROTOCOL_ERROR,
	}

	buf := make([]u8, 100)
	defer delete(buf)

	written, write_err := http2.write_rst_stream_frame(buf, &original)
	testing.expect_value(t, write_err, http2.Write_Error.None)
	testing.expect_value(t, written, 13)  // 9 header + 4 error code

	// Parse it back
	header, _, _ := http2.parse_frame_header(buf)
	parsed, parse_err := http2.parse_rst_stream_frame(header, buf[9:])
	testing.expect_value(t, parse_err, http2.Parse_Error.None)

	// Verify round-trip
	testing.expect_value(t, parsed.error_code, original.error_code)
}

@(test)
test_write_and_parse_settings_frame :: proc(t: ^testing.T) {
	original := http2.Settings_Frame{
		header = http2.Frame_Header{
			length = 12,
			type = .SETTINGS,
			flags = 0,
			stream_id = 0,
		},
		settings = []http2.Setting{
			{id = .HEADER_TABLE_SIZE, value = 8192},
			{id = .MAX_CONCURRENT_STREAMS, value = 100},
		},
	}

	buf := make([]u8, 100)
	defer delete(buf)

	written, write_err := http2.write_settings_frame(buf, &original)
	testing.expect_value(t, write_err, http2.Write_Error.None)
	testing.expect_value(t, written, 21)  // 9 header + 12 settings

	// Parse it back
	header, _, _ := http2.parse_frame_header(buf)
	parsed, parse_err := http2.parse_settings_frame(header, buf[9:])
	defer delete(parsed.settings)
	testing.expect_value(t, parse_err, http2.Parse_Error.None)

	// Verify round-trip
	testing.expect_value(t, len(parsed.settings), len(original.settings))
	for i in 0..<len(original.settings) {
		testing.expect_value(t, parsed.settings[i].id, original.settings[i].id)
		testing.expect_value(t, parsed.settings[i].value, original.settings[i].value)
	}
}

@(test)
test_write_and_parse_ping_frame :: proc(t: ^testing.T) {
	original := http2.Ping_Frame{
		header = http2.Frame_Header{
			length = 8,
			type = .PING,
			flags = 0,
			stream_id = 0,
		},
		opaque_data = [8]u8{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08},
	}

	buf := make([]u8, 100)
	defer delete(buf)

	written, write_err := http2.write_ping_frame(buf, &original)
	testing.expect_value(t, write_err, http2.Write_Error.None)
	testing.expect_value(t, written, 17)  // 9 header + 8 data

	// Parse it back
	header, _, _ := http2.parse_frame_header(buf)
	parsed, parse_err := http2.parse_ping_frame(header, buf[9:])
	testing.expect_value(t, parse_err, http2.Parse_Error.None)

	// Verify round-trip
	for i in 0..<8 {
		testing.expect_value(t, parsed.opaque_data[i], original.opaque_data[i])
	}
}

@(test)
test_write_and_parse_goaway_frame :: proc(t: ^testing.T) {
	original := http2.Goaway_Frame{
		header = http2.Frame_Header{
			length = 8,
			type = .GOAWAY,
			flags = 0,
			stream_id = 0,
		},
		last_stream_id = 7,
		error_code = .NO_ERROR,
	}

	buf := make([]u8, 100)
	defer delete(buf)

	written, write_err := http2.write_goaway_frame(buf, &original)
	testing.expect_value(t, write_err, http2.Write_Error.None)
	testing.expect_value(t, written, 17)  // 9 header + 8 (last_stream + error)

	// Parse it back
	header, _, _ := http2.parse_frame_header(buf)
	parsed, parse_err := http2.parse_goaway_frame(header, buf[9:])
	testing.expect_value(t, parse_err, http2.Parse_Error.None)

	// Verify round-trip
	testing.expect_value(t, parsed.last_stream_id, original.last_stream_id)
	testing.expect_value(t, parsed.error_code, original.error_code)
}

@(test)
test_write_and_parse_window_update_frame :: proc(t: ^testing.T) {
	original := http2.Window_Update_Frame{
		header = http2.Frame_Header{
			length = 4,
			type = .WINDOW_UPDATE,
			flags = 0,
			stream_id = 1,
		},
		window_size_increment = 1024,
	}

	buf := make([]u8, 100)
	defer delete(buf)

	written, write_err := http2.write_window_update_frame(buf, &original)
	testing.expect_value(t, write_err, http2.Write_Error.None)
	testing.expect_value(t, written, 13)  // 9 header + 4 increment

	// Parse it back
	header, _, _ := http2.parse_frame_header(buf)
	parsed, parse_err := http2.parse_window_update_frame(header, buf[9:])
	testing.expect_value(t, parse_err, http2.Parse_Error.None)

	// Verify round-trip
	testing.expect_value(t, parsed.window_size_increment, original.window_size_increment)
}

@(test)
test_write_and_parse_continuation_frame :: proc(t: ^testing.T) {
	original := http2.Continuation_Frame{
		header = http2.Frame_Header{
			length = 5,
			type = .CONTINUATION,
			flags = 0x04,  // END_HEADERS
			stream_id = 1,
		},
		header_block = []u8{0x01, 0x02, 0x03, 0x04, 0x05},
	}

	buf := make([]u8, 100)
	defer delete(buf)

	written, write_err := http2.write_continuation_frame(buf, &original)
	testing.expect_value(t, write_err, http2.Write_Error.None)
	testing.expect_value(t, written, 14)  // 9 header + 5 data

	// Parse it back
	header, _, _ := http2.parse_frame_header(buf)
	parsed, parse_err := http2.parse_continuation_frame(header, buf[9:])
	testing.expect_value(t, parse_err, http2.Parse_Error.None)

	// Verify round-trip
	testing.expect_value(t, len(parsed.header_block), len(original.header_block))
	for i in 0..<len(original.header_block) {
		testing.expect_value(t, parsed.header_block[i], original.header_block[i])
	}
}

@(test)
test_write_buffer_too_small :: proc(t: ^testing.T) {
	frame := http2.Data_Frame{
		header = http2.Frame_Header{
			length = 5,
			type = .DATA,
			flags = 0,
			stream_id = 1,
		},
		data = []u8{0x48, 0x65, 0x6c, 0x6c, 0x6f},
	}

	// Buffer too small
	small_buf := make([]u8, 5)
	defer delete(small_buf)

	_, err := http2.write_data_frame(small_buf, &frame)
	testing.expect_value(t, err, http2.Write_Error.Buffer_Too_Small)
}
