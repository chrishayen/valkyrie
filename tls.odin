package http

import "core:fmt"
import "core:os"
import "core:strings"
import "core:c"
import s2n "s2n"

// TLS_Context holds s2n configuration
TLS_Context :: struct {
	config: ^s2n.s2n_config,
}

// TLS_Connection wraps an s2n connection
TLS_Connection :: struct {
	s2n_conn: ^s2n.s2n_connection,
}

// tls_init initializes the s2n library and creates a TLS context
tls_init :: proc(cert_path: string, key_path: string, allocator := context.allocator) -> (ctx: TLS_Context, ok: bool) {
	// Initialize s2n-tls
	if s2n.s2n_init() != s2n.S2N_SUCCESS {
		fmt.eprintln("Failed to initialize s2n-tls")
		return {}, false
	}

	// Create config
	config := s2n.s2n_config_new()
	if config == nil {
		fmt.eprintln("Failed to create s2n config")
		return {}, false
	}

	// Read certificate and key files
	cert_data, cert_ok := os.read_entire_file(cert_path, allocator)
	if !cert_ok {
		fmt.eprintfln("Failed to read certificate file: %s", cert_path)
		s2n.s2n_config_free(config)
		return {}, false
	}
	defer delete(cert_data, allocator)

	key_data, key_ok := os.read_entire_file(key_path, allocator)
	if !key_ok {
		fmt.eprintfln("Failed to read key file: %s", key_path)
		s2n.s2n_config_free(config)
		return {}, false
	}
	defer delete(key_data, allocator)

	// Convert to C strings (must be null-terminated)
	cert_cstr := strings.clone_to_cstring(string(cert_data), allocator)
	defer delete(cert_cstr, allocator)

	key_cstr := strings.clone_to_cstring(string(key_data), allocator)
	defer delete(key_cstr, allocator)

	// Add certificate and key to config
	if s2n.s2n_config_add_cert_chain_and_key(config, cert_cstr, key_cstr) != s2n.S2N_SUCCESS {
		fmt.eprintln("Failed to add certificate and key to s2n config")
		s2n.s2n_config_free(config)
		return {}, false
	}

	// Set ALPN preferences for HTTP/2
	protocols := [1]cstring{"h2"}
	protocols_ptr := &protocols[0]
	if s2n.s2n_config_set_protocol_preferences(config, protocols_ptr, 1) != s2n.S2N_SUCCESS {
		fmt.eprintln("Failed to set ALPN protocol preferences")
		s2n.s2n_config_free(config)
		return {}, false
	}

	fmt.println("TLS initialized successfully with ALPN support (h2)")

	return TLS_Context{config = config}, true
}

// tls_destroy cleans up TLS context
tls_destroy :: proc(ctx: ^TLS_Context) {
	if ctx.config != nil {
		s2n.s2n_config_free(ctx.config)
		ctx.config = nil
	}
	s2n.s2n_cleanup()
}

// tls_connection_new creates a new TLS connection for a file descriptor
tls_connection_new :: proc(ctx: ^TLS_Context, fd: c.int) -> (tls_conn: TLS_Connection, ok: bool) {
	if ctx.config == nil {
		return {}, false
	}

	// Create s2n connection in server mode
	s2n_conn := s2n.s2n_connection_new(s2n.s2n_mode.SERVER)
	if s2n_conn == nil {
		fmt.eprintln("Failed to create s2n connection")
		return {}, false
	}

	// Set config
	if s2n.s2n_connection_set_config(s2n_conn, ctx.config) != s2n.S2N_SUCCESS {
		fmt.eprintln("Failed to set config on connection")
		s2n.s2n_connection_free(s2n_conn)
		return {}, false
	}

	// Set file descriptor
	if s2n.s2n_connection_set_fd(s2n_conn, fd) != s2n.S2N_SUCCESS {
		fmt.eprintln("Failed to set file descriptor on connection")
		s2n.s2n_connection_free(s2n_conn)
		return {}, false
	}

	return TLS_Connection{s2n_conn = s2n_conn}, true
}

// tls_connection_free frees a TLS connection
tls_connection_free :: proc(tls_conn: ^TLS_Connection) {
	if tls_conn.s2n_conn != nil {
		s2n.s2n_connection_free(tls_conn.s2n_conn)
		tls_conn.s2n_conn = nil
	}
}

// TLS_Negotiate_Result represents the result of a TLS handshake attempt
TLS_Negotiate_Result :: enum {
	Success,
	WouldBlock,
	Error,
}

// tls_negotiate performs the TLS handshake (non-blocking)
// Returns Success if complete, WouldBlock if needs more I/O, Error on failure
tls_negotiate :: proc(tls_conn: ^TLS_Connection) -> TLS_Negotiate_Result {
	if tls_conn.s2n_conn == nil {
		return .Error
	}

	blocked: s2n.s2n_blocked_status
	result := s2n.s2n_negotiate(tls_conn.s2n_conn, &blocked)

	if result == s2n.S2N_SUCCESS {
		// Handshake complete
		protocol := s2n.s2n_get_application_protocol(tls_conn.s2n_conn)
		if protocol != nil {
			fmt.printf("TLS handshake successful, negotiated protocol: %s\n", protocol)
		} else {
			fmt.println("TLS handshake successful")
		}
		return .Success
	}

	// Check if we need to retry
	if blocked == .BLOCKED_ON_READ || blocked == .BLOCKED_ON_WRITE {
		// Would block, need to retry later
		return .WouldBlock
	}

	// Error occurred - get detailed error information
	errno_ptr := s2n.s2n_errno_location()
	if errno_ptr != nil {
		error_code := errno_ptr^
		error_msg := s2n.s2n_strerror(error_code, "EN")
		error_debug := s2n.s2n_strerror_debug(error_code, "EN")
		fmt.eprintfln("TLS handshake failed:")
		fmt.eprintfln("  Error code: %d", error_code)
		fmt.eprintfln("  Error: %s", error_msg)
		fmt.eprintfln("  Debug: %s", error_debug)
		fmt.eprintfln("  Blocked status: %v", blocked)
	} else {
		fmt.eprintfln("TLS handshake failed, blocked status: %v", blocked)
	}
	return .Error
}

// tls_send sends data over TLS connection
tls_send :: proc(tls_conn: ^TLS_Connection, data: []byte) -> int {
	if tls_conn.s2n_conn == nil || len(data) == 0 {
		return 0
	}

	blocked: s2n.s2n_blocked_status
	total_sent := 0

	for total_sent < len(data) {
		remaining := data[total_sent:]
		sent := s2n.s2n_send(tls_conn.s2n_conn, raw_data(remaining), c.ssize_t(len(remaining)), &blocked)

		if sent > 0 {
			total_sent += int(sent)
		} else if sent == 0 {
			// Connection closed
			break
		} else {
			// Error or would block
			if blocked == .BLOCKED_ON_WRITE || blocked == .BLOCKED_ON_READ {
				// Would block, return what we've sent so far
				break
			}
			// Error
			return -1
		}
	}

	return total_sent
}

// tls_recv receives data from TLS connection
tls_recv :: proc(tls_conn: ^TLS_Connection, buffer: []byte) -> int {
	if tls_conn.s2n_conn == nil || len(buffer) == 0 {
		return 0
	}

	blocked: s2n.s2n_blocked_status
	received := s2n.s2n_recv(tls_conn.s2n_conn, raw_data(buffer), c.ssize_t(len(buffer)), &blocked)

	if received > 0 {
		return int(received)
	} else if received == 0 {
		// Connection closed
		return 0
	} else {
		// Error or would block
		if blocked == .BLOCKED_ON_READ || blocked == .BLOCKED_ON_WRITE {
			// Would block
			return 0
		}
		// Error
		return -1
	}
}

// tls_shutdown gracefully shuts down TLS connection
tls_shutdown :: proc(tls_conn: ^TLS_Connection) {
	if tls_conn.s2n_conn == nil {
		return
	}

	blocked: s2n.s2n_blocked_status
	s2n.s2n_shutdown(tls_conn.s2n_conn, &blocked)
}
