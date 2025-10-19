package valkyrie_tests

import "core:testing"
import http2 "../http2"

@(test)
test_http2_connection_init :: proc(t: ^testing.T) {
	conn, ok := http2.connection_init(true)  // Server connection
	defer http2.connection_destroy(&conn)

	testing.expect(t, ok == true, "Should initialize successfully")
	testing.expect(t, conn.state == .Waiting_Preface, "Should start in Waiting_Preface state")
	testing.expect(t, conn.next_stream_id == 2, "Server should use even stream IDs")
	testing.expect(t, conn.preface_received == false, "Preface not received yet")
}

@(test)
test_http2_connection_init_client :: proc(t: ^testing.T) {
	conn, ok := http2.connection_init(false)  // Client connection
	defer http2.connection_destroy(&conn)

	testing.expect(t, ok == true, "Should initialize successfully")
	testing.expect(t, conn.next_stream_id == 1, "Client should use odd stream IDs")
}

@(test)
test_http2_connection_handle_preface_valid :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	preface := []byte{
		0x50, 0x52, 0x49, 0x20, 0x2a, 0x20, 0x48, 0x54,
		0x54, 0x50, 0x2f, 0x32, 0x2e, 0x30, 0x0d, 0x0a,
		0x0d, 0x0a, 0x53, 0x4d, 0x0d, 0x0a, 0x0d, 0x0a,
	}

	err := http2.connection_handle_preface(&conn, preface)
	testing.expect(t, err == .None, "Should accept valid preface")
	testing.expect(t, conn.preface_received == true, "Should mark preface received")
	testing.expect(t, conn.state == .Waiting_Settings, "Should transition to Waiting_Settings")
}

@(test)
test_http2_connection_handle_preface_invalid :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	invalid_preface := []byte{
		0x48, 0x54, 0x54, 0x50, 0x2f, 0x31, 0x2e, 0x31,
		0x20, 0x32, 0x30, 0x30, 0x20, 0x4f, 0x4b, 0x0d,
		0x0a, 0x0d, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00,
	}

	err := http2.connection_handle_preface(&conn, invalid_preface)
	testing.expect(t, err == .Preface_Invalid, "Should reject invalid preface")
	testing.expect(t, conn.preface_received == false, "Should not mark preface received")
}

@(test)
test_http2_connection_handle_settings :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	// Move to Waiting_Settings state
	conn.state = .Waiting_Settings

	// Create SETTINGS frame
	settings_frame, _ := http2.settings_build_frame(&conn.settings)
	defer delete(settings_frame.settings)

	err := http2.connection_handle_settings(&conn, &settings_frame)
	testing.expect(t, err == .None, "Should handle SETTINGS successfully")
	testing.expect(t, conn.state == .Active, "Should transition to Active")
}

@(test)
test_http2_connection_handle_settings_ack :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	conn.state = .Active

	// Create SETTINGS ACK frame
	ack_frame := http2.settings_build_ack_frame()

	err := http2.connection_handle_settings(&conn, &ack_frame)
	testing.expect(t, err == .None, "Should handle SETTINGS ACK successfully")
}

@(test)
test_http2_connection_create_stream :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	conn.state = .Active

	stream, err := http2.connection_create_stream(&conn, 1)
	testing.expect(t, err == .None, "Should create stream successfully")
	testing.expect(t, stream != nil, "Should return valid stream pointer")
	testing.expect(t, stream.id == 1, "Stream should have correct ID")
	testing.expect(t, http2.connection_stream_count(&conn) == 1, "Should have 1 stream")
}

@(test)
test_http2_connection_create_duplicate_stream :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	conn.state = .Active

	// Create first stream
	http2.connection_create_stream(&conn, 1)

	// Try to create duplicate
	_, err := http2.connection_create_stream(&conn, 1)
	testing.expect(t, err == .Stream_Error, "Should reject duplicate stream ID")
}

@(test)
test_http2_connection_get_stream :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	conn.state = .Active

	// Create stream
	http2.connection_create_stream(&conn, 1)

	// Get stream
	stream, found := http2.connection_get_stream(&conn, 1)
	testing.expect(t, found == true, "Should find stream")
	testing.expect(t, stream != nil, "Should return valid stream")
	testing.expect(t, stream.id == 1, "Should have correct ID")

	// Try to get non-existent stream
	_, found2 := http2.connection_get_stream(&conn, 999)
	testing.expect(t, found2 == false, "Should not find non-existent stream")
}

@(test)
test_http2_connection_remove_stream :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	conn.state = .Active

	// Create and remove stream
	http2.connection_create_stream(&conn, 1)
	testing.expect(t, http2.connection_stream_count(&conn) == 1, "Should have 1 stream")

	removed := http2.connection_remove_stream(&conn, 1)
	testing.expect(t, removed == true, "Should remove stream")
	testing.expect(t, http2.connection_stream_count(&conn) == 0, "Should have 0 streams")
}

@(test)
test_http2_connection_handle_ping :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	conn.state = .Active

	ping_frame := http2.Ping_Frame{
		header = http2.Frame_Header{
			length = 8,
			type = .PING,
			flags = 0,
			stream_id = 0,
		},
		opaque_data = [8]byte{1, 2, 3, 4, 5, 6, 7, 8},
	}

	err := http2.connection_handle_ping(&conn, &ping_frame, false)
	testing.expect(t, err == .None, "Should handle PING successfully")
}

@(test)
test_http2_connection_handle_ping_wrong_stream :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	conn.state = .Active

	// PING on non-zero stream is an error
	ping_frame := http2.Ping_Frame{
		header = http2.Frame_Header{
			length = 8,
			type = .PING,
			flags = 0,
			stream_id = 1,  // Invalid
		},
		opaque_data = [8]byte{1, 2, 3, 4, 5, 6, 7, 8},
	}

	err := http2.connection_handle_ping(&conn, &ping_frame, false)
	testing.expect(t, err == .Protocol_Error, "Should reject PING on non-zero stream")
}

@(test)
test_http2_connection_handle_goaway :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	conn.state = .Active

	// Create some streams
	http2.connection_create_stream(&conn, 1)
	http2.connection_create_stream(&conn, 3)
	http2.connection_create_stream(&conn, 5)

	// Send GOAWAY with last_stream_id = 3
	goaway_frame := http2.Goaway_Frame{
		header = http2.Frame_Header{
			length = 8,
			type = .GOAWAY,
			flags = 0,
			stream_id = 0,
		},
		last_stream_id = 3,
		error_code = .NO_ERROR,
		additional_data = nil,
	}

	err := http2.connection_handle_goaway(&conn, &goaway_frame)
	testing.expect(t, err == .None, "Should handle GOAWAY successfully")
	testing.expect(t, conn.goaway_received == true, "Should mark GOAWAY received")
	testing.expect(t, conn.state == .Going_Away, "Should transition to Going_Away")

	// Stream 5 should be closed (> last_stream_id)
	// Streams 1 and 3 should remain
	testing.expect(t, http2.connection_stream_count(&conn) == 2, "Should have 2 streams left")

	_, found1 := http2.connection_get_stream(&conn, 1)
	testing.expect(t, found1 == true, "Stream 1 should exist")

	_, found3 := http2.connection_get_stream(&conn, 3)
	testing.expect(t, found3 == true, "Stream 3 should exist")

	_, found5 := http2.connection_get_stream(&conn, 5)
	testing.expect(t, found5 == false, "Stream 5 should be closed")
}

@(test)
test_http2_connection_send_goaway :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	conn.state = .Active

	err := http2.connection_send_goaway(&conn, .NO_ERROR)
	testing.expect(t, err == .None, "Should send GOAWAY successfully")
	testing.expect(t, conn.goaway_sent == true, "Should mark GOAWAY sent")
	testing.expect(t, conn.state == .Going_Away, "Should transition to Going_Away")
}

@(test)
test_http2_connection_flow_control :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	initial_window := conn.connection_window
	testing.expect(t, initial_window == 65535, "Should have default window size")

	// Consume some window
	err := http2.connection_consume_window(&conn, 1000)
	testing.expect(t, err == .None, "Should consume window successfully")
	testing.expect(t, conn.connection_window == 64535, "Window should be decreased")

	// Update window
	err = http2.connection_update_window(&conn, 2000)
	testing.expect(t, err == .None, "Should update window successfully")
	testing.expect(t, conn.connection_window == 66535, "Window should be increased")
}

@(test)
test_http2_connection_flow_control_overflow :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	conn.connection_window = max(i32) - 100

	// Try to overflow
	err := http2.connection_update_window(&conn, 200)
	testing.expect(t, err == .Flow_Control_Error, "Should reject overflow")
}

@(test)
test_http2_connection_flow_control_underflow :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	conn.connection_window = 100

	// Try to consume more than available
	err := http2.connection_consume_window(&conn, 200)
	testing.expect(t, err == .Flow_Control_Error, "Should reject underflow")
}

@(test)
test_http2_connection_state_checks :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	testing.expect(t, http2.connection_is_active(&conn) == false, "Should not be active initially")
	testing.expect(t, http2.connection_is_closing(&conn) == false, "Should not be closing initially")

	conn.state = .Active
	testing.expect(t, http2.connection_is_active(&conn) == true, "Should be active")
	testing.expect(t, http2.connection_is_closing(&conn) == false, "Should not be closing")

	conn.state = .Going_Away
	testing.expect(t, http2.connection_is_active(&conn) == false, "Should not be active")
	testing.expect(t, http2.connection_is_closing(&conn) == true, "Should be closing")
}

@(test)
test_http2_connection_can_create_stream :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	testing.expect(t, http2.connection_can_create_stream(&conn) == false, "Cannot create before Active")

	conn.state = .Active
	testing.expect(t, http2.connection_can_create_stream(&conn) == true, "Can create when Active")

	conn.state = .Going_Away
	testing.expect(t, http2.connection_can_create_stream(&conn) == false, "Cannot create when Going_Away")
}

@(test)
test_http2_connection_stream_limit :: proc(t: ^testing.T) {
	conn, _ := http2.connection_init(true)
	defer http2.connection_destroy(&conn)

	conn.state = .Active

	// Set a low limit
	http2.settings_apply_remote(&conn.settings, .MAX_CONCURRENT_STREAMS, 2)

	// Create up to limit
	http2.connection_create_stream(&conn, 1)
	http2.connection_create_stream(&conn, 3)

	// Try to exceed limit
	_, err := http2.connection_create_stream(&conn, 5)
	testing.expect(t, err == .Stream_Limit_Exceeded, "Should enforce stream limit")
}
