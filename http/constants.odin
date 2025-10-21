package http

// HTTP/2 Frame Types (RFC 9113 Section 6)
Frame_Type :: enum u8 {
	DATA          = 0x0,
	HEADERS       = 0x1,
	PRIORITY      = 0x2,
	RST_STREAM    = 0x3,
	SETTINGS      = 0x4,
	PUSH_PROMISE  = 0x5,
	PING          = 0x6,
	GOAWAY        = 0x7,
	WINDOW_UPDATE = 0x8,
	CONTINUATION  = 0x9,
}

// HTTP/2 Frame Flags (RFC 9113 Section 6)
Frame_Flag :: enum u8 {
	END_STREAM  = 0,  // 0x1
	END_HEADERS = 2,  // 0x4
	PADDED      = 3,  // 0x8
	PRIORITY    = 5,  // 0x20
}

Frame_Flags :: bit_set[Frame_Flag; u8]

// Settings-specific flags
Settings_Flag :: enum u8 {
	ACK = 0,  // 0x1
}

Settings_Flags :: bit_set[Settings_Flag; u8]

// Settings flag constants for direct use
SETTINGS_FLAG_ACK :: 0x1

// HTTP/2 Error Codes (RFC 9113 Section 7)
Error_Code :: enum u32 {
	NO_ERROR            = 0x0,
	PROTOCOL_ERROR      = 0x1,
	INTERNAL_ERROR      = 0x2,
	FLOW_CONTROL_ERROR  = 0x3,
	SETTINGS_TIMEOUT    = 0x4,
	STREAM_CLOSED       = 0x5,
	FRAME_SIZE_ERROR    = 0x6,
	REFUSED_STREAM      = 0x7,
	CANCEL              = 0x8,
	COMPRESSION_ERROR   = 0x9,
	CONNECT_ERROR       = 0xa,
	ENHANCE_YOUR_CALM   = 0xb,
	INADEQUATE_SECURITY = 0xc,
	HTTP_1_1_REQUIRED   = 0xd,
}

// HTTP/2 Settings Identifiers (RFC 9113 Section 6.5.2)
Settings_ID :: enum u16 {
	HEADER_TABLE_SIZE      = 0x1,
	ENABLE_PUSH            = 0x2,
	MAX_CONCURRENT_STREAMS = 0x3,
	INITIAL_WINDOW_SIZE    = 0x4,
	MAX_FRAME_SIZE         = 0x5,
	MAX_HEADER_LIST_SIZE   = 0x6,
}

// Default Settings Values (RFC 9113 Section 6.5.2)
DEFAULT_HEADER_TABLE_SIZE      :: 4096
DEFAULT_ENABLE_PUSH            :: 1
DEFAULT_MAX_CONCURRENT_STREAMS :: 0xFFFFFFFF  // Unlimited
DEFAULT_INITIAL_WINDOW_SIZE    :: 65535
DEFAULT_MAX_FRAME_SIZE         :: 16384
DEFAULT_MAX_HEADER_LIST_SIZE   :: 0xFFFFFFFF  // Unlimited

// Frame Size Limits (RFC 9113 Section 4.2)
MIN_FRAME_SIZE :: 16384        // 2^14
MAX_FRAME_SIZE :: 16777215     // 2^24 - 1
FRAME_HEADER_SIZE :: 9         // All frames have 9-byte header

// Connection Preface (RFC 9113 Section 3.4)
CONNECTION_PREFACE :: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
CONNECTION_PREFACE_LENGTH :: 24

// Stream Identifiers
STREAM_ID_MASK :: 0x7FFFFFFF  // 31 bits
RESERVED_BIT   :: 0x80000000  // Most significant bit (reserved)

// Window Size Limits
MIN_WINDOW_SIZE :: 0
MAX_WINDOW_SIZE :: 0x7FFFFFFF  // 2^31 - 1

// Priority Defaults
DEFAULT_WEIGHT :: 16
MIN_WEIGHT     :: 1
MAX_WEIGHT     :: 256
