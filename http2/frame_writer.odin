package http2

// Write_Error represents errors that can occur during frame writing
Write_Error :: enum {
	None,
	Buffer_Too_Small,
	Invalid_Frame_Size,
	Invalid_Stream_ID,
}

// write_frame_header writes a 9-byte frame header to a buffer
// Returns the number of bytes written
write_frame_header :: proc(buf: []u8, header: ^Frame_Header) -> (written: int, err: Write_Error) {
	if len(buf) < FRAME_HEADER_SIZE {
		return 0, .Buffer_Too_Small
	}

	if header.length > MAX_FRAME_SIZE {
		return 0, .Invalid_Frame_Size
	}

	// Write 24-bit length (3 bytes, big-endian)
	buf[0] = u8((header.length >> 16) & 0xFF)
	buf[1] = u8((header.length >> 8) & 0xFF)
	buf[2] = u8(header.length & 0xFF)

	// Write type (1 byte)
	buf[3] = u8(header.type)

	// Write flags (1 byte)
	buf[4] = header.flags

	// Write stream ID (4 bytes, big-endian, preserve reserved bit)
	buf[5] = u8((header.stream_id >> 24) & 0xFF)
	buf[6] = u8((header.stream_id >> 16) & 0xFF)
	buf[7] = u8((header.stream_id >> 8) & 0xFF)
	buf[8] = u8(header.stream_id & 0xFF)

	return FRAME_HEADER_SIZE, .None
}

// write_data_frame writes a DATA frame to a buffer
write_data_frame :: proc(buf: []u8, frame: ^Data_Frame) -> (written: int, err: Write_Error) {
	offset := 0

	// Write header
	n, header_err := write_frame_header(buf[offset:], &frame.header)
	if header_err != .None {
		return 0, header_err
	}
	offset += n

	// Check buffer size
	required := offset + int(frame.header.length)
	if len(buf) < required {
		return 0, .Buffer_Too_Small
	}

	// Write pad length if PADDED
	if frame_has_flag(&frame.header, .PADDED) {
		buf[offset] = frame.pad_length
		offset += 1
	}

	// Write data
	if len(frame.data) > 0 {
		copy(buf[offset:], frame.data)
		offset += len(frame.data)
	}

	// Write padding
	if len(frame.padding) > 0 {
		copy(buf[offset:], frame.padding)
		offset += len(frame.padding)
	}

	return offset, .None
}

// write_headers_frame writes a HEADERS frame to a buffer
write_headers_frame :: proc(buf: []u8, frame: ^Headers_Frame) -> (written: int, err: Write_Error) {
	offset := 0

	// Write header
	n, header_err := write_frame_header(buf[offset:], &frame.header)
	if header_err != .None {
		return 0, header_err
	}
	offset += n

	// Check buffer size
	required := offset + int(frame.header.length)
	if len(buf) < required {
		return 0, .Buffer_Too_Small
	}

	// Write pad length if PADDED
	if frame_has_flag(&frame.header, .PADDED) {
		buf[offset] = frame.pad_length
		offset += 1
	}

	// Write priority if PRIORITY flag is set
	if frame_has_flag(&frame.header, .PRIORITY) {
		// Combine exclusive flag with stream dependency
		stream_dep := frame.stream_dependency & STREAM_ID_MASK
		if frame.exclusive {
			stream_dep |= 0x80000000
		}

		buf[offset] = u8((stream_dep >> 24) & 0xFF)
		buf[offset + 1] = u8((stream_dep >> 16) & 0xFF)
		buf[offset + 2] = u8((stream_dep >> 8) & 0xFF)
		buf[offset + 3] = u8(stream_dep & 0xFF)
		buf[offset + 4] = frame.weight
		offset += 5
	}

	// Write header block
	if len(frame.header_block) > 0 {
		copy(buf[offset:], frame.header_block)
		offset += len(frame.header_block)
	}

	// Write padding
	if len(frame.padding) > 0 {
		copy(buf[offset:], frame.padding)
		offset += len(frame.padding)
	}

	return offset, .None
}

// write_priority_frame writes a PRIORITY frame to a buffer
write_priority_frame :: proc(buf: []u8, frame: ^Priority_Frame) -> (written: int, err: Write_Error) {
	if len(buf) < FRAME_HEADER_SIZE + 5 {
		return 0, .Buffer_Too_Small
	}

	offset := 0

	// Write header
	n, header_err := write_frame_header(buf[offset:], &frame.header)
	if header_err != .None {
		return 0, header_err
	}
	offset += n

	// Combine exclusive flag with stream dependency
	stream_dep := frame.stream_dependency & STREAM_ID_MASK
	if frame.exclusive {
		stream_dep |= 0x80000000
	}

	buf[offset] = u8((stream_dep >> 24) & 0xFF)
	buf[offset + 1] = u8((stream_dep >> 16) & 0xFF)
	buf[offset + 2] = u8((stream_dep >> 8) & 0xFF)
	buf[offset + 3] = u8(stream_dep & 0xFF)
	buf[offset + 4] = frame.weight
	offset += 5

	return offset, .None
}

// write_rst_stream_frame writes a RST_STREAM frame to a buffer
write_rst_stream_frame :: proc(buf: []u8, frame: ^Rst_Stream_Frame) -> (written: int, err: Write_Error) {
	if len(buf) < FRAME_HEADER_SIZE + 4 {
		return 0, .Buffer_Too_Small
	}

	offset := 0

	// Write header
	n, header_err := write_frame_header(buf[offset:], &frame.header)
	if header_err != .None {
		return 0, header_err
	}
	offset += n

	// Write error code
	error_code := u32(frame.error_code)
	buf[offset] = u8((error_code >> 24) & 0xFF)
	buf[offset + 1] = u8((error_code >> 16) & 0xFF)
	buf[offset + 2] = u8((error_code >> 8) & 0xFF)
	buf[offset + 3] = u8(error_code & 0xFF)
	offset += 4

	return offset, .None
}

// write_settings_frame writes a SETTINGS frame to a buffer
write_settings_frame :: proc(buf: []u8, frame: ^Settings_Frame) -> (written: int, err: Write_Error) {
	required := FRAME_HEADER_SIZE + len(frame.settings) * 6
	if len(buf) < required {
		return 0, .Buffer_Too_Small
	}

	offset := 0

	// Write header
	n, header_err := write_frame_header(buf[offset:], &frame.header)
	if header_err != .None {
		return 0, header_err
	}
	offset += n

	// Write settings
	for setting in frame.settings {
		id := u16(setting.id)
		buf[offset] = u8((id >> 8) & 0xFF)
		buf[offset + 1] = u8(id & 0xFF)

		buf[offset + 2] = u8((setting.value >> 24) & 0xFF)
		buf[offset + 3] = u8((setting.value >> 16) & 0xFF)
		buf[offset + 4] = u8((setting.value >> 8) & 0xFF)
		buf[offset + 5] = u8(setting.value & 0xFF)
		offset += 6
	}

	return offset, .None
}

// write_ping_frame writes a PING frame to a buffer
write_ping_frame :: proc(buf: []u8, frame: ^Ping_Frame) -> (written: int, err: Write_Error) {
	if len(buf) < FRAME_HEADER_SIZE + 8 {
		return 0, .Buffer_Too_Small
	}

	offset := 0

	// Write header
	n, header_err := write_frame_header(buf[offset:], &frame.header)
	if header_err != .None {
		return 0, header_err
	}
	offset += n

	// Write opaque data
	copy(buf[offset:offset + 8], frame.opaque_data[:])
	offset += 8

	return offset, .None
}

// write_goaway_frame writes a GOAWAY frame to a buffer
write_goaway_frame :: proc(buf: []u8, frame: ^Goaway_Frame) -> (written: int, err: Write_Error) {
	required := FRAME_HEADER_SIZE + 8 + len(frame.additional_data)
	if len(buf) < required {
		return 0, .Buffer_Too_Small
	}

	offset := 0

	// Write header
	n, header_err := write_frame_header(buf[offset:], &frame.header)
	if header_err != .None {
		return 0, header_err
	}
	offset += n

	// Write last stream ID
	last_stream := frame.last_stream_id & STREAM_ID_MASK
	buf[offset] = u8((last_stream >> 24) & 0xFF)
	buf[offset + 1] = u8((last_stream >> 16) & 0xFF)
	buf[offset + 2] = u8((last_stream >> 8) & 0xFF)
	buf[offset + 3] = u8(last_stream & 0xFF)

	// Write error code
	error_code := u32(frame.error_code)
	buf[offset + 4] = u8((error_code >> 24) & 0xFF)
	buf[offset + 5] = u8((error_code >> 16) & 0xFF)
	buf[offset + 6] = u8((error_code >> 8) & 0xFF)
	buf[offset + 7] = u8(error_code & 0xFF)
	offset += 8

	// Write additional data
	if len(frame.additional_data) > 0 {
		copy(buf[offset:], frame.additional_data)
		offset += len(frame.additional_data)
	}

	return offset, .None
}

// write_window_update_frame writes a WINDOW_UPDATE frame to a buffer
write_window_update_frame :: proc(buf: []u8, frame: ^Window_Update_Frame) -> (written: int, err: Write_Error) {
	if len(buf) < FRAME_HEADER_SIZE + 4 {
		return 0, .Buffer_Too_Small
	}

	offset := 0

	// Write header
	n, header_err := write_frame_header(buf[offset:], &frame.header)
	if header_err != .None {
		return 0, header_err
	}
	offset += n

	// Write window size increment (preserve reserved bit)
	increment := frame.window_size_increment & STREAM_ID_MASK
	buf[offset] = u8((increment >> 24) & 0xFF)
	buf[offset + 1] = u8((increment >> 16) & 0xFF)
	buf[offset + 2] = u8((increment >> 8) & 0xFF)
	buf[offset + 3] = u8(increment & 0xFF)
	offset += 4

	return offset, .None
}

// write_continuation_frame writes a CONTINUATION frame to a buffer
write_continuation_frame :: proc(buf: []u8, frame: ^Continuation_Frame) -> (written: int, err: Write_Error) {
	required := FRAME_HEADER_SIZE + len(frame.header_block)
	if len(buf) < required {
		return 0, .Buffer_Too_Small
	}

	offset := 0

	// Write header
	n, header_err := write_frame_header(buf[offset:], &frame.header)
	if header_err != .None {
		return 0, header_err
	}
	offset += n

	// Write header block
	if len(frame.header_block) > 0 {
		copy(buf[offset:], frame.header_block)
		offset += len(frame.header_block)
	}

	return offset, .None
}
