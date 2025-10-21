package http

import "base:runtime"
import "core:fmt"

// Connection_State represents the state of an HTTP/2 connection
Connection_State :: enum {
	Waiting_Preface,      // Waiting for client preface
	Waiting_Settings,     // Waiting for initial SETTINGS
	Active,               // Connection is active
	Going_Away,           // Sent/received GOAWAY
	Closed,               // Connection closed
}

// HTTP2_Connection manages an HTTP/2 connection with multiple streams
HTTP2_Connection :: struct {
	state:                      Connection_State,
	settings:                   Settings_Context,
	streams:                    map[u32]Stream,  // Active streams by ID
	next_stream_id:             u32,              // Next stream ID to use (for server push)
	last_stream_id:             u32,              // Last stream ID processed
	goaway_sent:                bool,
	goaway_received:            bool,
	goaway_error_code:          Error_Code,
	connection_window:          i32,              // Local flow control window (for receiving)
	remote_connection_window:   i32,              // Remote's flow control window (for sending)
	preface_received:           bool,

	// CONTINUATION frame state
	continuation_expected:      bool,             // Expecting CONTINUATION frames
	continuation_stream_id:     u32,              // Stream ID for CONTINUATION sequence
	continuation_header_block:  [dynamic]byte,    // Accumulated header block fragments

	allocator:                  runtime.Allocator,
}

// Connection_Error represents connection-level errors
Connection_Error :: enum {
	None,
	Preface_Invalid,
	Settings_Error,
	Stream_Error,
	Protocol_Error,
	Flow_Control_Error,
	Frame_Size_Error,
	Connection_Closed,
	Stream_Not_Found,
	Stream_Limit_Exceeded,
}

// connection_init creates a new HTTP/2 connection
connection_init :: proc(is_server: bool, allocator := context.allocator) -> (conn: HTTP2_Connection, ok: bool) {
	streams := make(map[u32]Stream, allocator)
	if streams.allocator.procedure == nil {
		return {}, false
	}

	settings := settings_init(allocator)

	continuation_header_block := make([dynamic]byte, 0, 0, allocator)

	return HTTP2_Connection{
		state = .Waiting_Preface,
		settings = settings,
		streams = streams,
		next_stream_id = is_server ? 2 : 1,  // Server uses even IDs for push
		last_stream_id = 0,
		goaway_sent = false,
		goaway_received = false,
		goaway_error_code = .NO_ERROR,
		connection_window = DEFAULT_INITIAL_WINDOW_SIZE,
		remote_connection_window = DEFAULT_INITIAL_WINDOW_SIZE,
		preface_received = false,

		continuation_expected = false,
		continuation_stream_id = 0,
		continuation_header_block = continuation_header_block,

		allocator = allocator,
	}, true
}

// connection_destroy frees all connection resources
connection_destroy :: proc(conn: ^HTTP2_Connection) {
	if conn == nil {
		return
	}

	// Destroy all streams
	for id, stream in &conn.streams {
		s := stream
		stream_destroy(&s)
	}
	delete(conn.streams)

	// Clean up continuation state
	delete(conn.continuation_header_block)

	settings_destroy(&conn.settings)
}

// connection_handle_preface validates the connection preface
connection_handle_preface :: proc(conn: ^HTTP2_Connection, data: []byte) -> Connection_Error {
	if conn == nil {
		return .Protocol_Error
	}

	if conn.state != .Waiting_Preface {
		return .Protocol_Error
	}

	valid, _ := preface_validate(data)
	if !valid {
		return .Preface_Invalid
	}

	conn.preface_received = true
	conn.state = .Waiting_Settings
	return .None
}

// connection_handle_settings processes a SETTINGS frame
connection_handle_settings :: proc(conn: ^HTTP2_Connection, frame: ^Settings_Frame) -> Connection_Error {
	if conn == nil || frame == nil {
		return .Protocol_Error
	}

	// Check if this is an ACK
	if settings_is_ack(frame) {
		settings_mark_local_acked(&conn.settings)
		return .None
	}

	// Apply remote settings
	if frame.settings != nil {
		for setting in frame.settings {
			err := settings_apply_remote(&conn.settings, setting.id, setting.value)
			if err != .None {
				return .Settings_Error
			}
		}
	}

	// Move to active state after first SETTINGS
	if conn.state == .Waiting_Settings {
		conn.state = .Active
	}

	settings_mark_remote_acked(&conn.settings)
	return .None
}

// connection_create_stream creates a new stream
connection_create_stream :: proc(conn: ^HTTP2_Connection, stream_id: u32) -> (^Stream, Connection_Error) {
	if conn == nil {
		return nil, .Protocol_Error
	}

	if conn.state != .Active {
		return nil, .Protocol_Error
	}

	// Check if stream already exists
	if stream_id in conn.streams {
		return nil, .Stream_Error
	}

	// Check stream limit (use local setting - how many we're willing to accept)
	max_streams := settings_get_local_max_concurrent_streams(&conn.settings)
	if u32(len(conn.streams)) >= max_streams {
		return nil, .Stream_Limit_Exceeded
	}

	// Create stream with current settings
	window_size := i32(settings_get_local_window_size(&conn.settings))
	stream := stream_init(stream_id, window_size, conn.allocator)
	conn.streams[stream_id] = stream

	if stream_id > conn.last_stream_id {
		conn.last_stream_id = stream_id
	}

	return &conn.streams[stream_id], .None
}

// connection_get_stream retrieves a stream by ID
connection_get_stream :: proc(conn: ^HTTP2_Connection, stream_id: u32) -> (^Stream, bool) {
	if conn == nil {
		return nil, false
	}

	if stream_id in conn.streams {
		return &conn.streams[stream_id], true
	}

	return nil, false
}

// connection_remove_stream removes a closed stream
connection_remove_stream :: proc(conn: ^HTTP2_Connection, stream_id: u32) -> bool {
	if conn == nil {
		return false
	}

	if stream_id in conn.streams {
		stream := conn.streams[stream_id]
		s := stream
		stream_destroy(&s)
		delete_key(&conn.streams, stream_id)
		return true
	}

	return false
}

// connection_handle_ping processes a PING frame
connection_handle_ping :: proc(conn: ^HTTP2_Connection, frame: ^Ping_Frame, is_ack: bool) -> Connection_Error {
	if conn == nil || frame == nil {
		return .Protocol_Error
	}

	if conn.state != .Active {
		return .Protocol_Error
	}

	// PING frames on non-zero stream ID are connection errors
	if frame.header.stream_id != 0 {
		return .Protocol_Error
	}

	// If it's not an ACK, we need to respond
	// If it is an ACK, just acknowledge receipt
	return .None
}

// connection_handle_goaway processes a GOAWAY frame
connection_handle_goaway :: proc(conn: ^HTTP2_Connection, frame: ^Goaway_Frame) -> Connection_Error {
	if conn == nil || frame == nil {
		return .Protocol_Error
	}

	// GOAWAY must be on stream 0
	if frame.header.stream_id != 0 {
		return .Protocol_Error
	}

	conn.goaway_received = true
	conn.goaway_error_code = frame.error_code
	conn.state = .Going_Away

	// Close streams with ID > last_stream_id from GOAWAY
	streams_to_close := make([dynamic]u32, conn.allocator)
	defer delete(streams_to_close)

	for id in conn.streams {
		if id > frame.last_stream_id {
			append(&streams_to_close, id)
		}
	}

	for id in streams_to_close {
		connection_remove_stream(conn, id)
	}

	return .None
}

// connection_send_goaway marks the connection as going away
connection_send_goaway :: proc(conn: ^HTTP2_Connection, error_code: Error_Code) -> Connection_Error {
	if conn == nil {
		return .Protocol_Error
	}

	conn.goaway_sent = true
	conn.goaway_error_code = error_code
	conn.state = .Going_Away

	return .None
}

// connection_update_window updates the connection-level flow control window
connection_update_window :: proc(conn: ^HTTP2_Connection, increment: i32) -> Connection_Error {
	if conn == nil {
		return .Protocol_Error
	}

	if increment <= 0 {
		return .Protocol_Error
	}

	new_window := conn.connection_window + increment
	if new_window > MAX_WINDOW_SIZE || new_window < 0 {
		return .Flow_Control_Error
	}

	conn.connection_window = new_window
	return .None
}

// connection_consume_window consumes connection-level flow control window
connection_consume_window :: proc(conn: ^HTTP2_Connection, amount: i32) -> Connection_Error {
	if conn == nil {
		return .Protocol_Error
	}

	if conn.connection_window < amount {
		return .Flow_Control_Error
	}

	conn.connection_window -= amount
	return .None
}

// connection_is_active checks if connection is active
connection_is_active :: proc(conn: ^HTTP2_Connection) -> bool {
	if conn == nil {
		return false
	}
	return conn.state == .Active
}

// connection_is_closing checks if connection is going away or closed
connection_is_closing :: proc(conn: ^HTTP2_Connection) -> bool {
	if conn == nil {
		return true
	}
	return conn.state == .Going_Away || conn.state == .Closed
}

// connection_stream_count returns the number of active streams
connection_stream_count :: proc(conn: ^HTTP2_Connection) -> int {
	if conn == nil {
		return 0
	}
	return len(conn.streams)
}

// connection_can_create_stream checks if we can create a new stream
connection_can_create_stream :: proc(conn: ^HTTP2_Connection) -> bool {
	if conn == nil || conn.state != .Active {
		return false
	}

	max_streams := settings_get_local_max_concurrent_streams(&conn.settings)
	return u32(len(conn.streams)) < max_streams
}

// connection_get_available_window returns available connection window (for receiving)
connection_get_available_window :: proc(conn: ^HTTP2_Connection) -> i32 {
	if conn == nil {
		return 0
	}
	return conn.connection_window
}

// connection_get_available_remote_window returns available remote window (for sending)
connection_get_available_remote_window :: proc(conn: ^HTTP2_Connection) -> i32 {
	if conn == nil {
		return 0
	}
	return conn.remote_connection_window
}

// connection_consume_remote_window consumes remote connection window when sending data
connection_consume_remote_window :: proc(conn: ^HTTP2_Connection, amount: i32) -> Connection_Error {
	if conn == nil {
		return .Protocol_Error
	}

	if conn.remote_connection_window < amount {
		return .Flow_Control_Error
	}

	conn.remote_connection_window -= amount
	return .None
}

// connection_update_remote_window updates remote connection window from WINDOW_UPDATE
connection_update_remote_window :: proc(conn: ^HTTP2_Connection, increment: i32) -> Connection_Error {
	if conn == nil {
		return .Protocol_Error
	}

	if increment <= 0 {
		return .Protocol_Error
	}

	new_window := conn.remote_connection_window + increment
	if new_window > MAX_WINDOW_SIZE || new_window < 0 {
		return .Flow_Control_Error
	}

	conn.remote_connection_window = new_window
	return .None
}
