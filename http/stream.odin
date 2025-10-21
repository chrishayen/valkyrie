package http

import "base:runtime"

// Stream_State represents the HTTP/2 stream state machine (RFC 9113 Section 5.1)
Stream_State :: enum {
	Idle,                // Initial state
	Reserved_Local,      // Server sent PUSH_PROMISE
	Reserved_Remote,     // Client received PUSH_PROMISE
	Open,                // Both endpoints can send frames
	Half_Closed_Local,   // Local sent END_STREAM, can still receive
	Half_Closed_Remote,  // Remote sent END_STREAM, can still send
	Closed,              // Terminal state
}

// Stream represents an HTTP/2 stream with its state and flow control
Stream :: struct {
	id:                    u32,
	state:                 Stream_State,
	window_size:           i32,  // Local flow control window for this stream
	remote_window_size:    i32,  // Remote's flow control window
	priority_weight:       u8,   // Stream priority weight (1-256, stored as 0-255)
	priority_depends_on:   u32,  // Stream dependency ID
	priority_exclusive:    bool, // Exclusive dependency flag
	recv_end_stream:       bool, // Received END_STREAM flag
	sent_end_stream:       bool, // Sent END_STREAM flag
	recv_body:             [dynamic]byte,  // Accumulated request body data
	recv_headers_complete: bool,           // Whether we've received complete headers
	recv_header_block:     []byte,         // Stored header block for deferred decoding

	// Flow control queueing for sending
	pending_send_data:     []byte,         // Queued response data waiting for flow control
	pending_send_end_stream: bool,         // Whether END_STREAM should be sent with final chunk

	allocator:             runtime.Allocator,
}

// Stream_Error represents stream-level errors that result in RST_STREAM
Stream_Error :: enum {
	None,
	Invalid_State_Transition,
	Flow_Control_Error,
	Stream_Closed,
	Invalid_Frame_For_State,
	Protocol_Error,
}

// stream_init creates a new stream in idle state
stream_init :: proc(id: u32, initial_window_size: i32 = 65535, allocator := context.allocator) -> Stream {
	return Stream{
		id = id,
		state = .Idle,
		window_size = initial_window_size,
		remote_window_size = initial_window_size,
		priority_weight = 15,  // Default weight is 16 (stored as 15, per RFC)
		priority_depends_on = 0,
		priority_exclusive = false,
		recv_end_stream = false,
		sent_end_stream = false,
		recv_body = make([dynamic]byte, 0, 0, allocator),
		recv_headers_complete = false,
		recv_header_block = nil,
		pending_send_data = nil,
		pending_send_end_stream = false,
		allocator = allocator,
	}
}

// stream_destroy cleans up stream resources
stream_destroy :: proc(stream: ^Stream) {
	if stream == nil {
		return
	}
	delete(stream.recv_body)
	if stream.recv_header_block != nil {
		delete(stream.recv_header_block)
	}
	if stream.pending_send_data != nil {
		delete(stream.pending_send_data)
	}
}

// stream_recv_headers processes receiving a HEADERS frame
stream_recv_headers :: proc(stream: ^Stream, end_stream: bool) -> Stream_Error {
	if stream == nil {
		return .Protocol_Error
	}

	switch stream.state {
	case .Idle:
		// HEADERS received on idle stream opens it
		stream.state = .Open
		if end_stream {
			stream.recv_end_stream = true
			stream.state = .Half_Closed_Remote
		}
		return .None

	case .Reserved_Remote:
		// Server sent PUSH_PROMISE, now sending promised response
		stream.state = .Half_Closed_Local
		if end_stream {
			stream.recv_end_stream = true
			stream.state = .Closed
		}
		return .None

	case .Open:
		// Trailers or additional headers
		if end_stream {
			stream.recv_end_stream = true
			if stream.sent_end_stream {
				stream.state = .Closed
			} else {
				stream.state = .Half_Closed_Remote
			}
		}
		return .None

	case .Half_Closed_Local:
		// Can still receive
		if end_stream {
			stream.recv_end_stream = true
			stream.state = .Closed
		}
		return .None

	case .Closed, .Half_Closed_Remote, .Reserved_Local:
		// Invalid to receive HEADERS in these states
		return .Invalid_Frame_For_State
	}

	return .Protocol_Error
}

// stream_send_headers processes sending a HEADERS frame
stream_send_headers :: proc(stream: ^Stream, end_stream: bool) -> Stream_Error {
	if stream == nil {
		return .Protocol_Error
	}

	switch stream.state {
	case .Idle:
		// Sending HEADERS opens the stream
		stream.state = .Open
		if end_stream {
			stream.sent_end_stream = true
			stream.state = .Half_Closed_Local
		}
		return .None

	case .Reserved_Local:
		// Server fulfilling PUSH_PROMISE
		stream.state = .Half_Closed_Remote
		if end_stream {
			stream.sent_end_stream = true
			stream.state = .Closed
		}
		return .None

	case .Open:
		// Trailers or additional headers
		if end_stream {
			stream.sent_end_stream = true
			if stream.recv_end_stream {
				stream.state = .Closed
			} else {
				stream.state = .Half_Closed_Local
			}
		}
		return .None

	case .Half_Closed_Remote:
		// Can still send
		if end_stream {
			stream.sent_end_stream = true
			stream.state = .Closed
		}
		return .None

	case .Closed, .Half_Closed_Local, .Reserved_Remote:
		// Invalid to send HEADERS in these states
		return .Invalid_Frame_For_State
	}

	return .Protocol_Error
}

// stream_recv_data processes receiving a DATA frame
stream_recv_data :: proc(stream: ^Stream, data_length: int, end_stream: bool) -> Stream_Error {
	if stream == nil {
		return .Protocol_Error
	}

	// DATA frames are only valid in certain states
	switch stream.state {
	case .Open:
		// Check flow control
		if stream.window_size < i32(data_length) {
			return .Flow_Control_Error
		}
		stream.window_size -= i32(data_length)

		if end_stream {
			stream.recv_end_stream = true
			if stream.sent_end_stream {
				stream.state = .Closed
			} else {
				stream.state = .Half_Closed_Remote
			}
		}
		return .None

	case .Half_Closed_Local:
		// Can still receive data
		if stream.window_size < i32(data_length) {
			return .Flow_Control_Error
		}
		stream.window_size -= i32(data_length)

		if end_stream {
			stream.recv_end_stream = true
			stream.state = .Closed
		}
		return .None

	case .Idle, .Reserved_Local, .Reserved_Remote, .Half_Closed_Remote, .Closed:
		// Cannot receive DATA in these states
		return .Invalid_Frame_For_State
	}

	return .Protocol_Error
}

// stream_send_data processes sending a DATA frame
stream_send_data :: proc(stream: ^Stream, data_length: int, end_stream: bool) -> Stream_Error {
	if stream == nil {
		return .Protocol_Error
	}

	// DATA frames are only valid in certain states
	switch stream.state {
	case .Open:
		// Check remote flow control window
		if stream.remote_window_size < i32(data_length) {
			return .Flow_Control_Error
		}
		stream.remote_window_size -= i32(data_length)

		if end_stream {
			stream.sent_end_stream = true
			if stream.recv_end_stream {
				stream.state = .Closed
			} else {
				stream.state = .Half_Closed_Local
			}
		}
		return .None

	case .Half_Closed_Remote:
		// Can still send data
		if stream.remote_window_size < i32(data_length) {
			return .Flow_Control_Error
		}
		stream.remote_window_size -= i32(data_length)

		if end_stream {
			stream.sent_end_stream = true
			stream.state = .Closed
		}
		return .None

	case .Idle, .Reserved_Local, .Reserved_Remote, .Half_Closed_Local, .Closed:
		// Cannot send DATA in these states
		return .Invalid_Frame_For_State
	}

	return .Protocol_Error
}

// stream_recv_rst processes receiving a RST_STREAM frame
stream_recv_rst :: proc(stream: ^Stream, error_code: u32) -> Stream_Error {
	if stream == nil {
		return .Protocol_Error
	}

	// RST_STREAM transitions any non-idle state to closed
	if stream.state == .Idle {
		return .Protocol_Error
	}

	stream.state = .Closed
	return .None
}

// stream_send_rst processes sending a RST_STREAM frame
stream_send_rst :: proc(stream: ^Stream, error_code: u32) -> Stream_Error {
	if stream == nil {
		return .Protocol_Error
	}

	// Can send RST_STREAM from any state except idle
	if stream.state == .Idle {
		return .Invalid_State_Transition
	}

	stream.state = .Closed
	return .None
}

// stream_recv_window_update processes receiving a WINDOW_UPDATE frame
stream_recv_window_update :: proc(stream: ^Stream, increment: i32) -> Stream_Error {
	if stream == nil {
		return .Protocol_Error
	}

	if increment <= 0 {
		return .Protocol_Error
	}

	// Check for overflow
	new_size := stream.remote_window_size + increment
	if new_size > max(i32) || new_size < 0 {
		return .Flow_Control_Error
	}

	stream.remote_window_size = new_size
	return .None
}

// stream_send_window_update processes sending a WINDOW_UPDATE frame
stream_send_window_update :: proc(stream: ^Stream, increment: i32) -> Stream_Error {
	if stream == nil {
		return .Protocol_Error
	}

	if increment <= 0 {
		return .Protocol_Error
	}

	// Check for overflow
	new_size := stream.window_size + increment
	if new_size > max(i32) || new_size < 0 {
		return .Flow_Control_Error
	}

	stream.window_size = new_size
	return .None
}

// stream_recv_priority processes receiving a PRIORITY frame
stream_recv_priority :: proc(stream: ^Stream, depends_on: u32, weight: u8, exclusive: bool) -> Stream_Error {
	if stream == nil {
		return .Protocol_Error
	}

	// Stream cannot depend on itself
	if depends_on == stream.id {
		return .Protocol_Error
	}

	// PRIORITY can be received in any state (even closed)
	stream.priority_depends_on = depends_on
	stream.priority_weight = weight
	stream.priority_exclusive = exclusive

	return .None
}

// stream_can_send_data checks if the stream can send data based on state
stream_can_send_data :: proc(stream: ^Stream) -> bool {
	if stream == nil {
		return false
	}

	return stream.state == .Open || stream.state == .Half_Closed_Remote
}

// stream_can_recv_data checks if the stream can receive data based on state
stream_can_recv_data :: proc(stream: ^Stream) -> bool {
	if stream == nil {
		return false
	}

	return stream.state == .Open || stream.state == .Half_Closed_Local
}

// stream_is_closed checks if the stream is in closed state
stream_is_closed :: proc(stream: ^Stream) -> bool {
	if stream == nil {
		return true
	}

	return stream.state == .Closed
}

// stream_available_send_window returns how much data can be sent
stream_available_send_window :: proc(stream: ^Stream) -> i32 {
	if stream == nil {
		return 0
	}

	if stream.remote_window_size < 0 {
		return 0
	}

	return stream.remote_window_size
}

// stream_available_recv_window returns how much data can be received
stream_available_recv_window :: proc(stream: ^Stream) -> i32 {
	if stream == nil {
		return 0
	}

	if stream.window_size < 0 {
		return 0
	}

	return stream.window_size
}
