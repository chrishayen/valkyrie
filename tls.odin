package valkyrie

import "core:c"
import "core:fmt"
import "core:strings"

// TLS_Context holds wolfSSL configuration
TLS_Context :: struct {
	ctx:       ^WOLFSSL_CTX,
	cert_path: string,
	key_path:  string,
}

// TLS_Connection wraps a wolfSSL connection
TLS_Connection :: struct {
	ssl: ^WOLFSSL,
}

// tls_global_init initializes the wolfSSL library globally
// This MUST be called exactly once before forking child processes
tls_global_init :: proc() -> bool {
	if wolfSSL_Init() != WOLFSSL_SUCCESS {
		fmt.eprintln("Failed to initialize wolfSSL")
		return false
	}
	return true
}

// tls_config_new creates a new TLS config without calling wolfSSL_Init()
// This should be called in child processes after fork()
tls_config_new :: proc(
	cert_path: string,
	key_path: string,
	allocator := context.allocator,
) -> (
	ctx: TLS_Context,
	ok: bool,
) {
	// Create context using TLS 1.3 server method
	method := wolfTLSv1_3_server_method()
	if method == nil {
		fmt.eprintln("Failed to get wolfSSL server method")
		return {}, false
	}

	ssl_ctx := wolfSSL_CTX_new(method)
	if ssl_ctx == nil {
		fmt.eprintln("Failed to create wolfSSL context")
		return {}, false
	}

	// Convert paths to C strings
	cert_cstr := strings.clone_to_cstring(cert_path, allocator)
	defer delete(cert_cstr, allocator)

	key_cstr := strings.clone_to_cstring(key_path, allocator)
	defer delete(key_cstr, allocator)

	// Load certificate chain
	if wolfSSL_CTX_use_certificate_chain_file(ssl_ctx, cert_cstr) != WOLFSSL_SUCCESS {
		fmt.eprintfln("Failed to load certificate chain from: %s", cert_path)
		wolfSSL_CTX_free(ssl_ctx)
		return {}, false
	}

	// Load private key
	if wolfSSL_CTX_use_PrivateKey_file(ssl_ctx, key_cstr, WOLFSSL_FILETYPE_PEM) !=
	   WOLFSSL_SUCCESS {
		fmt.eprintfln("Failed to load private key from: %s", key_path)
		wolfSSL_CTX_free(ssl_ctx)
		return {}, false
	}

	// Enable session cache for performance
	wolfSSL_CTX_set_session_cache_mode(
		ssl_ctx,
		SSL_SESS_CACHE_SERVER | SSL_SESS_CACHE_NO_AUTO_CLEAR,
	)

	return TLS_Context{ctx = ssl_ctx, cert_path = cert_path, key_path = key_path}, true
}

// tls_init initializes the wolfSSL library and creates a TLS context
tls_init :: proc(
	cert_path: string,
	key_path: string,
	allocator := context.allocator,
) -> (
	ctx: TLS_Context,
	ok: bool,
) {
	// Initialize wolfSSL
	if wolfSSL_Init() != WOLFSSL_SUCCESS {
		fmt.eprintln("Failed to initialize wolfSSL")
		return {}, false
	}

	// Create context using TLS 1.3 server method
	method := wolfTLSv1_3_server_method()
	if method == nil {
		fmt.eprintln("Failed to get wolfSSL server method")
		return {}, false
	}

	ssl_ctx := wolfSSL_CTX_new(method)
	if ssl_ctx == nil {
		fmt.eprintln("Failed to create wolfSSL context")
		return {}, false
	}

	// Convert paths to C strings
	cert_cstr := strings.clone_to_cstring(cert_path, allocator)
	defer delete(cert_cstr, allocator)

	key_cstr := strings.clone_to_cstring(key_path, allocator)
	defer delete(key_cstr, allocator)

	// Load certificate chain
	if wolfSSL_CTX_use_certificate_chain_file(ssl_ctx, cert_cstr) != WOLFSSL_SUCCESS {
		fmt.eprintfln("Failed to load certificate chain from: %s", cert_path)
		wolfSSL_CTX_free(ssl_ctx)
		return {}, false
	}

	// Load private key
	if wolfSSL_CTX_use_PrivateKey_file(ssl_ctx, key_cstr, WOLFSSL_FILETYPE_PEM) !=
	   WOLFSSL_SUCCESS {
		fmt.eprintfln("Failed to load private key from: %s", key_path)
		wolfSSL_CTX_free(ssl_ctx)
		return {}, false
	}

	// Enable session cache for performance
	wolfSSL_CTX_set_session_cache_mode(
		ssl_ctx,
		SSL_SESS_CACHE_SERVER | SSL_SESS_CACHE_NO_AUTO_CLEAR,
	)

	return TLS_Context{ctx = ssl_ctx, cert_path = cert_path, key_path = key_path}, true
}

// tls_destroy cleans up TLS context
tls_destroy :: proc(ctx: ^TLS_Context) {
	if ctx.ctx != nil {
		wolfSSL_CTX_free(ctx.ctx)
		ctx.ctx = nil
	}
	wolfSSL_Cleanup()
}

// tls_connection_new creates a new TLS connection for a file descriptor
tls_connection_new :: proc(ctx: ^TLS_Context, fd: c.int) -> (tls_conn: TLS_Connection, ok: bool) {
	if ctx.ctx == nil {
		return {}, false
	}

	// Create new SSL connection
	ssl := wolfSSL_new(ctx.ctx)
	if ssl == nil {
		fmt.eprintln("Failed to create wolfSSL connection")
		return {}, false
	}

	// Set file descriptor
	if wolfSSL_set_fd(ssl, fd) != WOLFSSL_SUCCESS {
		fmt.eprintln("Failed to set file descriptor on wolfSSL connection")
		wolfSSL_free(ssl)
		return {}, false
	}

	// Enable session tickets for resumption
	if wolfSSL_UseSessionTicket(ssl) != WOLFSSL_SUCCESS {
		fmt.eprintln("Warning: Failed to enable session tickets")
	}

	// Set ALPN for HTTP/2
	alpn_list := "h2"
	alpn_cstr := strings.clone_to_cstring(alpn_list, context.temp_allocator)
	if wolfSSL_UseALPN(ssl, alpn_cstr, u32(len(alpn_list)), WOLFSSL_ALPN_FAILED_ON_MISMATCH) !=
	   WOLFSSL_SUCCESS {
		fmt.eprintln("Warning: Failed to set ALPN preferences")
	}

	return TLS_Connection{ssl = ssl}, true
}

// tls_connection_free frees a TLS connection
tls_connection_free :: proc(tls_conn: ^TLS_Connection) {
	if tls_conn.ssl != nil {
		wolfSSL_free(tls_conn.ssl)
		tls_conn.ssl = nil
	}
}

// TLS_Negotiate_Result represents the result of a TLS handshake attempt
TLS_Negotiate_Result :: enum {
	Success,
	WouldBlock_Read, // Need to read more data
	WouldBlock_Write, // Need to write data
	Error,
}

// tls_negotiate performs the TLS handshake (non-blocking)
// Returns Success if complete, WouldBlock_Read/Write if needs more I/O, Error on failure
tls_negotiate :: proc(tls_conn: ^TLS_Connection) -> TLS_Negotiate_Result {
	if tls_conn.ssl == nil {
		log_error("TLS negotiate: ssl is nil")
		return .Error
	}

	log_debug("TLS: Calling wolfSSL_accept")
	result := wolfSSL_accept(tls_conn.ssl)
	log_debug("TLS: wolfSSL_accept returned: %d", result)

	if result == WOLFSSL_SUCCESS {
		log_debug("TLS: Handshake SUCCESS")
		return .Success
	}

	// Check error code
	error := wolfSSL_get_error(tls_conn.ssl, result)

	if error == WOLFSSL_ERROR_WANT_READ {
		log_debug("TLS: Handshake blocked on READ")
		return .WouldBlock_Read
	}

	if error == WOLFSSL_ERROR_WANT_WRITE {
		log_debug("TLS: Handshake blocked on WRITE")
		return .WouldBlock_Write
	}

	// Error case
	error_str := wolfSSL_ERR_reason_error_string(u64(error))
	log_error("TLS: Handshake error: %s (error code: %d)", error_str, error)
	return .Error
}

// tls_send sends data over TLS connection
tls_send :: proc(tls_conn: ^TLS_Connection, data: []byte) -> int {
	if tls_conn.ssl == nil || len(data) == 0 {
		return 0
	}

	total_sent := 0

	for total_sent < len(data) {
		remaining := data[total_sent:]
		sent := wolfSSL_write(tls_conn.ssl, raw_data(remaining), c.int(len(remaining)))

		if sent > 0 {
			total_sent += int(sent)
		} else {
			error := wolfSSL_get_error(tls_conn.ssl, sent)

			if error == WOLFSSL_ERROR_WANT_WRITE || error == WOLFSSL_ERROR_WANT_READ {
				// Would block, return what we've sent so far
				break
			}

			if error == WOLFSSL_ERROR_ZERO_RETURN {
				// Connection closed
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
	if tls_conn.ssl == nil || len(buffer) == 0 {
		return 0
	}

	received := wolfSSL_read(tls_conn.ssl, raw_data(buffer), c.int(len(buffer)))

	if received > 0 {
		return int(received)
	}

	error := wolfSSL_get_error(tls_conn.ssl, received)

	if error == WOLFSSL_ERROR_WANT_READ || error == WOLFSSL_ERROR_WANT_WRITE {
		// Would block
		return 0
	}

	if error == WOLFSSL_ERROR_ZERO_RETURN {
		// Connection closed
		return 0
	}

	// Error
	return -1
}

// tls_shutdown gracefully shuts down TLS connection
tls_shutdown :: proc(tls_conn: ^TLS_Connection) {
	if tls_conn.ssl == nil {
		return
	}

	wolfSSL_shutdown(tls_conn.ssl)
}
