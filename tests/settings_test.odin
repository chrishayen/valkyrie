package valkyrie_tests

import "core:testing"
import http "../http"

@(test)
test_settings_init :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	testing.expect(t, ctx.local_header_table_size == 4096, "Default header table size")
	testing.expect(t, ctx.local_enable_push == false, "Push disabled by default for servers")
	testing.expect(t, ctx.local_initial_window_size == 65535, "Default window size")
	testing.expect(t, ctx.local_max_frame_size == 16384, "Default frame size")
}

@(test)
test_settings_apply_local :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	// Update header table size
	err := http.settings_apply_local(&ctx, .HEADER_TABLE_SIZE, 8192)
	testing.expect(t, err == .None, "Should apply successfully")
	testing.expect(t, ctx.local_header_table_size == 8192, "Should update value")
}

@(test)
test_settings_apply_remote :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	// Update remote max concurrent streams
	err := http.settings_apply_remote(&ctx, .MAX_CONCURRENT_STREAMS, 200)
	testing.expect(t, err == .None, "Should apply successfully")
	testing.expect(t, ctx.remote_max_concurrent_streams == 200, "Should update value")
}

@(test)
test_settings_enable_push_valid :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	// Disable push
	err := http.settings_apply_remote(&ctx, .ENABLE_PUSH, 0)
	testing.expect(t, err == .None, "Should apply successfully")
	testing.expect(t, ctx.remote_enable_push == false, "Should disable push")

	// Enable push
	err = http.settings_apply_remote(&ctx, .ENABLE_PUSH, 1)
	testing.expect(t, err == .None, "Should apply successfully")
	testing.expect(t, ctx.remote_enable_push == true, "Should enable push")
}

@(test)
test_settings_enable_push_invalid :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	// Invalid value (must be 0 or 1)
	err := http.settings_apply_remote(&ctx, .ENABLE_PUSH, 2)
	testing.expect(t, err == .Invalid_Value, "Should reject invalid value")
}

@(test)
test_settings_initial_window_size_valid :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	// Valid window size
	err := http.settings_apply_local(&ctx, .INITIAL_WINDOW_SIZE, 1000000)
	testing.expect(t, err == .None, "Should apply successfully")
	testing.expect(t, ctx.local_initial_window_size == 1000000, "Should update value")
}

@(test)
test_settings_initial_window_size_too_large :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	// Too large (> 2^31 - 1)
	err := http.settings_apply_remote(&ctx, .INITIAL_WINDOW_SIZE, 0x80000000)
	testing.expect(t, err == .Flow_Control_Error, "Should reject too large value")
}

@(test)
test_settings_max_frame_size_valid :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	// Valid frame size
	err := http.settings_apply_local(&ctx, .MAX_FRAME_SIZE, 32768)
	testing.expect(t, err == .None, "Should apply successfully")
	testing.expect(t, ctx.local_max_frame_size == 32768, "Should update value")
}

@(test)
test_settings_max_frame_size_too_small :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	// Too small (< 2^14)
	err := http.settings_apply_remote(&ctx, .MAX_FRAME_SIZE, 10000)
	testing.expect(t, err == .Frame_Size_Error, "Should reject too small value")
}

@(test)
test_settings_max_frame_size_too_large :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	// Too large (> 2^24 - 1)
	err := http.settings_apply_remote(&ctx, .MAX_FRAME_SIZE, 16777216)
	testing.expect(t, err == .Frame_Size_Error, "Should reject too large value")
}

@(test)
test_settings_ack_tracking :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	testing.expect(t, ctx.local_settings_acked == false, "Initially not acked")
	testing.expect(t, ctx.remote_settings_acked == false, "Initially not acked")

	http.settings_mark_local_acked(&ctx)
	testing.expect(t, ctx.local_settings_acked == true, "Should mark local acked")

	http.settings_mark_remote_acked(&ctx)
	testing.expect(t, ctx.remote_settings_acked == true, "Should mark remote acked")
}

@(test)
test_settings_getters :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	// Update some settings
	http.settings_apply_local(&ctx, .INITIAL_WINDOW_SIZE, 100000)
	http.settings_apply_remote(&ctx, .INITIAL_WINDOW_SIZE, 200000)
	http.settings_apply_remote(&ctx, .MAX_FRAME_SIZE, 32768)
	http.settings_apply_remote(&ctx, .MAX_CONCURRENT_STREAMS, 50)

	testing.expect(t, http.settings_get_local_window_size(&ctx) == 100000, "Should get local window")
	testing.expect(t, http.settings_get_remote_window_size(&ctx) == 200000, "Should get remote window")
	testing.expect(t, http.settings_get_remote_max_frame_size(&ctx) == 32768, "Should get max frame size")
	testing.expect(t, http.settings_get_remote_max_concurrent_streams(&ctx) == 50, "Should get max streams")
}

@(test)
test_settings_can_push :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	// Remote (client) enables push by default
	testing.expect(t, http.settings_can_push(&ctx) == true, "Client push enabled by default")

	http.settings_apply_remote(&ctx, .ENABLE_PUSH, 0)
	testing.expect(t, http.settings_can_push(&ctx) == false, "Push should be disabled")
}

@(test)
test_settings_build_frame :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	frame, ok := http.settings_build_frame(&ctx)
	defer delete(frame.settings)

	testing.expect(t, ok == true, "Should build frame")
	testing.expect(t, frame.header.type == .SETTINGS, "Should be SETTINGS frame")
	testing.expect(t, frame.header.stream_id == 0, "Should be on stream 0")
	testing.expect(t, len(frame.settings) == 6, "Should have 6 settings")
	testing.expect(t, frame.header.length == 36, "Length should be 6 * 6 = 36 bytes")
}

@(test)
test_settings_build_ack_frame :: proc(t: ^testing.T) {
	frame := http.settings_build_ack_frame()

	testing.expect(t, frame.header.type == .SETTINGS, "Should be SETTINGS frame")
	testing.expect(t, frame.header.stream_id == 0, "Should be on stream 0")
	testing.expect(t, frame.header.length == 0, "ACK should have no payload")
	testing.expect(t, (frame.header.flags & http.SETTINGS_FLAG_ACK) != 0, "Should have ACK flag")
	testing.expect(t, frame.settings == nil, "ACK should have no settings")
}

@(test)
test_settings_is_ack :: proc(t: ^testing.T) {
	// Regular SETTINGS frame
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	frame, _ := http.settings_build_frame(&ctx)
	defer delete(frame.settings)
	testing.expect(t, http.settings_is_ack(&frame) == false, "Should not be ACK")

	// ACK frame
	ack_frame := http.settings_build_ack_frame()
	testing.expect(t, http.settings_is_ack(&ack_frame) == true, "Should be ACK")
}

@(test)
test_settings_max_header_list_size :: proc(t: ^testing.T) {
	ctx := http.settings_init()
	defer http.settings_destroy(&ctx)

	// Update max header list size
	err := http.settings_apply_remote(&ctx, .MAX_HEADER_LIST_SIZE, 16384)
	testing.expect(t, err == .None, "Should apply successfully")
	testing.expect(t, ctx.remote_max_header_list_size == 16384, "Should update value")
}
