package http2

import "core:mem"

// Parse_Error represents errors that can occur during frame parsing
Parse_Error :: enum {
	None,
	Incomplete_Frame,
	Invalid_Frame_Size,
	Invalid_Stream_ID,
	Invalid_Setting,
	Invalid_Window_Size,
	Protocol_Error,
	Frame_Size_Error,
}

// parse_frame_header parses the 9-byte frame header from a byte buffer
// Returns the parsed header and number of bytes consumed
parse_frame_header :: proc(data: []u8) -> (header: Frame_Header, consumed: int, err: Parse_Error) {
	if len(data) < FRAME_HEADER_SIZE {
		return {}, 0, .Incomplete_Frame
	}

	// Parse 24-bit length (3 bytes, big-endian)
	length := u32(data[0]) << 16 | u32(data[1]) << 8 | u32(data[2])

	// Parse type (1 byte)
	frame_type := Frame_Type(data[3])

	// Parse flags (1 byte)
	flags := data[4]

	// Parse stream ID (4 bytes, big-endian, bit 0 is reserved)
	stream_id := u32(data[5]) << 24 | u32(data[6]) << 16 | u32(data[7]) << 8 | u32(data[8])

	header = Frame_Header{
		length = length,
		type = frame_type,
		flags = flags,
		stream_id = stream_id,
	}

	return header, FRAME_HEADER_SIZE, .None
}

// parse_data_frame parses a DATA frame
parse_data_frame :: proc(header: Frame_Header, data: []u8) -> (frame: Data_Frame, err: Parse_Error) {
	if len(data) < int(header.length) {
		return {}, .Incomplete_Frame
	}

	frame.header = header
	offset := 0

	// Check for PADDED flag
	if frame_has_flag(&frame.header, .PADDED) {
		if len(data) < 1 {
			return {}, .Incomplete_Frame
		}
		frame.pad_length = data[0]
		offset += 1

		// Validate padding
		if int(frame.pad_length) >= int(header.length) {
			return {}, .Protocol_Error
		}
	}

	// Calculate data length
	data_len := int(header.length) - offset - int(frame.pad_length)
	if data_len < 0 {
		return {}, .Protocol_Error
	}

	// Extract data
	if data_len > 0 {
		frame.data = data[offset:offset + data_len]
	}

	// Extract padding (if any)
	if frame.pad_length > 0 {
		frame.padding = data[offset + data_len:offset + data_len + int(frame.pad_length)]
	}

	return frame, .None
}

// parse_headers_frame parses a HEADERS frame
parse_headers_frame :: proc(header: Frame_Header, data: []u8) -> (frame: Headers_Frame, err: Parse_Error) {
	if len(data) < int(header.length) {
		return {}, .Incomplete_Frame
	}

	frame.header = header
	offset := 0

	// Check for PADDED flag
	if frame_has_flag(&frame.header, .PADDED) {
		if len(data) < 1 {
			return {}, .Incomplete_Frame
		}
		frame.pad_length = data[0]
		offset += 1
	}

	// Check for PRIORITY flag
	if frame_has_flag(&frame.header, .PRIORITY) {
		if len(data) < offset + 5 {
			return {}, .Incomplete_Frame
		}

		// Parse stream dependency (4 bytes)
		stream_dep := u32(data[offset]) << 24 | u32(data[offset + 1]) << 16 |
		              u32(data[offset + 2]) << 8 | u32(data[offset + 3])

		// Extract exclusive flag (bit 0)
		frame.exclusive = (stream_dep & 0x80000000) != 0
		frame.stream_dependency = stream_dep & STREAM_ID_MASK

		// Parse weight (1 byte)
		frame.weight = data[offset + 4]
		offset += 5
	}

	// Calculate header block length
	header_len := int(header.length) - offset - int(frame.pad_length)
	if header_len < 0 {
		return {}, .Protocol_Error
	}

	// Extract header block
	if header_len > 0 {
		frame.header_block = data[offset:offset + header_len]
	}

	// Extract padding (if any)
	if frame.pad_length > 0 {
		frame.padding = data[offset + header_len:offset + header_len + int(frame.pad_length)]
	}

	return frame, .None
}

// parse_priority_frame parses a PRIORITY frame
parse_priority_frame :: proc(header: Frame_Header, data: []u8) -> (frame: Priority_Frame, err: Parse_Error) {
	if header.length != 5 {
		return {}, .Frame_Size_Error
	}

	if len(data) < 5 {
		return {}, .Incomplete_Frame
	}

	frame.header = header

	// Parse stream dependency (4 bytes)
	stream_dep := u32(data[0]) << 24 | u32(data[1]) << 16 | u32(data[2]) << 8 | u32(data[3])

	// Extract exclusive flag (bit 0)
	frame.exclusive = (stream_dep & 0x80000000) != 0
	frame.stream_dependency = stream_dep & STREAM_ID_MASK

	// Parse weight (1 byte)
	frame.weight = data[4]

	return frame, .None
}

// parse_rst_stream_frame parses a RST_STREAM frame
parse_rst_stream_frame :: proc(header: Frame_Header, data: []u8) -> (frame: Rst_Stream_Frame, err: Parse_Error) {
	if header.length != 4 {
		return {}, .Frame_Size_Error
	}

	if len(data) < 4 {
		return {}, .Incomplete_Frame
	}

	frame.header = header

	// Parse error code (4 bytes)
	error_code := u32(data[0]) << 24 | u32(data[1]) << 16 | u32(data[2]) << 8 | u32(data[3])
	frame.error_code = Error_Code(error_code)

	return frame, .None
}

// parse_settings_frame parses a SETTINGS frame
parse_settings_frame :: proc(header: Frame_Header, data: []u8, allocator := context.allocator) -> (frame: Settings_Frame, err: Parse_Error) {
	if header.length % 6 != 0 {
		return {}, .Frame_Size_Error
	}

	if len(data) < int(header.length) {
		return {}, .Incomplete_Frame
	}

	frame.header = header

	// ACK flag means no payload
	if (header.flags & 0x1) != 0 {
		if header.length != 0 {
			return {}, .Frame_Size_Error
		}
		return frame, .None
	}

	// Parse settings
	num_settings := int(header.length) / 6
	if num_settings > 0 {
		settings, alloc_err := make([]Setting, num_settings, allocator)
		if alloc_err != nil {
			return {}, .Protocol_Error
		}
		frame.settings = settings

		for i in 0..<num_settings {
			offset := i * 6

			// Parse setting ID (2 bytes)
			id := u16(data[offset]) << 8 | u16(data[offset + 1])

			// Parse value (4 bytes)
			value := u32(data[offset + 2]) << 24 | u32(data[offset + 3]) << 16 |
			         u32(data[offset + 4]) << 8 | u32(data[offset + 5])

			frame.settings[i] = Setting{
				id = Settings_ID(id),
				value = value,
			}
		}
	}

	return frame, .None
}

// parse_ping_frame parses a PING frame
parse_ping_frame :: proc(header: Frame_Header, data: []u8) -> (frame: Ping_Frame, err: Parse_Error) {
	if header.length != 8 {
		return {}, .Frame_Size_Error
	}

	if len(data) < 8 {
		return {}, .Incomplete_Frame
	}

	frame.header = header

	// Copy opaque data (8 bytes)
	copy(frame.opaque_data[:], data[0:8])

	return frame, .None
}

// parse_goaway_frame parses a GOAWAY frame
parse_goaway_frame :: proc(header: Frame_Header, data: []u8) -> (frame: Goaway_Frame, err: Parse_Error) {
	if header.length < 8 {
		return {}, .Frame_Size_Error
	}

	if len(data) < int(header.length) {
		return {}, .Incomplete_Frame
	}

	frame.header = header

	// Parse last stream ID (4 bytes)
	last_stream := u32(data[0]) << 24 | u32(data[1]) << 16 | u32(data[2]) << 8 | u32(data[3])
	frame.last_stream_id = last_stream & STREAM_ID_MASK

	// Parse error code (4 bytes)
	error_code := u32(data[4]) << 24 | u32(data[5]) << 16 | u32(data[6]) << 8 | u32(data[7])
	frame.error_code = Error_Code(error_code)

	// Extract additional debug data (if any)
	if header.length > 8 {
		frame.additional_data = data[8:header.length]
	}

	return frame, .None
}

// parse_window_update_frame parses a WINDOW_UPDATE frame
parse_window_update_frame :: proc(header: Frame_Header, data: []u8) -> (frame: Window_Update_Frame, err: Parse_Error) {
	if header.length != 4 {
		return {}, .Frame_Size_Error
	}

	if len(data) < 4 {
		return {}, .Incomplete_Frame
	}

	frame.header = header

	// Parse window size increment (4 bytes, bit 0 is reserved)
	increment := u32(data[0]) << 24 | u32(data[1]) << 16 | u32(data[2]) << 8 | u32(data[3])
	frame.window_size_increment = increment & STREAM_ID_MASK

	if frame.window_size_increment == 0 {
		return {}, .Protocol_Error
	}

	return frame, .None
}

// parse_continuation_frame parses a CONTINUATION frame
parse_continuation_frame :: proc(header: Frame_Header, data: []u8) -> (frame: Continuation_Frame, err: Parse_Error) {
	if len(data) < int(header.length) {
		return {}, .Incomplete_Frame
	}

	frame.header = header

	// Extract header block fragment
	if header.length > 0 {
		frame.header_block = data[0:header.length]
	}

	return frame, .None
}
