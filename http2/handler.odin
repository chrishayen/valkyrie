package http2

import "core:fmt"
import hpack "hpack"

// Request represents a decoded HTTP/2 request
Request :: struct {
	method:  string,
	path:    string,
	headers: []hpack.Header,
	body:    []byte,
}

// Response represents an HTTP/2 response to send
Response :: struct {
	status:  int,
	headers: []hpack.Header,
	body:    []byte,
}

// request_decode decodes HEADERS frame into a Request
request_decode :: proc(decoder: ^hpack.Decoder_Context, header_block: []byte, allocator := context.allocator) -> (req: Request, ok: bool) {
	headers, err := hpack.decoder_decode_headers(decoder, header_block, allocator)
	if err != .None {
		return {}, false
	}

	req.headers = headers

	// Extract pseudo-headers
	for h in headers {
		if h.name == ":method" {
			req.method = h.value
		} else if h.name == ":path" {
			req.path = h.value
		}
	}

	return req, true
}

// request_destroy frees request resources
request_destroy :: proc(req: ^Request) {
	if req == nil {
		return
	}

	for h in req.headers {
		delete(h.name)
		delete(h.value)
	}
	delete(req.headers)
	delete(req.body)
}

// response_encode encodes a Response into HEADERS + DATA frames
response_encode :: proc(encoder: ^hpack.Encoder_Context, resp: ^Response, allocator := context.allocator) -> (headers: []byte, ok: bool) {
	if encoder == nil || resp == nil {
		return nil, false
	}

	// Build response headers
	response_headers := make([dynamic]hpack.Header, 0, 10, allocator)
	defer delete(response_headers)

	// Status pseudo-header
	status_str := fmt.aprintf("%d", resp.status, allocator = allocator)
	defer delete(status_str)

	append(&response_headers, hpack.Header{name = ":status", value = status_str})

	// Add custom headers
	if resp.headers != nil {
		for h in resp.headers {
			append(&response_headers, h)
		}
	}

	// Encode headers
	encoded, encode_ok := hpack.encoder_encode_headers(encoder, response_headers[:], allocator)
	if !encode_ok {
		return nil, false
	}

	return encoded, true
}

// handle_request processes an HTTP/2 request and returns a response
handle_request :: proc(req: ^Request, allocator := context.allocator) -> Response {
	// Simple echo handler - returns information about the request
	body_str := fmt.aprintf(
		"HTTP/2 Request Received\n\nMethod: %s\nPath: %s\n\nRequest Body Length: %d bytes\n",
		req.method,
		req.path,
		len(req.body),
		allocator = allocator,
	)
	defer delete(body_str)

	// Calculate actual content length
	content_length_str := fmt.aprintf("%d", len(body_str), allocator = allocator)

	// Build response headers
	headers := make([]hpack.Header, 2, allocator)
	headers[0] = hpack.Header{name = "content-type", value = "text/plain"}
	headers[1] = hpack.Header{name = "content-length", value = content_length_str}

	// Copy body for response
	body_bytes := make([]byte, len(body_str), allocator)
	copy(body_bytes, transmute([]byte)body_str)

	return Response{
		status = 200,
		headers = headers,
		body = body_bytes,
	}
}
