package http2

import "base:runtime"
import "core:fmt"
import hpack "hpack"

// Protocol_Handler manages the HTTP/2 protocol for a connection
Protocol_Handler :: struct {
	conn:            HTTP2_Connection,
	encoder:         hpack.Encoder_Context,
	decoder:         hpack.Decoder_Context,
	read_buffer:     [dynamic]byte,  // Buffer for incoming data
	write_buffer:    [dynamic]byte,  // Buffer for outgoing data
	preface_offset:  int,             // Bytes of preface received so far
	allocator:       runtime.Allocator,
}

// protocol_handler_init creates a new protocol handler
protocol_handler_init :: proc(is_server: bool, allocator := context.allocator) -> (handler: Protocol_Handler, ok: bool) {
	conn, conn_ok := connection_init(is_server, allocator)
	if !conn_ok {
		return {}, false
	}

	encoder, encoder_ok := hpack.encoder_init(4096, false, allocator)  // Disable Huffman for simplicity
	if !encoder_ok {
		connection_destroy(&conn)
		return {}, false
	}

	decoder, decoder_ok := hpack.decoder_init(4096, 8192, allocator)
	if !decoder_ok {
		hpack.encoder_destroy(&encoder)
		connection_destroy(&conn)
		return {}, false
	}

	read_buffer := make([dynamic]byte, 0, 4096, allocator)
	write_buffer := make([dynamic]byte, 0, 4096, allocator)

	return Protocol_Handler{
		conn = conn,
		encoder = encoder,
		decoder = decoder,
		read_buffer = read_buffer,
		write_buffer = write_buffer,
		preface_offset = 0,
		allocator = allocator,
	}, true
}

// protocol_handler_destroy frees all handler resources
protocol_handler_destroy :: proc(handler: ^Protocol_Handler) {
	if handler == nil {
		return
	}

	connection_destroy(&handler.conn)
	hpack.encoder_destroy(&handler.encoder)
	hpack.decoder_destroy(&handler.decoder)
	delete(handler.read_buffer)
	delete(handler.write_buffer)
}

// protocol_handler_process_data processes incoming data
protocol_handler_process_data :: proc(handler: ^Protocol_Handler, data: []byte) -> bool {
	if handler == nil || len(data) == 0 {
		return false
	}

	// Append to read buffer
	append(&handler.read_buffer, ..data)

	// Try to process what we have
	return protocol_handler_process_buffer(handler)
}

// protocol_handler_process_buffer processes buffered data
protocol_handler_process_buffer :: proc(handler: ^Protocol_Handler) -> bool {
	if handler == nil {
		return false
	}

	// Handle preface if we're waiting for it
	if handler.conn.state == .Waiting_Preface {
		if len(handler.read_buffer) < CONNECTION_PREFACE_LENGTH {
			// Need more data
			return true
		}

		// Validate preface
		err := connection_handle_preface(&handler.conn, handler.read_buffer[:CONNECTION_PREFACE_LENGTH])
		if err != .None {
			return false
		}

		// Remove preface from buffer
		copy(handler.read_buffer[:], handler.read_buffer[CONNECTION_PREFACE_LENGTH:])
		resize(&handler.read_buffer, len(handler.read_buffer) - CONNECTION_PREFACE_LENGTH)

		// Send server's SETTINGS frame now that preface is validated
		protocol_handler_send_initial_settings(handler)
	}

	// Process frames
	for len(handler.read_buffer) >= FRAME_HEADER_SIZE {
		// Parse frame header
		frame_header, _, parse_err := parse_frame_header(handler.read_buffer[:FRAME_HEADER_SIZE])
		if parse_err != .None {
			return false
		}

		// Check if we have the full frame
		frame_size := int(frame_header.length) + FRAME_HEADER_SIZE
		if len(handler.read_buffer) < frame_size {
			// Need more data
			return true
		}

		// Process the frame
		frame_data := handler.read_buffer[:frame_size]
		ok := protocol_handler_process_frame(handler, frame_data)
		if !ok {
			return false
		}

		// Remove frame from buffer
		copy(handler.read_buffer[:], handler.read_buffer[frame_size:])
		resize(&handler.read_buffer, len(handler.read_buffer) - frame_size)
	}

	return true
}

// protocol_handler_process_frame processes a single frame
protocol_handler_process_frame :: proc(handler: ^Protocol_Handler, frame_data: []byte) -> bool {
	if handler == nil || len(frame_data) < FRAME_HEADER_SIZE {
		fmt.eprintln("protocol_handler_process_frame: invalid input")
		return false
	}

	header, _, parse_err := parse_frame_header(frame_data[:FRAME_HEADER_SIZE])
	if parse_err != .None {
		fmt.eprintfln("protocol_handler_process_frame: failed to parse frame header: %v", parse_err)
		return false
	}
	payload := frame_data[FRAME_HEADER_SIZE:]

	#partial switch header.type {
	case .SETTINGS:
		return protocol_handler_handle_settings(handler, &header, payload)
	case .HEADERS:
		return protocol_handler_handle_headers(handler, &header, payload)
	case .DATA:
		// DATA frame handling (not implemented yet)
		return true
	case .PING:
		return protocol_handler_handle_ping(handler, &header, payload)
	case .WINDOW_UPDATE:
		// WINDOW_UPDATE handling (not implemented yet)
		return true
	case .RST_STREAM:
		return true
	case .GOAWAY:
		return protocol_handler_handle_goaway(handler, &header, payload)
	case .PRIORITY:
		// PRIORITY frame - just ignore it
		return true
	case .CONTINUATION:
		// CONTINUATION frame - not supported yet, but don't fail
		fmt.eprintln("[HTTP/2] CONTINUATION frame not supported yet")
		return true
	case:
		return true
	}
}

// protocol_handler_handle_settings processes a SETTINGS frame
protocol_handler_handle_settings :: proc(handler: ^Protocol_Handler, header: ^Frame_Header, payload: []byte) -> bool {
	// Check if ACK
	is_ack := (header.flags & SETTINGS_FLAG_ACK) != 0

	if is_ack {
		// ACK our settings
		settings_frame := Settings_Frame{header = header^, settings = nil}
		connection_handle_settings(&handler.conn, &settings_frame)
		return true
	}

	// Parse settings
	settings_count := len(payload) / 6
	settings := make([]Setting, settings_count, handler.allocator)
	defer delete(settings)

	for i in 0..<settings_count {
		offset := i * 6
		id := Settings_ID((u16(payload[offset]) << 8) | u16(payload[offset + 1]))
		value := u32(payload[offset + 2]) << 24 | u32(payload[offset + 3]) << 16 |
		         u32(payload[offset + 4]) << 8 | u32(payload[offset + 5])
		settings[i] = Setting{id = id, value = value}
	}

	settings_frame := Settings_Frame{header = header^, settings = settings}
	err := connection_handle_settings(&handler.conn, &settings_frame)
	if err != .None {
		return false
	}

	// Send SETTINGS ACK
	protocol_handler_send_settings_ack(handler)

	return true
}

// protocol_handler_handle_headers processes a HEADERS frame
protocol_handler_handle_headers :: proc(handler: ^Protocol_Handler, header: ^Frame_Header, payload: []byte) -> bool {
	// Parse HEADERS frame to extract header block
	headers_frame, parse_err := parse_headers_frame(header^, payload)
	if parse_err != .None {
		return false
	}

	// Get or create stream
	stream, found := connection_get_stream(&handler.conn, header.stream_id)
	if !found {
		new_stream, err := connection_create_stream(&handler.conn, header.stream_id)
		if err != .None {
			return false
		}
		stream = new_stream
	}

	// Update stream state
	end_stream := (header.flags & 0x01) != 0
	stream_recv_headers(stream, end_stream)

	// Decode headers from header block
	req, ok := request_decode(&handler.decoder, headers_frame.header_block, handler.allocator)
	if !ok {
		return false
	}
	defer request_destroy(&req)

	// Handle request
	resp := handle_request(&req, handler.allocator)
	defer delete(resp.headers)

	// Send response
	protocol_handler_send_response(handler, header.stream_id, &resp)

	// Clean up closed stream after sending complete response
	if stream.state == .Closed {
		connection_remove_stream(&handler.conn, header.stream_id)
	}

	return true
}

// protocol_handler_handle_ping processes a PING frame
protocol_handler_handle_ping :: proc(handler: ^Protocol_Handler, header: ^Frame_Header, payload: []byte) -> bool {
	is_ack := (header.flags & 0x01) != 0
	if is_ack {
		return true
	}

	// Send PING ACK with same data
	protocol_handler_send_ping_ack(handler, payload)
	return true
}

// protocol_handler_handle_goaway processes a GOAWAY frame
protocol_handler_handle_goaway :: proc(handler: ^Protocol_Handler, header: ^Frame_Header, payload: []byte) -> bool {
	if len(payload) < 8 {
		return false
	}

	// Mark connection as closing - return false to signal connection should be closed
	return false
}

// protocol_handler_send_settings_ack sends a SETTINGS ACK frame
protocol_handler_send_settings_ack :: proc(handler: ^Protocol_Handler) {
	ack_frame := settings_build_ack_frame()
	protocol_handler_write_frame_header(handler, &ack_frame.header)
}

// protocol_handler_send_ping_ack sends a PING ACK
protocol_handler_send_ping_ack :: proc(handler: ^Protocol_Handler, data: []byte) {
	header := Frame_Header{
		length = 8,
		type = .PING,
		flags = 0x01,  // ACK
		stream_id = 0,
	}
	protocol_handler_write_frame_header(handler, &header)
	append(&handler.write_buffer, ..data)
}

// protocol_handler_send_response sends an HTTP/2 response
protocol_handler_send_response :: proc(handler: ^Protocol_Handler, stream_id: u32, resp: ^Response) {
	// Get stream
	stream, found := connection_get_stream(&handler.conn, stream_id)
	if !found {
		return
	}

	// Encode headers
	headers_encoded, ok := response_encode(&handler.encoder, resp, handler.allocator)
	if !ok {
		return
	}
	defer delete(headers_encoded)

	// Send HEADERS frame
	headers_header := Frame_Header{
		length = u32(len(headers_encoded)),
		type = .HEADERS,
		flags = 0x04,  // END_HEADERS
		stream_id = stream_id,
	}
	protocol_handler_write_frame_header(handler, &headers_header)
	append(&handler.write_buffer, ..headers_encoded)

	// Update stream state for sending HEADERS (without END_STREAM)
	stream_send_headers(stream, false)

	// Send DATA frame with END_STREAM
	data_header := Frame_Header{
		length = u32(len(resp.body)),
		type = .DATA,
		flags = 0x01,  // END_STREAM
		stream_id = stream_id,
	}
	protocol_handler_write_frame_header(handler, &data_header)
	append(&handler.write_buffer, ..resp.body)

	// Update stream state for sending DATA with END_STREAM
	stream_send_data(stream, len(resp.body), true)
}

// protocol_handler_write_frame_header writes a frame header to the write buffer
protocol_handler_write_frame_header :: proc(handler: ^Protocol_Handler, header: ^Frame_Header) {
	// Write all 9 bytes of frame header at once
	frame_header_bytes := [9]u8{
		u8(header.length >> 16),
		u8(header.length >> 8),
		u8(header.length),
		u8(header.type),
		header.flags,
		u8(header.stream_id >> 24),
		u8(header.stream_id >> 16),
		u8(header.stream_id >> 8),
		u8(header.stream_id),
	}
	append(&handler.write_buffer, ..frame_header_bytes[:])
}

// protocol_handler_get_write_data returns data to write
protocol_handler_get_write_data :: proc(handler: ^Protocol_Handler) -> []byte {
	if handler == nil {
		return nil
	}
	return handler.write_buffer[:]
}

// protocol_handler_consume_write_data consumes written data from buffer
protocol_handler_consume_write_data :: proc(handler: ^Protocol_Handler, bytes_written: int) {
	if handler == nil || bytes_written <= 0 {
		return
	}

	if bytes_written >= len(handler.write_buffer) {
		clear(&handler.write_buffer)
	} else {
		copy(handler.write_buffer[:], handler.write_buffer[bytes_written:])
		resize(&handler.write_buffer, len(handler.write_buffer) - bytes_written)
	}
}

// protocol_handler_needs_write checks if there's data to write
protocol_handler_needs_write :: proc(handler: ^Protocol_Handler) -> bool {
	if handler == nil {
		return false
	}
	return len(handler.write_buffer) > 0
}

// protocol_handler_send_initial_settings sends initial SETTINGS frame
protocol_handler_send_initial_settings :: proc(handler: ^Protocol_Handler) {
	settings_frame, ok := settings_build_frame(&handler.conn.settings, handler.allocator)
	if !ok {
		return
	}
	defer delete(settings_frame.settings)

	protocol_handler_write_frame_header(handler, &settings_frame.header)

	// Write settings payload - each setting is 6 bytes
	for setting in settings_frame.settings {
		setting_bytes := [6]u8{
			u8(u16(setting.id) >> 8),
			u8(u16(setting.id)),
			u8(setting.value >> 24),
			u8(setting.value >> 16),
			u8(setting.value >> 8),
			u8(setting.value),
		}
		append(&handler.write_buffer, ..setting_bytes[:])
	}
}
