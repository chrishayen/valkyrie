package http

import "core:fmt"
import http2 "http2"

// http2_connection_init initializes an HTTP/2 connection
http2_connection_init :: proc(conn: ^Connection, allocator := context.allocator) -> bool {
	if conn == nil {
		return false
	}

	// Create HTTP/2 protocol handler
	handler, ok := http2.protocol_handler_init(true, allocator)  // is_server = true
	if !ok {
		return false
	}

	// Store handler in user_data
	handler_ptr := new(http2.Protocol_Handler, allocator)
	handler_ptr^ = handler
	conn.user_data = handler_ptr

	// Don't send SETTINGS yet - wait for client preface first
	// Server SETTINGS will be sent after validating client preface

	return true
}

// http2_connection_destroy cleans up HTTP/2 connection
http2_connection_destroy :: proc(conn: ^Connection) {
	if conn == nil || conn.user_data == nil {
		return
	}

	handler := cast(^http2.Protocol_Handler)conn.user_data
	http2.protocol_handler_destroy(handler)
	free(handler)
	conn.user_data = nil
}

// http2_connection_process processes HTTP/2 protocol for a connection
http2_connection_process :: proc(conn: ^Connection) -> bool {
	if conn == nil || conn.user_data == nil {
		return false
	}

	handler := cast(^http2.Protocol_Handler)conn.user_data

	// Read available data from connection buffer
	available := connection_available_data(conn)
	if available > 0 {
		data, err := make([]byte, available, context.temp_allocator)
		if err != nil {
			return false
		}

		bytes_read := connection_read_data(conn, data)
		if bytes_read > 0 {
			// Process the data through HTTP/2 protocol
			ok := http2.protocol_handler_process_data(handler, data[:bytes_read])
			if !ok {
				fmt.println("HTTP/2 protocol error")
				return false
			}
		}
	}

	// Check if there's data to write
	if http2.protocol_handler_needs_write(handler) {
		write_data := http2.protocol_handler_get_write_data(handler)
		if len(write_data) > 0 {
			bytes_queued := connection_queue_write(conn, write_data)
			http2.protocol_handler_consume_write_data(handler, bytes_queued)
		}
	}

	return true
}
