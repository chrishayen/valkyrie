package valkyrie_tests

import "core:testing"
import http "../http"

@(test)
test_stream_init :: proc(t: ^testing.T) {
	stream := http.stream_init(1, 65535)
	defer http.stream_destroy(&stream)

	testing.expect(t, stream.id == 1, "Stream ID should be 1")
	testing.expect(t, stream.state == .Idle, "Initial state should be idle")
	testing.expect(t, stream.window_size == 65535, "Window size should be 65535")
	testing.expect(t, stream.remote_window_size == 65535, "Remote window size should be 65535")
	testing.expect(t, stream.priority_weight == 15, "Default weight should be 15 (16-1)")
}

@(test)
test_stream_idle_to_open_recv :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Receive HEADERS without END_STREAM
	err := http.stream_recv_headers(&stream, false)
	testing.expect(t, err == .None, "Should transition successfully")
	testing.expect(t, stream.state == .Open, "State should be open")
}

@(test)
test_stream_idle_to_half_closed_remote :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Receive HEADERS with END_STREAM
	err := http.stream_recv_headers(&stream, true)
	testing.expect(t, err == .None, "Should transition successfully")
	testing.expect(t, stream.state == .Half_Closed_Remote, "State should be half-closed remote")
	testing.expect(t, stream.recv_end_stream == true, "Should mark received END_STREAM")
}

@(test)
test_stream_idle_to_open_send :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Send HEADERS without END_STREAM
	err := http.stream_send_headers(&stream, false)
	testing.expect(t, err == .None, "Should transition successfully")
	testing.expect(t, stream.state == .Open, "State should be open")
}

@(test)
test_stream_idle_to_half_closed_local :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Send HEADERS with END_STREAM
	err := http.stream_send_headers(&stream, true)
	testing.expect(t, err == .None, "Should transition successfully")
	testing.expect(t, stream.state == .Half_Closed_Local, "State should be half-closed local")
	testing.expect(t, stream.sent_end_stream == true, "Should mark sent END_STREAM")
}

@(test)
test_stream_open_to_closed_both_directions :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Open the stream
	http.stream_recv_headers(&stream, false)
	testing.expect(t, stream.state == .Open, "Stream should be open")

	// Send END_STREAM
	err := http.stream_send_data(&stream, 0, true)
	testing.expect(t, err == .None, "Should send successfully")
	testing.expect(t, stream.state == .Half_Closed_Local, "State should be half-closed local")

	// Receive END_STREAM
	err = http.stream_recv_data(&stream, 0, true)
	testing.expect(t, err == .None, "Should receive successfully")
	testing.expect(t, stream.state == .Closed, "State should be closed")
}

@(test)
test_stream_recv_data_flow_control :: proc(t: ^testing.T) {
	stream := http.stream_init(1, 1000)
	defer http.stream_destroy(&stream)

	// Open the stream
	http.stream_recv_headers(&stream, false)

	// Receive data within window
	err := http.stream_recv_data(&stream, 500, false)
	testing.expect(t, err == .None, "Should receive successfully")
	testing.expect(t, stream.window_size == 500, "Window should be decremented")

	// Receive more data
	err = http.stream_recv_data(&stream, 500, false)
	testing.expect(t, err == .None, "Should receive successfully")
	testing.expect(t, stream.window_size == 0, "Window should be zero")

	// Try to exceed window
	err = http.stream_recv_data(&stream, 1, false)
	testing.expect(t, err == .Flow_Control_Error, "Should fail with flow control error")
}

@(test)
test_stream_send_data_flow_control :: proc(t: ^testing.T) {
	stream := http.stream_init(1, 1000)
	defer http.stream_destroy(&stream)

	// Open the stream
	http.stream_send_headers(&stream, false)

	// Send data within window
	err := http.stream_send_data(&stream, 500, false)
	testing.expect(t, err == .None, "Should send successfully")
	testing.expect(t, stream.remote_window_size == 500, "Remote window should be decremented")

	// Send more data
	err = http.stream_send_data(&stream, 500, false)
	testing.expect(t, err == .None, "Should send successfully")
	testing.expect(t, stream.remote_window_size == 0, "Remote window should be zero")

	// Try to exceed window
	err = http.stream_send_data(&stream, 1, false)
	testing.expect(t, err == .Flow_Control_Error, "Should fail with flow control error")
}

@(test)
test_stream_recv_window_update :: proc(t: ^testing.T) {
	stream := http.stream_init(1, 1000)
	defer http.stream_destroy(&stream)

	// Update remote window (for sending)
	err := http.stream_recv_window_update(&stream, 500)
	testing.expect(t, err == .None, "Should update successfully")
	testing.expect(t, stream.remote_window_size == 1500, "Remote window should be increased")
}

@(test)
test_stream_send_window_update :: proc(t: ^testing.T) {
	stream := http.stream_init(1, 1000)
	defer http.stream_destroy(&stream)

	// Update local window (for receiving)
	err := http.stream_send_window_update(&stream, 500)
	testing.expect(t, err == .None, "Should update successfully")
	testing.expect(t, stream.window_size == 1500, "Local window should be increased")
}

@(test)
test_stream_window_update_overflow :: proc(t: ^testing.T) {
	stream := http.stream_init(1, max(i32) - 100)
	defer http.stream_destroy(&stream)

	// Try to overflow window
	err := http.stream_recv_window_update(&stream, 200)
	testing.expect(t, err == .Flow_Control_Error, "Should fail with overflow")
}

@(test)
test_stream_window_update_zero_increment :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Zero increment is invalid
	err := http.stream_recv_window_update(&stream, 0)
	testing.expect(t, err == .Protocol_Error, "Should fail with protocol error")
}

@(test)
test_stream_rst_from_open :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Open the stream
	http.stream_recv_headers(&stream, false)
	testing.expect(t, stream.state == .Open, "Stream should be open")

	// Receive RST_STREAM
	err := http.stream_recv_rst(&stream, 0)
	testing.expect(t, err == .None, "Should reset successfully")
	testing.expect(t, stream.state == .Closed, "State should be closed")
}

@(test)
test_stream_rst_from_idle_invalid :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Cannot RST_STREAM from idle
	err := http.stream_recv_rst(&stream, 0)
	testing.expect(t, err == .Protocol_Error, "Should fail from idle state")
}

@(test)
test_stream_send_rst_from_open :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Open the stream
	http.stream_send_headers(&stream, false)
	testing.expect(t, stream.state == .Open, "Stream should be open")

	// Send RST_STREAM
	err := http.stream_send_rst(&stream, 0)
	testing.expect(t, err == .None, "Should send RST successfully")
	testing.expect(t, stream.state == .Closed, "State should be closed")
}

@(test)
test_stream_priority :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Receive PRIORITY frame
	err := http.stream_recv_priority(&stream, 3, 42, true)
	testing.expect(t, err == .None, "Should update priority successfully")
	testing.expect(t, stream.priority_depends_on == 3, "Should update dependency")
	testing.expect(t, stream.priority_weight == 42, "Should update weight")
	testing.expect(t, stream.priority_exclusive == true, "Should update exclusive flag")
}

@(test)
test_stream_priority_self_dependency :: proc(t: ^testing.T) {
	stream := http.stream_init(5)
	defer http.stream_destroy(&stream)

	// Cannot depend on itself
	err := http.stream_recv_priority(&stream, 5, 10, false)
	testing.expect(t, err == .Protocol_Error, "Should fail with self-dependency")
}

@(test)
test_stream_priority_on_closed :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Close the stream
	http.stream_send_headers(&stream, false)
	http.stream_send_rst(&stream, 0)
	testing.expect(t, stream.state == .Closed, "Stream should be closed")

	// PRIORITY is allowed even on closed streams
	err := http.stream_recv_priority(&stream, 3, 10, false)
	testing.expect(t, err == .None, "PRIORITY should be allowed on closed stream")
}

@(test)
test_stream_can_send_data :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Idle - cannot send
	testing.expect(t, http.stream_can_send_data(&stream) == false, "Cannot send from idle")

	// Open - can send
	http.stream_send_headers(&stream, false)
	testing.expect(t, http.stream_can_send_data(&stream) == true, "Can send from open")

	// Half-closed local - cannot send
	http.stream_send_data(&stream, 0, true)
	testing.expect(t, http.stream_can_send_data(&stream) == false, "Cannot send from half-closed local")
}

@(test)
test_stream_can_recv_data :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Idle - cannot receive
	testing.expect(t, http.stream_can_recv_data(&stream) == false, "Cannot receive from idle")

	// Open - can receive
	http.stream_recv_headers(&stream, false)
	testing.expect(t, http.stream_can_recv_data(&stream) == true, "Can receive from open")

	// Half-closed remote - cannot receive
	http.stream_recv_data(&stream, 0, true)
	testing.expect(t, http.stream_can_recv_data(&stream) == false, "Cannot receive from half-closed remote")
}

@(test)
test_stream_invalid_data_on_closed :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Open and close stream
	http.stream_send_headers(&stream, false)
	http.stream_send_rst(&stream, 0)

	// Try to send data on closed stream
	err := http.stream_send_data(&stream, 100, false)
	testing.expect(t, err == .Invalid_Frame_For_State, "Should reject DATA on closed stream")

	// Try to receive data on closed stream
	err = http.stream_recv_data(&stream, 100, false)
	testing.expect(t, err == .Invalid_Frame_For_State, "Should reject DATA on closed stream")
}

@(test)
test_stream_half_closed_local_can_recv :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Open stream and send END_STREAM
	http.stream_recv_headers(&stream, false)
	http.stream_send_data(&stream, 0, true)
	testing.expect(t, stream.state == .Half_Closed_Local, "Should be half-closed local")

	// Can still receive data
	err := http.stream_recv_data(&stream, 100, false)
	testing.expect(t, err == .None, "Should receive data in half-closed local")
}

@(test)
test_stream_half_closed_remote_can_send :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Open stream and receive END_STREAM
	http.stream_send_headers(&stream, false)
	http.stream_recv_data(&stream, 0, true)
	testing.expect(t, stream.state == .Half_Closed_Remote, "Should be half-closed remote")

	// Can still send data
	err := http.stream_send_data(&stream, 100, false)
	testing.expect(t, err == .None, "Should send data in half-closed remote")
}

@(test)
test_stream_available_windows :: proc(t: ^testing.T) {
	stream := http.stream_init(1, 1000)
	defer http.stream_destroy(&stream)

	// Check initial windows
	testing.expect(t, http.stream_available_send_window(&stream) == 1000, "Send window should be 1000")
	testing.expect(t, http.stream_available_recv_window(&stream) == 1000, "Recv window should be 1000")

	// Open and consume some window
	http.stream_send_headers(&stream, false)
	http.stream_send_data(&stream, 300, false)

	testing.expect(t, http.stream_available_send_window(&stream) == 700, "Send window should be 700")
	testing.expect(t, http.stream_available_recv_window(&stream) == 1000, "Recv window unchanged")
}

@(test)
test_stream_trailers :: proc(t: ^testing.T) {
	stream := http.stream_init(1)
	defer http.stream_destroy(&stream)

	// Open stream with initial HEADERS
	http.stream_recv_headers(&stream, false)
	testing.expect(t, stream.state == .Open, "Stream should be open")

	// Receive DATA
	http.stream_recv_data(&stream, 100, false)
	testing.expect(t, stream.state == .Open, "Stream should still be open")

	// Receive trailing HEADERS with END_STREAM
	err := http.stream_recv_headers(&stream, true)
	testing.expect(t, err == .None, "Should accept trailers")
	testing.expect(t, stream.state == .Half_Closed_Remote, "Should transition to half-closed remote")
}
