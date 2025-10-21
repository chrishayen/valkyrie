package http

import "base:runtime"
import "core:fmt"
import hpack "hpack"

// Protocol_Handler manages the HTTP/2 protocol for a connection
Protocol_Handler :: struct {
	conn:            HTTP2_Connection,
	encoder:         hpack.Encoder_Context,
	decoder:         hpack.Decoder_Context,
	read_buffer:     Ring_Buffer,       // Ring buffer for incoming data
	write_buffer:    [dynamic]byte,     // Buffer for outgoing data
	preface_offset:  int,                // Bytes of preface received so far
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

	read_buffer, read_buffer_ok := buffer_init(16384, allocator)  // 16KB ring buffer
	if !read_buffer_ok {
		hpack.decoder_destroy(&decoder)
		hpack.encoder_destroy(&encoder)
		connection_destroy(&conn)
		return {}, false
	}

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
	buffer_destroy(&handler.read_buffer)
	delete(handler.write_buffer)
}

// protocol_handler_process_data processes incoming data
protocol_handler_process_data :: proc(handler: ^Protocol_Handler, data: []byte) -> bool {
	if handler == nil || len(data) == 0 {
		return false
	}

	// Write to ring buffer
	bytes_written := buffer_write(&handler.read_buffer, data)
	if bytes_written < len(data) {
		// Buffer full - this shouldn't happen with proper flow control
		fmt.eprintfln("[HTTP/2] Warning: ring buffer full, wrote %d/%d bytes", bytes_written, len(data))
	}

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
		if buffer_available_read(&handler.read_buffer) < CONNECTION_PREFACE_LENGTH {
			// Need more data
			return true
		}

		// Peek at preface data without consuming
		preface_buf := make([]byte, CONNECTION_PREFACE_LENGTH, handler.allocator)
		defer delete(preface_buf)
		buffer_peek(&handler.read_buffer, preface_buf)

		// Validate preface
		err := connection_handle_preface(&handler.conn, preface_buf)
		if err != .None {
			return false
		}

		// Consume preface from buffer
		buffer_consume(&handler.read_buffer, CONNECTION_PREFACE_LENGTH)

		// Send server's SETTINGS frame now that preface is validated
		protocol_handler_send_initial_settings(handler)
	}

	// Process frames
	for buffer_available_read(&handler.read_buffer) >= FRAME_HEADER_SIZE {
		// Peek at frame header
		header_buf := make([]byte, FRAME_HEADER_SIZE, handler.allocator)
		defer delete(header_buf)
		buffer_peek(&handler.read_buffer, header_buf)

		// Parse frame header
		frame_header, _, parse_err := parse_frame_header(header_buf)
		if parse_err != .None {
			return false
		}

		// Validate frame size against our local MAX_FRAME_SIZE (what we told peer they can send)
		// Note: SETTINGS frames are exempt from size validation per RFC
		if frame_header.type != .SETTINGS {
			max_frame_size := settings_get_local_max_frame_size(&handler.conn.settings)
			if frame_header.length > max_frame_size {
				fmt.eprintfln("[HTTP/2] Frame size %d exceeds MAX_FRAME_SIZE %d", frame_header.length, max_frame_size)
				protocol_handler_send_goaway(handler, .FRAME_SIZE_ERROR)
				return false
			}
		}

		// Check if we have the full frame
		frame_size := int(frame_header.length) + FRAME_HEADER_SIZE
		if buffer_available_read(&handler.read_buffer) < frame_size {
			// Need more data
			return true
		}

		// Peek at full frame data
		frame_data := make([]byte, frame_size, handler.allocator)
		defer delete(frame_data)
		buffer_peek(&handler.read_buffer, frame_data)

		// Process the frame
		ok := protocol_handler_process_frame(handler, frame_data)
		if !ok {
			return false
		}

		// Consume frame from buffer
		buffer_consume(&handler.read_buffer, frame_size)
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

	// RFC 9113 Section 6.10: If expecting CONTINUATION, reject all other frames
	if handler.conn.continuation_expected {
		if header.type != .CONTINUATION {
			fmt.eprintfln("[HTTP/2] Expected CONTINUATION frame, got %v", header.type)
			protocol_handler_send_goaway(handler, .PROTOCOL_ERROR)
			return false
		}
		if header.stream_id != handler.conn.continuation_stream_id {
			fmt.eprintfln("[HTTP/2] CONTINUATION on wrong stream: expected %d, got %d",
				handler.conn.continuation_stream_id, header.stream_id)
			protocol_handler_send_goaway(handler, .PROTOCOL_ERROR)
			return false
		}
	}

	#partial switch header.type {
	case .SETTINGS:
		return protocol_handler_handle_settings(handler, &header, payload)
	case .HEADERS:
		return protocol_handler_handle_headers(handler, &header, payload)
	case .DATA:
		return protocol_handler_handle_data(handler, &header, payload)
	case .PING:
		return protocol_handler_handle_ping(handler, &header, payload)
	case .WINDOW_UPDATE:
		return protocol_handler_handle_window_update(handler, &header, payload)
	case .RST_STREAM:
		return protocol_handler_handle_rst_stream(handler, &header, payload)
	case .GOAWAY:
		return protocol_handler_handle_goaway(handler, &header, payload)
	case .PRIORITY:
		// PRIORITY frame - just ignore it
		return true
	case .CONTINUATION:
		return protocol_handler_handle_continuation(handler, &header, payload)
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
		fmt.eprintfln("[HTTP/2] Failed to parse HEADERS frame: %v", parse_err)
		protocol_handler_send_rst_stream(handler, header.stream_id, .PROTOCOL_ERROR)
		return true
	}

	// Get or create stream
	stream, found := connection_get_stream(&handler.conn, header.stream_id)
	if !found {
		new_stream, err := connection_create_stream(&handler.conn, header.stream_id)
		if err != .None {
			fmt.eprintfln("[HTTP/2] Failed to create stream %d: %v", header.stream_id, err)
			protocol_handler_send_rst_stream(handler, header.stream_id, .REFUSED_STREAM)
			return true
		}
		stream = new_stream
	}

	// Update stream state
	end_stream := (header.flags & 0x01) != 0
	end_headers := (header.flags & 0x04) != 0
	stream_err := stream_recv_headers(stream, end_stream)
	if stream_err != .None {
		fmt.eprintfln("[HTTP/2] Stream error receiving HEADERS: %v", stream_err)
		protocol_handler_send_rst_stream(handler, header.stream_id, .PROTOCOL_ERROR)
		connection_remove_stream(&handler.conn, header.stream_id)
		return true
	}

	// If END_HEADERS is not set, we're expecting CONTINUATION frames
	if !end_headers {
		// Start continuation sequence
		handler.conn.continuation_expected = true
		handler.conn.continuation_stream_id = header.stream_id
		clear(&handler.conn.continuation_header_block)

		// Append header block fragment
		for b in headers_frame.header_block {
			append(&handler.conn.continuation_header_block, b)
		}

		// Store END_STREAM flag for later processing
		stream.recv_headers_complete = false
		return true
	}

	// Complete header block received - decode it
	req, ok := request_decode(&handler.decoder, headers_frame.header_block, handler.allocator)
	if !ok {
		fmt.eprintln("[HTTP/2] Failed to decode HPACK headers")
		protocol_handler_send_rst_stream(handler, header.stream_id, .COMPRESSION_ERROR)
		connection_remove_stream(&handler.conn, header.stream_id)
		return true
	}

	// Mark headers as complete
	stream.recv_headers_complete = true

	// If END_STREAM in HEADERS, process request immediately (no body expected)
	if end_stream {
		// Request has no body
		defer request_destroy(&req)

		// Handle request
		resp := handle_request(&req, handler.allocator)
		defer {
			for h in resp.headers {
				delete(h.value)
			}
			delete(resp.headers)
			delete(resp.body)
		}

		// Send response
		protocol_handler_send_response(handler, header.stream_id, &resp)

		// Clean up closed stream after sending complete response
		if stream.state == .Closed {
			connection_remove_stream(&handler.conn, header.stream_id)
		}
	} else {
		// Request has body - store header block for later processing
		// Clean up the decoded request for now (we'll decode again later with body)
		request_destroy(&req)

		// Copy header block for later
		header_block_copy := make([]byte, len(headers_frame.header_block), handler.allocator)
		copy(header_block_copy, headers_frame.header_block)
		stream.recv_header_block = header_block_copy
	}

	return true
}

// protocol_handler_handle_continuation processes a CONTINUATION frame
protocol_handler_handle_continuation :: proc(handler: ^Protocol_Handler, header: ^Frame_Header, payload: []byte) -> bool {
	if handler == nil {
		return false
	}

	// CONTINUATION frames must only appear during a continuation sequence
	// (this is already validated in protocol_handler_process_frame)

	// Parse CONTINUATION frame
	continuation_frame, parse_err := parse_continuation_frame(header^, payload)
	if parse_err != .None {
		fmt.eprintfln("[HTTP/2] Failed to parse CONTINUATION frame: %v", parse_err)
		protocol_handler_send_goaway(handler, .PROTOCOL_ERROR)
		return false
	}

	// Append header block fragment
	for b in continuation_frame.header_block {
		append(&handler.conn.continuation_header_block, b)
	}

	// Check for END_HEADERS flag
	end_headers := (header.flags & 0x04) != 0

	if !end_headers {
		// More CONTINUATION frames expected
		return true
	}

	// END_HEADERS received - process complete header block
	stream, found := connection_get_stream(&handler.conn, header.stream_id)
	if !found {
		fmt.eprintfln("[HTTP/2] Stream %d not found for CONTINUATION", header.stream_id)
		protocol_handler_send_goaway(handler, .PROTOCOL_ERROR)
		return false
	}

	// Decode complete header block
	complete_header_block := handler.conn.continuation_header_block[:]
	req, ok := request_decode(&handler.decoder, complete_header_block, handler.allocator)
	if !ok {
		fmt.eprintln("[HTTP/2] Failed to decode HPACK headers from CONTINUATION")
		protocol_handler_send_rst_stream(handler, header.stream_id, .COMPRESSION_ERROR)
		connection_remove_stream(&handler.conn, header.stream_id)

		// Reset continuation state
		handler.conn.continuation_expected = false
		handler.conn.continuation_stream_id = 0
		clear(&handler.conn.continuation_header_block)
		return true
	}

	// Mark headers as complete
	stream.recv_headers_complete = true

	// Reset continuation state
	handler.conn.continuation_expected = false
	handler.conn.continuation_stream_id = 0
	clear(&handler.conn.continuation_header_block)

	// Check if this was a request with or without body
	// (END_STREAM flag would have been set in the original HEADERS frame)
	end_stream := stream.state == .Half_Closed_Remote || stream.state == .Closed

	if end_stream {
		// Request has no body - process immediately
		defer request_destroy(&req)

		// Handle request
		resp := handle_request(&req, handler.allocator)
		defer {
			for h in resp.headers {
				delete(h.value)
			}
			delete(resp.headers)
			delete(resp.body)
		}

		// Send response
		protocol_handler_send_response(handler, header.stream_id, &resp)

		// Clean up closed stream
		if stream.state == .Closed {
			connection_remove_stream(&handler.conn, header.stream_id)
		}
	} else {
		// Request has body - store header block for later processing with body
		request_destroy(&req)

		// Copy complete header block for later
		header_block_copy := make([]byte, len(complete_header_block), handler.allocator)
		copy(header_block_copy, complete_header_block)
		stream.recv_header_block = header_block_copy
	}

	return true
}

// protocol_handler_handle_data processes a DATA frame
protocol_handler_handle_data :: proc(handler: ^Protocol_Handler, header: ^Frame_Header, payload: []byte) -> bool {
	if handler == nil {
		return false
	}

	// DATA frames must be associated with a stream
	if header.stream_id == 0 {
		fmt.eprintln("[HTTP/2] DATA frame on stream 0 is invalid")
		protocol_handler_send_goaway(handler, .PROTOCOL_ERROR)
		return false
	}

	// Get stream
	stream, found := connection_get_stream(&handler.conn, header.stream_id)
	if !found {
		fmt.eprintfln("[HTTP/2] DATA frame on non-existent stream %d", header.stream_id)
		protocol_handler_send_rst_stream(handler, header.stream_id, .STREAM_CLOSED)
		return true  // Continue processing other frames
	}

	// Parse DATA frame
	data_frame, parse_err := parse_data_frame(header^, payload)
	if parse_err != .None {
		fmt.eprintfln("[HTTP/2] Failed to parse DATA frame: %v", parse_err)
		protocol_handler_send_rst_stream(handler, header.stream_id, .PROTOCOL_ERROR)
		connection_remove_stream(&handler.conn, header.stream_id)
		return true
	}

	// Check stream state allows receiving data
	if !stream_can_recv_data(stream) {
		fmt.eprintfln("[HTTP/2] Stream %d cannot receive DATA in state %v", header.stream_id, stream.state)
		protocol_handler_send_rst_stream(handler, header.stream_id, .STREAM_CLOSED)
		connection_remove_stream(&handler.conn, header.stream_id)
		return true
	}

	data_len := len(data_frame.data)
	end_stream := (header.flags & 0x01) != 0

	// Check connection-level flow control
	if handler.conn.connection_window < i32(data_len) {
		fmt.eprintfln("[HTTP/2] Connection flow control violation: need %d, have %d", data_len, handler.conn.connection_window)
		// Connection-level flow control error - this is fatal
		protocol_handler_send_goaway(handler, .FLOW_CONTROL_ERROR)
		return false
	}

	// Process data reception (checks stream-level flow control)
	stream_err := stream_recv_data(stream, data_len, end_stream)
	if stream_err != .None {
		fmt.eprintfln("[HTTP/2] Stream error processing DATA: %v", stream_err)
		protocol_handler_send_rst_stream(handler, header.stream_id, .FLOW_CONTROL_ERROR)
		connection_remove_stream(&handler.conn, header.stream_id)
		return true
	}

	// Consume connection-level window
	conn_err := connection_consume_window(&handler.conn, i32(data_len))
	if conn_err != .None {
		fmt.eprintfln("[HTTP/2] Connection flow control error: %v", conn_err)
		protocol_handler_send_goaway(handler, .FLOW_CONTROL_ERROR)
		return false
	}

	// Append data to stream body buffer
	if data_len > 0 {
		for b in data_frame.data {
			append(&stream.recv_body, b)
		}
	}

	// Replenish flow control windows if needed (before they're exhausted)
	protocol_handler_replenish_windows(handler, header.stream_id)

	// If END_STREAM received, process complete request with body
	if end_stream && stream.recv_headers_complete {
		// Decode headers with accumulated body
		req, ok := request_decode(&handler.decoder, stream.recv_header_block, handler.allocator)
		if !ok {
			return false
		}
		defer request_destroy(&req)

		// Attach body
		req.body = stream.recv_body[:]

		// Handle request
		resp := handle_request(&req, handler.allocator)
		defer {
			for h in resp.headers {
				delete(h.value)
			}
			delete(resp.headers)
			delete(resp.body)
		}

		// Send response
		protocol_handler_send_response(handler, header.stream_id, &resp)
	}

	// If stream is now closed (received END_STREAM), remove it
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

// protocol_handler_handle_window_update processes a WINDOW_UPDATE frame
protocol_handler_handle_window_update :: proc(handler: ^Protocol_Handler, header: ^Frame_Header, payload: []byte) -> bool {
	if handler == nil {
		return false
	}

	// Parse WINDOW_UPDATE frame
	window_frame, parse_err := parse_window_update_frame(header^, payload)
	if parse_err != .None {
		fmt.eprintfln("[HTTP/2] Failed to parse WINDOW_UPDATE frame: %v", parse_err)
		return false
	}

	increment := i32(window_frame.window_size_increment)
	if increment <= 0 {
		fmt.eprintln("[HTTP/2] WINDOW_UPDATE with zero increment")
		return false
	}

	if header.stream_id == 0 {
		// Connection-level window update from peer (they can receive more)
		err := connection_update_remote_window(&handler.conn, increment)
		if err != .None {
			fmt.eprintfln("[HTTP/2] Connection WINDOW_UPDATE error: %v", err)
			return false
		}

		// Resume any streams that have queued data (connection window was blocking them)
		for id in handler.conn.streams {
			stream := &handler.conn.streams[id]
			if stream.pending_send_data != nil && len(stream.pending_send_data) > 0 {
				protocol_handler_resume_stream_send(handler, id)
			}
		}
	} else {
		// Stream-level window update
		stream, found := connection_get_stream(&handler.conn, header.stream_id)
		if !found {
			fmt.eprintfln("[HTTP/2] WINDOW_UPDATE on non-existent stream %d", header.stream_id)
			return false
		}

		err := stream_recv_window_update(stream, increment)
		if err != .None {
			fmt.eprintfln("[HTTP/2] Stream WINDOW_UPDATE error: %v", err)
			return false
		}

		// Resume sending queued data on this stream
		protocol_handler_resume_stream_send(handler, header.stream_id)
	}

	return true
}

// protocol_handler_handle_rst_stream processes a RST_STREAM frame
protocol_handler_handle_rst_stream :: proc(handler: ^Protocol_Handler, header: ^Frame_Header, payload: []byte) -> bool {
	if handler == nil {
		return false
	}

	// RST_STREAM must be on a stream
	if header.stream_id == 0 {
		fmt.eprintln("[HTTP/2] RST_STREAM on stream 0 is invalid")
		protocol_handler_send_goaway(handler, .PROTOCOL_ERROR)
		return false
	}

	// Parse RST_STREAM frame
	rst_frame, parse_err := parse_rst_stream_frame(header^, payload)
	if parse_err != .None {
		fmt.eprintfln("[HTTP/2] Failed to parse RST_STREAM frame: %v", parse_err)
		return false
	}

	// Get stream
	stream, found := connection_get_stream(&handler.conn, header.stream_id)
	if !found {
		// Stream already closed or never existed - this is okay
		return true
	}

	// Process RST_STREAM on the stream
	error_code := u32(rst_frame.error_code)
	stream_err := stream_recv_rst(stream, error_code)
	if stream_err != .None {
		fmt.eprintfln("[HTTP/2] Stream error processing RST_STREAM: %v", stream_err)
		return false
	}

	// Remove the closed stream
	connection_remove_stream(&handler.conn, header.stream_id)

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

// protocol_handler_send_response sends an HTTP/2 response with flow control
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

	// Send HEADERS frame (headers don't consume flow control)
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

	// Send DATA frames with flow control
	body_data := resp.body
	bytes_sent := 0
	max_frame_size := settings_get_remote_max_frame_size(&handler.conn.settings)

	for bytes_sent < len(body_data) {
		remaining := len(body_data) - bytes_sent

		// Calculate how much we can send in this frame
		// Limited by: stream window, connection window, and max frame size
		available_stream := stream.remote_window_size
		available_conn := handler.conn.remote_connection_window
		available := min(available_stream, available_conn)
		available = min(available, i32(max_frame_size))
		available = min(available, i32(remaining))

		if available <= 0 {
			// No flow control window available - queue remaining data
			remaining_data := body_data[bytes_sent:]
			stream.pending_send_data = make([]byte, len(remaining_data), handler.allocator)
			copy(stream.pending_send_data, remaining_data)
			stream.pending_send_end_stream = true  // Remember to send END_STREAM when done
			fmt.eprintfln("[HTTP/2] Flow control exhausted, queued %d bytes for later", len(remaining_data))
			break
		}

		chunk_size := int(available)
		chunk := body_data[bytes_sent:bytes_sent + chunk_size]
		is_last_frame := (bytes_sent + chunk_size) >= len(body_data)

		// Send DATA frame
		flags := u8(0)
		if is_last_frame {
			flags = 0x01  // END_STREAM
		}

		data_header := Frame_Header{
			length = u32(chunk_size),
			type = .DATA,
			flags = flags,
			stream_id = stream_id,
		}
		protocol_handler_write_frame_header(handler, &data_header)
		append(&handler.write_buffer, ..chunk)

		// Consume flow control windows
		stream.remote_window_size -= i32(chunk_size)
		handler.conn.remote_connection_window -= i32(chunk_size)

		// Update stream state
		stream_send_data(stream, chunk_size, is_last_frame)

		bytes_sent += chunk_size
	}
}

// protocol_handler_resume_stream_send resumes sending queued data after WINDOW_UPDATE
protocol_handler_resume_stream_send :: proc(handler: ^Protocol_Handler, stream_id: u32) {
	stream, found := connection_get_stream(&handler.conn, stream_id)
	if !found || stream.pending_send_data == nil || len(stream.pending_send_data) == 0 {
		return
	}

	// Try to send queued data
	body_data := stream.pending_send_data
	bytes_sent := 0
	max_frame_size := settings_get_remote_max_frame_size(&handler.conn.settings)

	for bytes_sent < len(body_data) {
		remaining := len(body_data) - bytes_sent

		// Calculate how much we can send
		available_stream := stream.remote_window_size
		available_conn := handler.conn.remote_connection_window
		available := min(available_stream, available_conn)
		available = min(available, i32(max_frame_size))
		available = min(available, i32(remaining))

		if available <= 0 {
			// Still no window - keep data queued
			if bytes_sent > 0 {
				// Sent some data, update queue
				remaining_data := body_data[bytes_sent:]
				new_pending := make([]byte, len(remaining_data), handler.allocator)
				copy(new_pending, remaining_data)
				delete(stream.pending_send_data)
				stream.pending_send_data = new_pending
			}
			return
		}

		chunk_size := int(available)
		chunk := body_data[bytes_sent:bytes_sent + chunk_size]
		is_last_frame := (bytes_sent + chunk_size) >= len(body_data)

		// Send DATA frame
		flags := u8(0)
		if is_last_frame && stream.pending_send_end_stream {
			flags = 0x01  // END_STREAM
		}

		data_header := Frame_Header{
			length = u32(chunk_size),
			type = .DATA,
			flags = flags,
			stream_id = stream_id,
		}
		protocol_handler_write_frame_header(handler, &data_header)
		append(&handler.write_buffer, ..chunk)

		// Consume flow control windows
		stream.remote_window_size -= i32(chunk_size)
		handler.conn.remote_connection_window -= i32(chunk_size)

		// Update stream state
		stream_send_data(stream, chunk_size, is_last_frame && stream.pending_send_end_stream)

		bytes_sent += chunk_size
	}

	// All queued data sent - clear the queue
	delete(stream.pending_send_data)
	stream.pending_send_data = nil
	stream.pending_send_end_stream = false
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

// protocol_handler_send_window_update sends a WINDOW_UPDATE frame
protocol_handler_send_window_update :: proc(handler: ^Protocol_Handler, stream_id: u32, increment: i32) {
	if handler == nil || increment <= 0 {
		return
	}

	header := Frame_Header{
		length = 4,
		type = .WINDOW_UPDATE,
		flags = 0,
		stream_id = stream_id,
	}
	protocol_handler_write_frame_header(handler, &header)

	// Write window size increment (4 bytes, big-endian, reserved bit cleared)
	increment_u32 := u32(increment) & STREAM_ID_MASK
	increment_bytes := [4]u8{
		u8(increment_u32 >> 24),
		u8(increment_u32 >> 16),
		u8(increment_u32 >> 8),
		u8(increment_u32),
	}
	append(&handler.write_buffer, ..increment_bytes[:])
}

// protocol_handler_send_rst_stream sends a RST_STREAM frame
protocol_handler_send_rst_stream :: proc(handler: ^Protocol_Handler, stream_id: u32, error_code: Error_Code) {
	if handler == nil || stream_id == 0 {
		return
	}

	header := Frame_Header{
		length = 4,
		type = .RST_STREAM,
		flags = 0,
		stream_id = stream_id,
	}
	protocol_handler_write_frame_header(handler, &header)

	// Write error code (4 bytes, big-endian)
	error_u32 := u32(error_code)
	error_bytes := [4]u8{
		u8(error_u32 >> 24),
		u8(error_u32 >> 16),
		u8(error_u32 >> 8),
		u8(error_u32),
	}
	append(&handler.write_buffer, ..error_bytes[:])
}

// protocol_handler_send_goaway sends a GOAWAY frame
protocol_handler_send_goaway :: proc(handler: ^Protocol_Handler, error_code: Error_Code, debug_data: []byte = nil) {
	if handler == nil {
		return
	}

	// Use last_stream_id from connection
	last_stream_id := handler.conn.last_stream_id

	// Calculate frame length
	frame_length := u32(8)  // last_stream_id (4) + error_code (4)
	if debug_data != nil {
		frame_length += u32(len(debug_data))
	}

	header := Frame_Header{
		length = frame_length,
		type = .GOAWAY,
		flags = 0,
		stream_id = 0,  // GOAWAY is always on connection (stream 0)
	}
	protocol_handler_write_frame_header(handler, &header)

	// Write last stream ID (4 bytes, big-endian, reserved bit cleared)
	last_stream := last_stream_id & STREAM_ID_MASK
	last_stream_bytes := [4]u8{
		u8(last_stream >> 24),
		u8(last_stream >> 16),
		u8(last_stream >> 8),
		u8(last_stream),
	}
	append(&handler.write_buffer, ..last_stream_bytes[:])

	// Write error code (4 bytes, big-endian)
	error_u32 := u32(error_code)
	error_bytes := [4]u8{
		u8(error_u32 >> 24),
		u8(error_u32 >> 16),
		u8(error_u32 >> 8),
		u8(error_u32),
	}
	append(&handler.write_buffer, ..error_bytes[:])

	// Write debug data if provided
	if debug_data != nil && len(debug_data) > 0 {
		append(&handler.write_buffer, ..debug_data)
	}

	// Mark connection as going away
	connection_send_goaway(&handler.conn, error_code)
}

// protocol_handler_replenish_windows checks and replenishes flow control windows
// Returns true if windows were replenished
protocol_handler_replenish_windows :: proc(handler: ^Protocol_Handler, stream_id: u32) -> bool {
	if handler == nil {
		return false
	}

	sent_update := false
	initial_window := i32(DEFAULT_INITIAL_WINDOW_SIZE)

	// Replenish connection-level window if below 50%
	conn_threshold := initial_window / 2
	if handler.conn.connection_window < conn_threshold {
		increment := initial_window - handler.conn.connection_window
		err := connection_update_window(&handler.conn, increment)
		if err == .None {
			protocol_handler_send_window_update(handler, 0, increment)  // stream_id 0 = connection-level
			sent_update = true
		}
	}

	// Replenish stream-level window if below 50%
	stream, found := connection_get_stream(&handler.conn, stream_id)
	if found {
		stream_threshold := initial_window / 2
		if stream.window_size < stream_threshold {
			increment := initial_window - stream.window_size
			err := stream_send_window_update(stream, increment)
			if err == .None {
				protocol_handler_send_window_update(handler, stream_id, increment)
				sent_update = true
			}
		}
	}

	return sent_update
}
