package s2n

// Odin bindings for s2n-tls (AWS's TLS library)
// https://github.com/aws/s2n-tls

import "core:c"

// Return codes
S2N_SUCCESS :: 0
S2N_FAILURE :: -1

// Connection mode
s2n_mode :: enum c.int {
	SERVER = 0,
	CLIENT = 1,
}

// Blocked status for non-blocking I/O
s2n_blocked_status :: enum c.int {
	NOT_BLOCKED = 0,
	BLOCKED_ON_READ = 1,
	BLOCKED_ON_WRITE = 2,
	BLOCKED_ON_APPLICATION_INPUT = 3,
	BLOCKED_ON_EARLY_DATA = 4,
}

// Opaque types
s2n_config :: struct {}
s2n_connection :: struct {}

foreign import s2n "system:s2n"

@(default_calling_convention="c")
foreign s2n {
	// Initialization
	s2n_init :: proc() -> c.int ---
	s2n_cleanup :: proc() -> c.int ---

	// Config management
	s2n_config_new :: proc() -> ^s2n_config ---
	s2n_config_free :: proc(config: ^s2n_config) -> c.int ---

	// Certificate configuration
	s2n_config_add_cert_chain_and_key :: proc(
		config: ^s2n_config,
		cert_chain_pem: cstring,
		private_key_pem: cstring,
	) -> c.int ---

	// ALPN configuration (for HTTP/2 negotiation)
	s2n_config_set_protocol_preferences :: proc(
		config: ^s2n_config,
		protocols: [^]cstring,
		protocol_count: c.int,
	) -> c.int ---

	// Connection management
	s2n_connection_new :: proc(mode: s2n_mode) -> ^s2n_connection ---
	s2n_connection_free :: proc(conn: ^s2n_connection) -> c.int ---
	s2n_connection_set_config :: proc(conn: ^s2n_connection, config: ^s2n_config) -> c.int ---
	s2n_connection_set_fd :: proc(conn: ^s2n_connection, fd: c.int) -> c.int ---

	// TLS handshake
	s2n_negotiate :: proc(conn: ^s2n_connection, blocked: ^s2n_blocked_status) -> c.int ---

	// I/O operations
	s2n_send :: proc(
		conn: ^s2n_connection,
		buf: rawptr,
		size: c.ssize_t,
		blocked: ^s2n_blocked_status,
	) -> c.ssize_t ---

	s2n_recv :: proc(
		conn: ^s2n_connection,
		buf: rawptr,
		size: c.ssize_t,
		blocked: ^s2n_blocked_status,
	) -> c.ssize_t ---

	// ALPN result
	s2n_get_application_protocol :: proc(conn: ^s2n_connection) -> cstring ---

	// Connection shutdown
	s2n_shutdown :: proc(conn: ^s2n_connection, blocked: ^s2n_blocked_status) -> c.int ---

	// Error handling
	s2n_errno_location :: proc() -> ^c.int ---
	s2n_strerror :: proc(error: c.int, lang: cstring) -> cstring ---
	s2n_strerror_debug :: proc(error: c.int, lang: cstring) -> cstring ---
}
