package valkyrie_tests

import "core:testing"
import "core:fmt"
import http2 "../http2"
import hpack "../http2/hpack"

// Helper to build a complete HTTP/2 connection preface + SETTINGS frame
build_preface :: proc(allocator := context.allocator) -> []byte {
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

// Helper to build a HEADERS frame
build_headers :: proc(
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

// Helper to build SETTINGS ACK
build_settings_ack_frame :: proc(allocator := context.allocator) -> []byte {
	frame := make([]byte, 9, allocator)
	frame[0] = 0x00  // Length: 0 (high)
	frame[1] = 0x00  // Length: 0 (mid)
	frame[2] = 0x00  // Length: 0 (low)
	frame[3] = 0x04  // Type: SETTINGS
	frame[4] = 0x01  // Flags: ACK
	frame[5] = 0x00  // Stream ID: 0 (high)
	frame[6] = 0x00  // Stream ID: 0
	frame[7] = 0x00  // Stream ID: 0
	frame[8] = 0x00  // Stream ID: 0 (low)
	return frame
}

@(test)
test_max_concurrent_streams_enforcement :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Setup connection
	preface := build_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	settings_ack := build_settings_ack_frame()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Set a low MAX_CONCURRENT_STREAMS limit
	max_streams := u32(5)
	handler.conn.settings.local_max_concurrent_streams = max_streams

	// Create max_streams streams successfully
	for i in 0..<max_streams {
		stream_id := u32(i * 2 + 1)  // Odd stream IDs: 1, 3, 5, 7, 9
		headers_frame, ok := build_headers(stream_id, "GET", fmt.tprintf("/stream-%d", i), false)
		testing.expect(t, ok, "Should build headers frame")
		defer delete(headers_frame)

		http2.protocol_handler_process_data(&handler, headers_frame)
	}

	// Verify we have max_streams streams
	stream_count := http2.connection_stream_count(&handler.conn)
	testing.expect(t, stream_count == int(max_streams), fmt.tprintf("Should have %d streams", max_streams))

	// Try to create one more stream (should be rejected)
	overflow_stream_id := u32(max_streams * 2 + 1)
	headers_frame, ok := build_headers(overflow_stream_id, "GET", "/overflow", false)
	testing.expect(t, ok, "Should build headers frame")
	defer delete(headers_frame)

	http2.protocol_handler_process_data(&handler, headers_frame)

	// Should have sent RST_STREAM (REFUSED_STREAM)
	testing.expect(t, http2.protocol_handler_needs_write(&handler), "Should send RST_STREAM")

	response_data := http2.protocol_handler_get_write_data(&handler)
	// Look for RST_STREAM frame (type 0x03)
	if len(response_data) >= 9 {
		testing.expect(t, response_data[3] == 0x03, "Should send RST_STREAM for overflow")
	}

	// Stream count should still be max_streams (overflow rejected)
	final_count := http2.connection_stream_count(&handler.conn)
	testing.expect(t, final_count == int(max_streams), fmt.tprintf("Should still have %d streams", max_streams))
}

@(test)
test_multiple_concurrent_streams :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Setup connection
	preface := build_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	settings_ack := build_settings_ack_frame()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Create 10 concurrent streams
	num_streams := 10
	for i in 0..<num_streams {
		stream_id := u32(i * 2 + 1)
		headers_frame, ok := build_headers(stream_id, "GET", fmt.tprintf("/stream-%d", i), true)
		testing.expect(t, ok, "Should build headers frame")
		defer delete(headers_frame)

		http2.protocol_handler_process_data(&handler, headers_frame)
	}

	// Should have responses for all streams
	testing.expect(t, http2.protocol_handler_needs_write(&handler), "Should have responses")

	response_data := http2.protocol_handler_get_write_data(&handler)

	// Parse all response frames and count streams
	offset := 0
	streams_responded := make(map[u32]bool)
	defer delete(streams_responded)

	for offset + 9 <= len(response_data) {
		frame_len := int(response_data[offset]) << 16 | int(response_data[offset + 1]) << 8 | int(response_data[offset + 2])
		stream_id := u32(response_data[offset + 5]) << 24 | u32(response_data[offset + 6]) << 16 |
		              u32(response_data[offset + 7]) << 8 | u32(response_data[offset + 8])

		if offset + 9 + frame_len > len(response_data) {
			break
		}

		// Track which streams got responses (stream ID > 0)
		if stream_id > 0 {
			streams_responded[stream_id] = true
		}

		offset += 9 + frame_len
	}

	// Should have responses for all 10 streams
	testing.expect(t, len(streams_responded) == num_streams,
		fmt.tprintf("Should have responses for %d streams, got %d", num_streams, len(streams_responded)))
}

@(test)
test_per_stream_flow_control_isolation :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Setup connection
	preface := build_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	settings_ack := build_settings_ack_frame()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Create two streams with different window sizes
	stream1, _ := http2.connection_create_stream(&handler.conn, 1)
	stream2, _ := http2.connection_create_stream(&handler.conn, 3)

	stream1.remote_window_size = 100  // Stream 1 has 100 bytes
	stream2.remote_window_size = 500  // Stream 2 has 500 bytes

	initial_conn_window := handler.conn.remote_connection_window

	// Send request on stream 1 with a long path to generate larger response
	long_path1 := "/stream1-with-a-very-long-path-name-to-generate-a-response-that-is-large-enough-to-test-flow-control-windows-properly-and-ensure-that-the-response-exceeds-the-smaller-window-size"
	headers1, ok1 := build_headers(1, "GET", long_path1, true)
	testing.expect(t, ok1, "Should build headers for stream 1")
	defer delete(headers1)
	http2.protocol_handler_process_data(&handler, headers1)

	// Send request on stream 2 with an even longer path
	long_path2 := "/stream2-with-an-extremely-long-path-name-to-generate-a-much-larger-response-body-that-will-definitely-exceed-the-window-size-for-stream1-but-should-fit-within-stream2s-larger-window-allowing-us-to-properly-test-per-stream-flow-control-isolation-between-multiple-concurrent-streams"
	headers2, ok2 := build_headers(3, "GET", long_path2, true)
	testing.expect(t, ok2, "Should build headers for stream 2")
	defer delete(headers2)
	http2.protocol_handler_process_data(&handler, headers2)

	// Get responses
	response_data := http2.protocol_handler_get_write_data(&handler)

	// Parse responses and verify window consumption per stream
	offset := 0
	stream1_data := 0
	stream2_data := 0

	for offset + 9 <= len(response_data) {
		frame_len := int(response_data[offset]) << 16 | int(response_data[offset + 1]) << 8 | int(response_data[offset + 2])
		frame_type := response_data[offset + 3]
		stream_id := u32(response_data[offset + 5]) << 24 | u32(response_data[offset + 6]) << 16 |
		              u32(response_data[offset + 7]) << 8 | u32(response_data[offset + 8])

		if offset + 9 + frame_len > len(response_data) {
			break
		}

		if frame_type == 0x00 {  // DATA frame
			if stream_id == 1 {
				stream1_data += frame_len
			} else if stream_id == 3 {
				stream2_data += frame_len
			}
		}

		offset += 9 + frame_len
	}

	// Stream 1 should have sent <= 100 bytes (its window)
	testing.expect(t, stream1_data <= 100, fmt.tprintf("Stream 1 should respect 100-byte window, sent %d", stream1_data))

	// Stream 2 should have sent more (has bigger window)
	testing.expect(t, stream2_data > stream1_data, "Stream 2 should send more data (larger window)")

	// Get final stream states
	final_stream1, _ := http2.connection_get_stream(&handler.conn, 1)
	final_stream2, _ := http2.connection_get_stream(&handler.conn, 3)

	// Windows should be consumed independently
	stream1_consumed := 100 - final_stream1.remote_window_size
	stream2_consumed := 500 - final_stream2.remote_window_size

	testing.expect(t, stream1_consumed == i32(stream1_data), "Stream 1 window consumption should match data sent")
	testing.expect(t, stream2_consumed == i32(stream2_data), "Stream 2 window consumption should match data sent")

	// Connection window should have consumed total from both streams
	conn_consumed := initial_conn_window - handler.conn.remote_connection_window
	total_data := i32(stream1_data + stream2_data)
	testing.expect(t, conn_consumed == total_data, "Connection window should consume total from all streams")
}

@(test)
test_stream_error_isolation :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Setup connection
	preface := build_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	settings_ack := build_settings_ack_frame()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Create three streams WITHOUT end_stream (so they remain open)
	headers1, ok1 := build_headers(1, "GET", "/stream1", false)
	testing.expect(t, ok1, "Should build headers for stream 1")
	defer delete(headers1)
	http2.protocol_handler_process_data(&handler, headers1)

	headers3, ok3 := build_headers(3, "GET", "/stream3", true)
	testing.expect(t, ok3, "Should build headers for stream 3")
	defer delete(headers3)
	http2.protocol_handler_process_data(&handler, headers3)

	headers5, ok5 := build_headers(5, "GET", "/stream5", false)
	testing.expect(t, ok5, "Should build headers for stream 5")
	defer delete(headers5)
	http2.protocol_handler_process_data(&handler, headers5)

	// Clear responses (stream 3 completes and is removed, streams 1 and 5 remain open)
	http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, 10000)

	// Now send DATA on stream 3 that no longer exists (it completed)
	// This should trigger RST_STREAM on stream 3 only
	bad_data_frame := make([]byte, 18)
	defer delete(bad_data_frame)

	// DATA frame: 9 bytes payload, stream 3, END_STREAM
	bad_data_frame[0] = 0x00  // Length: 9 (high)
	bad_data_frame[1] = 0x00  // Length: 9 (mid)
	bad_data_frame[2] = 0x09  // Length: 9 (low)
	bad_data_frame[3] = 0x00  // Type: DATA
	bad_data_frame[4] = 0x01  // Flags: END_STREAM
	bad_data_frame[5] = 0x00  // Stream ID: 3 (high)
	bad_data_frame[6] = 0x00
	bad_data_frame[7] = 0x00
	bad_data_frame[8] = 0x03  // Stream ID: 3 (low)
	// 9 bytes of data
	for i in 9..<18 {
		bad_data_frame[i] = u8('X')
	}

	http2.protocol_handler_process_data(&handler, bad_data_frame)

	// Should send RST_STREAM for stream 3
	testing.expect(t, http2.protocol_handler_needs_write(&handler), "Should send RST_STREAM")

	error_response := http2.protocol_handler_get_write_data(&handler)

	// Parse response - should be RST_STREAM on stream 3
	if len(error_response) >= 9 {
		frame_type := error_response[3]
		stream_id := u32(error_response[5]) << 24 | u32(error_response[6]) << 16 |
		              u32(error_response[7]) << 8 | u32(error_response[8])

		testing.expect(t, frame_type == 0x03, "Should send RST_STREAM")
		testing.expect(t, stream_id == 3, "RST_STREAM should be for stream 3")
	}

	// Connection should still be active (not going away)
	testing.expect(t, !http2.connection_is_closing(&handler.conn), "Connection should still be active")

	// Streams 1 and 5 should still exist (stream 3 should be removed)
	stream1_exists := false
	stream3_exists := false
	stream5_exists := false

	_, stream1_exists = http2.connection_get_stream(&handler.conn, 1)
	_, stream3_exists = http2.connection_get_stream(&handler.conn, 3)
	_, stream5_exists = http2.connection_get_stream(&handler.conn, 5)

	testing.expect(t, stream1_exists, "Stream 1 should still exist")
	testing.expect(t, !stream3_exists, "Stream 3 should be removed")
	testing.expect(t, stream5_exists, "Stream 5 should still exist")
}

@(test)
test_connection_flow_control_shared :: proc(t: ^testing.T) {
	// Create protocol handler
	handler, handler_ok := http2.protocol_handler_init(true)
	defer http2.protocol_handler_destroy(&handler)
	testing.expect(t, handler_ok, "Should create protocol handler")

	// Setup connection
	preface := build_preface()
	defer delete(preface)
	http2.protocol_handler_process_data(&handler, preface)

	write_data := http2.protocol_handler_get_write_data(&handler)
	http2.protocol_handler_consume_write_data(&handler, len(write_data))

	settings_ack := build_settings_ack_frame()
	defer delete(settings_ack)
	http2.protocol_handler_process_data(&handler, settings_ack)

	// Set connection window to 200 bytes total
	handler.conn.remote_connection_window = 200

	// Create 3 streams, each with large individual windows
	stream1, _ := http2.connection_create_stream(&handler.conn, 1)
	stream2, _ := http2.connection_create_stream(&handler.conn, 3)
	stream3, _ := http2.connection_create_stream(&handler.conn, 5)

	stream1.remote_window_size = 1000
	stream2.remote_window_size = 1000
	stream3.remote_window_size = 1000

	// Send requests on all streams with long paths to generate large responses
	long_path := "/stream-with-a-very-long-path-name-to-generate-large-response-that-exceeds-the-connection-window-limit-and-forces-queueing-of-data-across-multiple-concurrent-streams"
	headers1, _ := build_headers(1, "GET", long_path, true)
	defer delete(headers1)
	http2.protocol_handler_process_data(&handler, headers1)

	headers2, _ := build_headers(3, "GET", long_path, true)
	defer delete(headers2)
	http2.protocol_handler_process_data(&handler, headers2)

	headers3, _ := build_headers(5, "GET", long_path, true)
	defer delete(headers3)
	http2.protocol_handler_process_data(&handler, headers3)

	// Get responses
	response_data := http2.protocol_handler_get_write_data(&handler)

	// Count total DATA sent across all streams
	offset := 0
	total_data_sent := 0

	for offset + 9 <= len(response_data) {
		frame_len := int(response_data[offset]) << 16 | int(response_data[offset + 1]) << 8 | int(response_data[offset + 2])
		frame_type := response_data[offset + 3]

		if offset + 9 + frame_len > len(response_data) {
			break
		}

		if frame_type == 0x00 {  // DATA
			total_data_sent += frame_len
		}

		offset += 9 + frame_len
	}

	// Total DATA should not exceed connection window (200 bytes)
	// Even though each stream has 1000 bytes available
	testing.expect(t, total_data_sent <= 200,
		fmt.tprintf("Total data should respect connection window (200), sent %d", total_data_sent))

	// Connection window should be consumed
	final_conn_window := handler.conn.remote_connection_window
	testing.expect(t, final_conn_window == 200 - i32(total_data_sent),
		"Connection window should be consumed by total data sent")

	// At least some streams should have queued data (couldn't send everything due to conn window)
	final_stream1, found1 := http2.connection_get_stream(&handler.conn, 1)
	final_stream2, found2 := http2.connection_get_stream(&handler.conn, 3)
	final_stream3, found3 := http2.connection_get_stream(&handler.conn, 5)

	queued_count := 0
	if found1 && final_stream1.pending_send_data != nil && len(final_stream1.pending_send_data) > 0 {
		queued_count += 1
	}
	if found2 && final_stream2.pending_send_data != nil && len(final_stream2.pending_send_data) > 0 {
		queued_count += 1
	}
	if found3 && final_stream3.pending_send_data != nil && len(final_stream3.pending_send_data) > 0 {
		queued_count += 1
	}

	// At least some streams should have queued data
	testing.expect(t, queued_count > 0, "Some streams should have queued data due to connection window limit")
}
