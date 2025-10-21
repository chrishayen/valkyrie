package valkyrie

// Odin bindings for wolfSSL
// https://github.com/wolfSSL/wolfssl

import "core:c"

// Return codes
WOLFSSL_SUCCESS :: 1
WOLFSSL_FAILURE :: 0

// Error codes
WOLFSSL_ERROR_WANT_READ :: 2
WOLFSSL_ERROR_WANT_WRITE :: 3
WOLFSSL_ERROR_ZERO_RETURN :: 6

// File types
WOLFSSL_FILETYPE_PEM :: 1
WOLFSSL_FILETYPE_ASN1 :: 2

// Opaque types
WOLFSSL_CTX :: struct {}
WOLFSSL :: struct {}
WOLFSSL_METHOD :: struct {}

foreign import wolfssl "system:wolfssl"

@(default_calling_convention = "c")
foreign wolfssl {
	// Initialization
	wolfSSL_Init :: proc() -> c.int ---
	wolfSSL_Cleanup :: proc() -> c.int ---

	// Method selection
	wolfTLSv1_3_server_method :: proc() -> ^WOLFSSL_METHOD ---
	wolfSSLv23_server_method :: proc() -> ^WOLFSSL_METHOD ---

	// Context management
	wolfSSL_CTX_new :: proc(method: ^WOLFSSL_METHOD) -> ^WOLFSSL_CTX ---
	wolfSSL_CTX_free :: proc(ctx: ^WOLFSSL_CTX) ---

	// Certificate configuration
	wolfSSL_CTX_use_certificate_file :: proc(
		ctx: ^WOLFSSL_CTX,
		file: cstring,
		format: c.int,
	) -> c.int ---

	wolfSSL_CTX_use_PrivateKey_file :: proc(
		ctx: ^WOLFSSL_CTX,
		file: cstring,
		format: c.int,
	) -> c.int ---

	wolfSSL_CTX_use_certificate_chain_file :: proc(ctx: ^WOLFSSL_CTX, file: cstring) -> c.int ---

	// ALPN configuration
	wolfSSL_UseALPN :: proc(
		ssl: ^WOLFSSL,
		protocol_name_list: cstring,
		protocol_name_listSz: c.uint,
		options: byte,
	) -> c.int ---

	wolfSSL_ALPN_GetProtocol :: proc(
		ssl: ^WOLFSSL,
		protocol_name: ^cstring,
		size: ^c.ushort,
	) -> c.int ---

	// Session cache configuration
	wolfSSL_CTX_set_session_cache_mode :: proc(ctx: ^WOLFSSL_CTX, mode: c.long) -> c.long ---

	// Session ticket configuration
	wolfSSL_CTX_NoTicketTLSv12 :: proc(ctx: ^WOLFSSL_CTX) -> c.int ---
	wolfSSL_UseSessionTicket :: proc(ssl: ^WOLFSSL) -> c.int ---

	// Connection management
	wolfSSL_new :: proc(ctx: ^WOLFSSL_CTX) -> ^WOLFSSL ---
	wolfSSL_free :: proc(ssl: ^WOLFSSL) ---
	wolfSSL_set_fd :: proc(ssl: ^WOLFSSL, fd: c.int) -> c.int ---

	// TLS handshake
	wolfSSL_accept :: proc(ssl: ^WOLFSSL) -> c.int ---

	// I/O operations
	wolfSSL_write :: proc(ssl: ^WOLFSSL, data: rawptr, sz: c.int) -> c.int ---
	wolfSSL_read :: proc(ssl: ^WOLFSSL, data: rawptr, sz: c.int) -> c.int ---

	// Connection shutdown
	wolfSSL_shutdown :: proc(ssl: ^WOLFSSL) -> c.int ---

	// Error handling
	wolfSSL_get_error :: proc(ssl: ^WOLFSSL, ret: c.int) -> c.int ---
	wolfSSL_ERR_error_string :: proc(err: c.ulong, buf: [^]byte) -> cstring ---
	wolfSSL_ERR_reason_error_string :: proc(err: c.ulong) -> cstring ---

	// Non-blocking I/O support
	wolfSSL_set_using_nonblock :: proc(ssl: ^WOLFSSL, nonblock: c.int) ---
	wolfSSL_get_using_nonblock :: proc(ssl: ^WOLFSSL) -> c.int ---
}

// Session cache modes
SSL_SESS_CACHE_OFF :: 0x0000
SSL_SESS_CACHE_CLIENT :: 0x0001
SSL_SESS_CACHE_SERVER :: 0x0002
SSL_SESS_CACHE_BOTH :: 0x0003
SSL_SESS_CACHE_NO_AUTO_CLEAR :: 0x0080
SSL_SESS_CACHE_NO_INTERNAL_LOOKUP :: 0x0100
SSL_SESS_CACHE_NO_INTERNAL_STORE :: 0x0200
SSL_SESS_CACHE_NO_INTERNAL :: 0x0300

// ALPN options
WOLFSSL_ALPN_CONTINUE_ON_MISMATCH :: 0x01
WOLFSSL_ALPN_FAILED_ON_MISMATCH :: 0x02
