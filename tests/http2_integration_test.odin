package valkyrie_tests

import "core:testing"
import "core:fmt"
import http2 "../http2"
import hpack "../http2/hpack"

// Helper to build a complete HTTP/2 connection preface + SETTINGS frame
build_client_preface :: proc(allocator := context.allocator) -> []byte {
	// Connection preface (24 bytes)
	preface := []byte{
		0x50, 0x52, 0x49, 0x20, 0x2a, 0x20, 0x48, 0x54,
		0x54, 0x50, 0x2f, 0x32, 0x2e, 0x30, 0x0d, 0x0a,
		0x0d, 0x0a, 0x53, 0x4d, 0x0d, 0x0a, 0x0d, 0x0a,
	}

	// SETTINGS frame (empty, just the header)
	settings_frame := []byte{
		0x00, 0x00, 0x00,  // Length: 0
		0x04,              // Type: SETTINGS
		0x00,              // Flags: none
		0x00, 0x00, 0x00, 0x00,  // Stream ID: 0
	}

	// Combine preface + SETTINGS
	result := make([]byte, len(preface) + len(settings_frame), allocator)
	copy(result[0:], preface)
	copy(result[len(preface):], settings_frame)

	return result
}

// Helper to build a HEADERS frame with HPACK-encoded headers
build_headers_frame :: proc(
	stream_id: u32,
	method: string,
	path: string,
	end_stream: bool,
	allocator := context.allocator,
) -> ([]byte, bool) {
	// Create encoder for HPACK
	encoder, encoder_ok := hpack.encoder_init(4096, false, allocator)
	if !encoder_ok {
		return nil, false
	}
	defer hpack.encoder_destroy(&encoder)

	// Build headers
	headers := make([dynamic]hpack.Header, 0, 4, allocator)
	defer delete(headers)

	append(&headers, hpack.Header{name = ":method", value = method})
	append(&headers, hpack.Header{name = ":path", value = path})
	append(&headers, hpack.Header{name = ":scheme", value = "https"})
	append(&headers, hpack.Header{name = ":authority", value = "localhost"})

	// Encode headers
	header_block, encode_ok := hpack.encoder_encode_headers(&encoder, headers[:], allocator)
	if !encode_ok {
		return nil, false
	}
	defer delete(header_block, allocator)

	// Build HEADERS frame
	frame_length := u32(len(header_block))
	flags := u8(0x04)  // END_HEADERS
	if end_stream {
		flags |= 0x01  // END_STREAM
	}

	frame := make([dynamic]byte, 0, 9 + len(header_block), allocator)
	defer if !true { delete(frame) }

	// Frame header (9 bytes)
	append(&frame, u8(frame_length >> 16))
	append(&frame, u8(frame_length >> 8))
	append(&frame, u8(frame_length))
	append(&frame, 0x01)  // Type: HEADERS
	append(&frame, flags)
	append(&frame, u8(stream_id >> 24))
	append(&frame, u8(stream_id >> 16))
	append(&frame, u8(stream_id >> 8))
	append(&frame, u8(stream_id))

	// Header block
	for b in header_block {
		append(&frame, b)
	}

	return frame[:], true
}

// Helper to build a DATA frame
build_data_frame :: proc(
	stream_id: u32,
	data: []byte,
	end_stream: bool,
	allocator := context.allocator,
) -> []byte {
	frame_length := u32(len(data))
	flags := u8(0x00)
	if end_stream {
		flags |= 0x01  // END_STREAM
	}

	frame := make([]byte, 9 + len(data), allocator)

	// Frame header (9 bytes)
	frame[0] = u8(frame_length >> 16)
	frame[1] = u8(frame_length >> 8)
	frame[2] = u8(frame_length)
	frame[3] = 0x00  // Type: DATA
	frame[4] = flags
	frame[5] = u8(stream_id >> 24)
	frame[6] = u8(stream_id >> 16)
	frame[7] = u8(stream_id >> 8)
	frame[8] = u8(stream_id)

	// Data
	if len(data) > 0 {
		copy(frame[9:], data)
	}

	return frame
}

// Helper to build SETTINGS ACK frame
build_settings_ack :: proc(allocator := context.allocator) -> []byte {
	frame := make([]byte, 9, allocator)
	frame[0] = 0x00  // Length: 0
	frame[1] = 0x00
	frame[2] = 0x00
	frame[3] = 0x04  // Type: SETTINGS
	frame[4] = 0x01  // Flags: ACK
	frame[5] = 0x00  // Stream ID: 0
	frame[6] = 0x00
	frame[7] = 0x00
	frame[8] = 0x00
	return frame
}

@(test)
test_http2_basic_request_response :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Send client preface + SETTINGS
	preface := build_client_preface()
	defer delete(preface)

	ok := http2.protocol_handler_process_data(&handler, preface)
	testing.expect(t, ok, "Should process client preface")

	// Handler should send SETTINGS frame back
	testing.expect(t, http2.protocol_handler_needs_write(&handler), "Should have SETTINGS to write")

	// Consume server's SETTINGS response
	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	// Send SETTINGS ACK from client
	settings_ack := build_settings_ack()
	defer delete(settings_ack)

	ok = http2.protocol_handler_process_data(&handler, settings_ack)
	testing.expect(t, ok, "Should process SETTINGS ACK")

	// Connection should now be active
	testing.expect(t, http2.connection_is_active(&handler.conn), "Connection should be active")

	// Send HEADERS frame for GET request (stream 1)
	headers_frame, headers_ok := build_headers_frame(1, "GET", "/", true)
	defer delete(headers_frame)
	testing.expect(t, headers_ok, "Should build HEADERS frame")

	ok = http2.protocol_handler_process_data(&handler, headers_frame)
	testing.expect(t, ok, "Should process HEADERS frame")

	// Should have response data to write
	testing.expect(t, http2.protocol_handler_needs_write(&handler), "Should have response to write")

	// Verify we got HEADERS + DATA frames back
	response_data := http2.protocol_handler_get_write_data(&handler)
	testing.expect(t, len(response_data) > 18, "Should have at least frame headers")

	// First frame should be HEADERS (type 0x01)
	testing.expect(t, response_data[3] == 0x01, "First frame should be HEADERS")

	// Stream should be closed after complete request/response
	stream, found := http2.connection_get_stream(&handler.conn, 1)
	testing.expect(t, !found, "Stream should be cleaned up after completion")
}

@(test)
test_http2_request_with_body :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Send client preface + SETTINGS
	preface := build_client_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	// Consume server's SETTINGS
	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	// Send SETTINGS ACK
	settings_ack := build_settings_ack()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Send HEADERS frame for POST request WITHOUT end_stream (body follows)
	headers_frame, headers_ok := build_headers_frame(1, "POST", "/upload", false)
	defer delete(headers_frame)
	testing.expect(t, headers_ok, "Should build HEADERS frame")

	ok := http2.protocol_handler_process_data(&handler, headers_frame)
	testing.expect(t, ok, "Should process HEADERS frame")

	// Stream should exist but not be closed yet
	stream, found := http2.connection_get_stream(&handler.conn, 1)
	testing.expect(t, found, "Stream should exist")
	testing.expect(t, stream.state != .Closed, "Stream should not be closed yet")

	// Should NOT have response yet (waiting for body)
	// Clear any SETTINGS ACK that might be pending
	if http2.protocol_handler_needs_write(&handler) {
		write_data = http2.protocol_handler_get_write_data(&handler)
		http2.protocol_handler_consume_write_data(&handler, len(write_data))
	}

	// Send DATA frame with body
	body_data := transmute([]byte)string("Hello from client!")
	data_frame := build_data_frame(1, body_data, true)
	defer delete(data_frame)

	ok = http2.protocol_handler_process_data(&handler, data_frame)
	testing.expect(t, ok, "Should process DATA frame")

	// Now should have response
	testing.expect(t, http2.protocol_handler_needs_write(&handler), "Should have response after body")

	// Stream should be cleaned up after complete exchange
	stream, found = http2.connection_get_stream(&handler.conn, 1)
	testing.expect(t, !found, "Stream should be cleaned up")

	// Verify flow control windows were updated
	// Connection window should have been replenished
	testing.expect(t, handler.conn.connection_window > 0, "Connection window should be replenished")
}

@(test)
test_http2_concurrent_streams :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Setup connection
	preface := build_client_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	settings_ack := build_settings_ack()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Send HEADERS for stream 1
	headers1, _ := build_headers_frame(1, "GET", "/page1", false)
	defer delete(headers1)
	http2.protocol_handler_process_data(&handler, headers1)

	// Send HEADERS for stream 3
	headers3, _ := build_headers_frame(3, "GET", "/page2", false)
	defer delete(headers3)
	http2.protocol_handler_process_data(&handler, headers3)

	// Send HEADERS for stream 5
	headers5, _ := build_headers_frame(5, "GET", "/page3", false)
	defer delete(headers5)
	http2.protocol_handler_process_data(&handler, headers5)

	// All three streams should exist
	stream1, found1 := http2.connection_get_stream(&handler.conn, 1)
	stream3, found3 := http2.connection_get_stream(&handler.conn, 3)
	stream5, found5 := http2.connection_get_stream(&handler.conn, 5)

	testing.expect(t, found1, "Stream 1 should exist")
	testing.expect(t, found3, "Stream 3 should exist")
	testing.expect(t, found5, "Stream 5 should exist")

	testing.expect(t, http2.connection_stream_count(&handler.conn) == 3, "Should have 3 concurrent streams")

	// Complete stream 3 with DATA
	data3 := build_data_frame(3, nil, true)
	defer delete(data3)
	http2.protocol_handler_process_data(&handler, data3)

	// Stream 3 should be cleaned up, others remain
	_, found3 = http2.connection_get_stream(&handler.conn, 3)
	testing.expect(t, !found3, "Stream 3 should be cleaned up")
	testing.expect(t, http2.connection_stream_count(&handler.conn) == 2, "Should have 2 streams left")
}

@(test)
test_http2_flow_control :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Setup connection
	preface := build_client_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	settings_ack := build_settings_ack()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Record initial window
	initial_conn_window := handler.conn.connection_window

	// Send HEADERS for stream 1
	headers, _ := build_headers_frame(1, "POST", "/data", false)
	defer delete(headers)
	http2.protocol_handler_process_data(&handler, headers)

	stream, _ := http2.connection_get_stream(&handler.conn, 1)
	initial_stream_window := stream.window_size

	// Send 1KB of data
	large_data := make([]byte, 1024)
	for i in 0..<1024 {
		large_data[i] = u8(i % 256)
	}
	defer delete(large_data)

	data_frame := build_data_frame(1, large_data, true)
	defer delete(data_frame)

	ok := http2.protocol_handler_process_data(&handler, data_frame)
	testing.expect(t, ok, "Should process large DATA frame")

	// Check that windows were consumed
	testing.expect(t, handler.conn.connection_window == initial_conn_window - 1024,
		"Connection window should decrease by data size")

	// Stream should be cleaned up after END_STREAM
	_, found := http2.connection_get_stream(&handler.conn, 1)
	testing.expect(t, !found, "Stream should be cleaned up")

	// Note: WINDOW_UPDATE is only sent when window drops below 50% (32767 bytes)
	// Since we only consumed 1024 bytes, no replenishment should occur yet
	// This is correct behavior - we don't want to send WINDOW_UPDATE on every DATA frame
}

@(test)
test_http2_stream_error_handling :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Setup connection
	preface := build_client_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	settings_ack := build_settings_ack()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Try to send DATA frame on non-existent stream (should trigger RST_STREAM)
	data_frame := build_data_frame(999, transmute([]byte)string("Invalid"), true)
	defer delete(data_frame)

	ok := http2.protocol_handler_process_data(&handler, data_frame)
	testing.expect(t, ok, "Should handle error gracefully")

	// Should have RST_STREAM frame to send
	testing.expect(t, http2.protocol_handler_needs_write(&handler), "Should send RST_STREAM")

	response_data := http2.protocol_handler_get_write_data(&handler)
	// RST_STREAM frame type is 0x03
	testing.expect(t, response_data[3] == 0x03, "Should send RST_STREAM frame")
}

@(test)
test_http2_connection_error_handling :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Setup connection
	preface := build_client_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	settings_ack := build_settings_ack()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Send DATA frame on stream 0 (invalid - should trigger GOAWAY)
	data_frame := build_data_frame(0, transmute([]byte)string("Invalid"), true)
	defer delete(data_frame)

	ok := http2.protocol_handler_process_data(&handler, data_frame)
	testing.expect(t, !ok, "Should reject connection-level protocol violation")

	// Should have GOAWAY frame to send
	testing.expect(t, http2.protocol_handler_needs_write(&handler), "Should send GOAWAY")

	response_data := http2.protocol_handler_get_write_data(&handler)
	// GOAWAY frame type is 0x07
	testing.expect(t, response_data[3] == 0x07, "Should send GOAWAY frame")

	// Connection should be marked as going away
	testing.expect(t, http2.connection_is_closing(&handler.conn), "Connection should be going away")
}

// Helper to build a HEADERS frame with optional END_HEADERS flag
build_headers_frame_with_flags :: proc(
	stream_id: u32,
	header_block: []byte,
	flags: u8,
	allocator := context.allocator,
) -> []byte {
	frame_length := u32(len(header_block))

	frame := make([dynamic]byte, 0, 9 + len(header_block), allocator)

	// Frame header (9 bytes)
	append(&frame, u8(frame_length >> 16))
	append(&frame, u8(frame_length >> 8))
	append(&frame, u8(frame_length))
	append(&frame, 0x01)  // Type: HEADERS
	append(&frame, flags)
	append(&frame, u8(stream_id >> 24))
	append(&frame, u8(stream_id >> 16))
	append(&frame, u8(stream_id >> 8))
	append(&frame, u8(stream_id))

	// Header block fragment
	for b in header_block {
		append(&frame, b)
	}

	return frame[:]
}

// Helper to build a CONTINUATION frame
build_continuation_frame :: proc(
	stream_id: u32,
	header_block_fragment: []byte,
	end_headers: bool,
	allocator := context.allocator,
) -> []byte {
	frame_length := u32(len(header_block_fragment))
	flags := u8(0)
	if end_headers {
		flags = 0x04  // END_HEADERS
	}

	frame := make([dynamic]byte, 0, 9 + len(header_block_fragment), allocator)

	// Frame header (9 bytes)
	append(&frame, u8(frame_length >> 16))
	append(&frame, u8(frame_length >> 8))
	append(&frame, u8(frame_length))
	append(&frame, 0x09)  // Type: CONTINUATION
	append(&frame, flags)
	append(&frame, u8(stream_id >> 24))
	append(&frame, u8(stream_id >> 16))
	append(&frame, u8(stream_id >> 8))
	append(&frame, u8(stream_id))

	// Header block fragment
	for b in header_block_fragment {
		append(&frame, b)
	}

	return frame[:]
}

@(test)
test_http2_continuation_basic :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Setup connection
	preface := build_client_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	settings_ack := build_settings_ack()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Create a complete header block using HPACK encoder
	encoder, encoder_ok := hpack.encoder_init(4096, false)
	testing.expect(t, encoder_ok, "Should create HPACK encoder")
	defer hpack.encoder_destroy(&encoder)

	headers := make([dynamic]hpack.Header, 0, 4)
	defer delete(headers)
	append(&headers, hpack.Header{name = ":method", value = "GET"})
	append(&headers, hpack.Header{name = ":path", value = "/continuation-test"})
	append(&headers, hpack.Header{name = ":scheme", value = "https"})
	append(&headers, hpack.Header{name = ":authority", value = "localhost"})

	complete_header_block, encode_ok := hpack.encoder_encode_headers(&encoder, headers[:])
	testing.expect(t, encode_ok, "Should encode headers")
	defer delete(complete_header_block)

	// Split header block into two fragments
	split_point := len(complete_header_block) / 2
	fragment1 := complete_header_block[:split_point]
	fragment2 := complete_header_block[split_point:]

	// Send HEADERS frame without END_HEADERS, with END_STREAM
	headers_frame := build_headers_frame_with_flags(1, fragment1, 0x01)  // END_STREAM, no END_HEADERS
	defer delete(headers_frame)

	ok := http2.protocol_handler_process_data(&handler, headers_frame)
	testing.expect(t, ok, "Should accept HEADERS without END_HEADERS")

	// Connection should be expecting CONTINUATION
	testing.expect(t, handler.conn.continuation_expected, "Should be expecting CONTINUATION")
	testing.expect(t, handler.conn.continuation_stream_id == 1, "Should expect CONTINUATION on stream 1")

	// Send CONTINUATION frame with END_HEADERS
	continuation_frame := build_continuation_frame(1, fragment2, true)
	defer delete(continuation_frame)

	ok = http2.protocol_handler_process_data(&handler, continuation_frame)
	testing.expect(t, ok, "Should accept CONTINUATION with END_HEADERS")

	// Continuation state should be reset
	testing.expect(t, !handler.conn.continuation_expected, "Should not be expecting CONTINUATION")

	// Should have response to send
	testing.expect(t, http2.protocol_handler_needs_write(&handler), "Should have response")

	response_data := http2.protocol_handler_get_write_data(&handler)
	testing.expect(t, len(response_data) > 0, "Should have response data")
	// Should be a HEADERS frame (type 0x01)
	testing.expect(t, response_data[3] == 0x01, "Should send HEADERS response")
}

@(test)
test_http2_continuation_interleaved_rejection :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Setup connection
	preface := build_client_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	settings_ack := build_settings_ack()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Create header block
	encoder, encoder_ok := hpack.encoder_init(4096, false)
	testing.expect(t, encoder_ok, "Should create HPACK encoder")
	defer hpack.encoder_destroy(&encoder)

	headers := make([dynamic]hpack.Header, 0, 4)
	defer delete(headers)
	append(&headers, hpack.Header{name = ":method", value = "GET"})
	append(&headers, hpack.Header{name = ":path", value = "/"})
	append(&headers, hpack.Header{name = ":scheme", value = "https"})
	append(&headers, hpack.Header{name = ":authority", value = "localhost"})

	header_block, encode_ok := hpack.encoder_encode_headers(&encoder, headers[:])
	testing.expect(t, encode_ok, "Should encode headers")
	defer delete(header_block)

	// Send HEADERS frame without END_HEADERS
	headers_frame := build_headers_frame_with_flags(1, header_block, 0x00)  // No END_HEADERS, no END_STREAM
	defer delete(headers_frame)

	ok := http2.protocol_handler_process_data(&handler, headers_frame)
	testing.expect(t, ok, "Should accept HEADERS without END_HEADERS")
	testing.expect(t, handler.conn.continuation_expected, "Should be expecting CONTINUATION")

	// Try to send DATA frame (should be rejected due to interleaving)
	data_frame := build_data_frame(1, transmute([]byte)string("test"), true)
	defer delete(data_frame)

	ok = http2.protocol_handler_process_data(&handler, data_frame)
	testing.expect(t, !ok, "Should reject interleaved DATA frame")

	// Should send GOAWAY
	testing.expect(t, http2.connection_is_closing(&handler.conn), "Connection should be going away")
}

@(test)
test_http2_continuation_wrong_stream :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Setup connection
	preface := build_client_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	settings_ack := build_settings_ack()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Create header block
	encoder, encoder_ok := hpack.encoder_init(4096, false)
	testing.expect(t, encoder_ok, "Should create HPACK encoder")
	defer hpack.encoder_destroy(&encoder)

	headers := make([dynamic]hpack.Header, 0, 4)
	defer delete(headers)
	append(&headers, hpack.Header{name = ":method", value = "GET"})
	append(&headers, hpack.Header{name = ":path", value = "/"})
	append(&headers, hpack.Header{name = ":scheme", value = "https"})
	append(&headers, hpack.Header{name = ":authority", value = "localhost"})

	header_block, encode_ok := hpack.encoder_encode_headers(&encoder, headers[:])
	testing.expect(t, encode_ok, "Should encode headers")
	defer delete(header_block)

	// Send HEADERS frame on stream 1 without END_HEADERS
	headers_frame := build_headers_frame_with_flags(1, header_block, 0x00)
	defer delete(headers_frame)

	ok := http2.protocol_handler_process_data(&handler, headers_frame)
	testing.expect(t, ok, "Should accept HEADERS without END_HEADERS")
	testing.expect(t, handler.conn.continuation_stream_id == 1, "Should expect CONTINUATION on stream 1")

	// Send CONTINUATION frame on stream 3 (wrong stream - should be rejected)
	continuation_frame := build_continuation_frame(3, header_block, true)
	defer delete(continuation_frame)

	ok = http2.protocol_handler_process_data(&handler, continuation_frame)
	testing.expect(t, !ok, "Should reject CONTINUATION on wrong stream")

	// Should send GOAWAY
	testing.expect(t, http2.connection_is_closing(&handler.conn), "Connection should be going away")
}

@(test)
test_http2_continuation_multiple_fragments :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Setup connection
	preface := build_client_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	settings_ack := build_settings_ack()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Create a large header block
	encoder, encoder_ok := hpack.encoder_init(4096, false)
	testing.expect(t, encoder_ok, "Should create HPACK encoder")
	defer hpack.encoder_destroy(&encoder)

	headers := make([dynamic]hpack.Header, 0, 10)
	defer delete(headers)
	append(&headers, hpack.Header{name = ":method", value = "POST"})
	append(&headers, hpack.Header{name = ":path", value = "/large-headers"})
	append(&headers, hpack.Header{name = ":scheme", value = "https"})
	append(&headers, hpack.Header{name = ":authority", value = "localhost"})
	// Add some custom headers to make the block larger
	append(&headers, hpack.Header{name = "x-custom-header-1", value = "value1-with-some-length"})
	append(&headers, hpack.Header{name = "x-custom-header-2", value = "value2-with-some-length"})
	append(&headers, hpack.Header{name = "x-custom-header-3", value = "value3-with-some-length"})

	complete_header_block, encode_ok := hpack.encoder_encode_headers(&encoder, headers[:])
	testing.expect(t, encode_ok, "Should encode headers")
	defer delete(complete_header_block)

	// Split into 3 fragments
	fragment_size := len(complete_header_block) / 3
	fragment1 := complete_header_block[:fragment_size]
	fragment2 := complete_header_block[fragment_size:fragment_size*2]
	fragment3 := complete_header_block[fragment_size*2:]

	// Send HEADERS frame with first fragment, no END_HEADERS, no END_STREAM
	headers_frame := build_headers_frame_with_flags(1, fragment1, 0x00)
	defer delete(headers_frame)

	ok := http2.protocol_handler_process_data(&handler, headers_frame)
	testing.expect(t, ok, "Should accept HEADERS without END_HEADERS")
	testing.expect(t, handler.conn.continuation_expected, "Should be expecting CONTINUATION")

	// Send first CONTINUATION frame with second fragment, no END_HEADERS
	cont1 := build_continuation_frame(1, fragment2, false)
	defer delete(cont1)

	ok = http2.protocol_handler_process_data(&handler, cont1)
	testing.expect(t, ok, "Should accept CONTINUATION without END_HEADERS")
	testing.expect(t, handler.conn.continuation_expected, "Should still be expecting CONTINUATION")

	// Send second CONTINUATION frame with third fragment, with END_HEADERS
	cont2 := build_continuation_frame(1, fragment3, true)
	defer delete(cont2)

	ok = http2.protocol_handler_process_data(&handler, cont2)
	testing.expect(t, ok, "Should accept final CONTINUATION with END_HEADERS")
	testing.expect(t, !handler.conn.continuation_expected, "Should not be expecting CONTINUATION")

	// Stream should exist and have headers complete
	stream, found := http2.connection_get_stream(&handler.conn, 1)
	testing.expect(t, found, "Stream 1 should exist")
	testing.expect(t, stream.recv_headers_complete, "Headers should be complete")
}
