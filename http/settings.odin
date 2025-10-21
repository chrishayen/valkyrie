package http

import "base:runtime"

// Settings_Context maintains negotiated HTTP/2 settings
Settings_Context :: struct {
	// Local settings (what we've sent to peer)
	local_header_table_size:      u32,
	local_enable_push:            bool,
	local_max_concurrent_streams: u32,
	local_initial_window_size:    u32,
	local_max_frame_size:         u32,
	local_max_header_list_size:   u32,

	// Remote settings (what peer has sent to us)
	remote_header_table_size:      u32,
	remote_enable_push:            bool,
	remote_max_concurrent_streams: u32,
	remote_initial_window_size:    u32,
	remote_max_frame_size:         u32,
	remote_max_header_list_size:   u32,

	// Acknowledgment tracking
	local_settings_acked:  bool,
	remote_settings_acked: bool,

	allocator: runtime.Allocator,
}

// Settings_Error represents settings-related errors
Settings_Error :: enum {
	None,
	Invalid_Value,
	Flow_Control_Error,
	Frame_Size_Error,
}

// settings_init creates a new settings context with default values
settings_init :: proc(allocator := context.allocator) -> Settings_Context {
	return Settings_Context{
		// Default local settings (RFC 9113 Section 6.5.2)
		local_header_table_size = 4096,
		local_enable_push = false,  // Servers must not enable push
		local_max_concurrent_streams = 100,  // Conservative default
		local_initial_window_size = 65535,
		local_max_frame_size = 16384,
		local_max_header_list_size = 8192,

		// Default remote settings (assume defaults until peer sends SETTINGS)
		remote_header_table_size = 4096,
		remote_enable_push = true,  // Client default
		remote_max_concurrent_streams = 0xFFFFFFFF,  // Unlimited by default
		remote_initial_window_size = 65535,
		remote_max_frame_size = 16384,
		remote_max_header_list_size = 0xFFFFFFFF,  // Unlimited by default

		local_settings_acked = false,
		remote_settings_acked = false,

		allocator = allocator,
	}
}

// settings_destroy cleans up settings context
settings_destroy :: proc(ctx: ^Settings_Context) {
	if ctx == nil {
		return
	}
	// Nothing to free currently
}

// settings_apply_local updates local settings (we're sending to peer)
settings_apply_local :: proc(ctx: ^Settings_Context, id: Settings_ID, value: u32) -> Settings_Error {
	if ctx == nil {
		return .Invalid_Value
	}

	switch id {
	case .HEADER_TABLE_SIZE:
		ctx.local_header_table_size = value
		return .None

	case .ENABLE_PUSH:
		if value > 1 {
			return .Invalid_Value
		}
		ctx.local_enable_push = value == 1
		return .None

	case .MAX_CONCURRENT_STREAMS:
		ctx.local_max_concurrent_streams = value
		return .None

	case .INITIAL_WINDOW_SIZE:
		if value > 0x7FFFFFFF {  // 2^31 - 1
			return .Flow_Control_Error
		}
		ctx.local_initial_window_size = value
		return .None

	case .MAX_FRAME_SIZE:
		if value < 16384 || value > 16777215 {  // 2^14 to 2^24-1
			return .Frame_Size_Error
		}
		ctx.local_max_frame_size = value
		return .None

	case .MAX_HEADER_LIST_SIZE:
		ctx.local_max_header_list_size = value
		return .None
	}

	// Unknown settings are ignored per RFC
	return .None
}

// settings_apply_remote updates remote settings (peer sent to us)
settings_apply_remote :: proc(ctx: ^Settings_Context, id: Settings_ID, value: u32) -> Settings_Error {
	if ctx == nil {
		return .Invalid_Value
	}

	switch id {
	case .HEADER_TABLE_SIZE:
		ctx.remote_header_table_size = value
		return .None

	case .ENABLE_PUSH:
		if value > 1 {
			return .Invalid_Value
		}
		ctx.remote_enable_push = value == 1
		return .None

	case .MAX_CONCURRENT_STREAMS:
		ctx.remote_max_concurrent_streams = value
		return .None

	case .INITIAL_WINDOW_SIZE:
		if value > 0x7FFFFFFF {  // 2^31 - 1
			return .Flow_Control_Error
		}
		ctx.remote_initial_window_size = value
		return .None

	case .MAX_FRAME_SIZE:
		if value < 16384 || value > 16777215 {  // 2^14 to 2^24-1
			return .Frame_Size_Error
		}
		ctx.remote_max_frame_size = value
		return .None

	case .MAX_HEADER_LIST_SIZE:
		ctx.remote_max_header_list_size = value
		return .None
	}

	// Unknown settings are ignored per RFC
	return .None
}

// settings_mark_local_acked marks that peer acknowledged our SETTINGS
settings_mark_local_acked :: proc(ctx: ^Settings_Context) {
	if ctx == nil {
		return
	}
	ctx.local_settings_acked = true
}

// settings_mark_remote_acked marks that we acknowledged peer's SETTINGS
settings_mark_remote_acked :: proc(ctx: ^Settings_Context) {
	if ctx == nil {
		return
	}
	ctx.remote_settings_acked = true
}

// settings_get_local_window_size returns the local initial window size
settings_get_local_window_size :: proc(ctx: ^Settings_Context) -> u32 {
	if ctx == nil {
		return 65535
	}
	return ctx.local_initial_window_size
}

// settings_get_remote_window_size returns the remote initial window size
settings_get_remote_window_size :: proc(ctx: ^Settings_Context) -> u32 {
	if ctx == nil {
		return 65535
	}
	return ctx.remote_initial_window_size
}

// settings_get_local_max_frame_size returns the maximum frame size we will accept
settings_get_local_max_frame_size :: proc(ctx: ^Settings_Context) -> u32 {
	if ctx == nil {
		return 16384
	}
	return ctx.local_max_frame_size
}

// settings_get_remote_max_frame_size returns the maximum frame size peer will accept
settings_get_remote_max_frame_size :: proc(ctx: ^Settings_Context) -> u32 {
	if ctx == nil {
		return 16384
	}
	return ctx.remote_max_frame_size
}

// settings_get_local_max_concurrent_streams returns max concurrent streams we allow
settings_get_local_max_concurrent_streams :: proc(ctx: ^Settings_Context) -> u32 {
	if ctx == nil {
		return 100
	}
	return ctx.local_max_concurrent_streams
}

// settings_get_remote_max_concurrent_streams returns max concurrent streams peer allows
settings_get_remote_max_concurrent_streams :: proc(ctx: ^Settings_Context) -> u32 {
	if ctx == nil {
		return 100
	}
	return ctx.remote_max_concurrent_streams
}

// settings_can_push returns whether server push is enabled
settings_can_push :: proc(ctx: ^Settings_Context) -> bool {
	if ctx == nil {
		return false
	}
	return ctx.remote_enable_push
}

// settings_build_frame creates a SETTINGS frame with current local settings
settings_build_frame :: proc(ctx: ^Settings_Context, allocator := context.allocator) -> (frame: Settings_Frame, ok: bool) {
	if ctx == nil {
		return {}, false
	}

	settings := make([dynamic]Setting, 0, 6, allocator)

	append(&settings, Setting{id = .HEADER_TABLE_SIZE, value = ctx.local_header_table_size})
	append(&settings, Setting{id = .ENABLE_PUSH, value = u32(ctx.local_enable_push ? 1 : 0)})
	append(&settings, Setting{id = .MAX_CONCURRENT_STREAMS, value = ctx.local_max_concurrent_streams})
	append(&settings, Setting{id = .INITIAL_WINDOW_SIZE, value = ctx.local_initial_window_size})
	append(&settings, Setting{id = .MAX_FRAME_SIZE, value = ctx.local_max_frame_size})
	append(&settings, Setting{id = .MAX_HEADER_LIST_SIZE, value = ctx.local_max_header_list_size})

	return Settings_Frame{
		header = Frame_Header{
			length = u32(len(settings) * 6),  // Each setting is 6 bytes
			type = .SETTINGS,
			flags = 0,
			stream_id = 0,
		},
		settings = settings[:],
	}, true
}

// settings_build_ack_frame creates a SETTINGS frame with ACK flag
settings_build_ack_frame :: proc() -> Settings_Frame {
	frame := Settings_Frame{
		header = Frame_Header{
			length = 0,
			type = .SETTINGS,
			flags = SETTINGS_FLAG_ACK,
			stream_id = 0,
		},
		settings = nil,
	}
	return frame
}

// settings_is_ack checks if a SETTINGS frame is an acknowledgment
settings_is_ack :: proc(frame: ^Settings_Frame) -> bool {
	if frame == nil {
		return false
	}
	return (frame.header.flags & SETTINGS_FLAG_ACK) != 0
}
