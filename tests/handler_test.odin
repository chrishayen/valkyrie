package valkyrie_tests

import "core:testing"
import http2 "../http2"
import "core:fmt"

@(test)
test_handle_request_body_not_empty :: proc(t: ^testing.T) {
	req := http2.Request{
		method = "GET",
		path = "/test",
		headers = nil,
		body = nil,
	}

	resp := http2.handle_request(&req)
	defer delete(resp.headers)

	testing.expectf(t, resp.status == 200, "Expected status 200, got %d", resp.status)
	testing.expectf(t, len(resp.body) > 0, "Expected non-empty body, got length %d", len(resp.body))
	testing.expectf(t, len(resp.body) == 15, "Expected body length 15, got %d", len(resp.body))

	fmt.printf("Response body length: %d\n", len(resp.body))
	fmt.printf("Response body: %v\n", resp.body)
	fmt.printf("Response body as string: %s\n", string(resp.body))
}
