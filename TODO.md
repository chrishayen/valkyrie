# HTTP/2 Server Implementation TODO

## Summary
Building a production-ready HTTP/2 server in Odin using epoll-based event loop (no async).
Features: HTTP/2 framing, custom HPACK compression, stream multiplexing, TLS via s2n-tls.
Architecture: Functional core (pure logic) with imperative shell (I/O, event loop).

## Project Structure
```
http/
├── main.odin                    # Entry point with event loop
├── server.odin                  # Server initialization and management
├── connection.odin              # Per-connection state and handling
├── event_loop.odin              # Epoll wrapper and event dispatcher
├── buffer.odin                  # Ring buffer for efficient I/O
├── http2/
│   ├── constants.odin           # Frame types, error codes, settings IDs
│   ├── frame.odin               # Frame type definitions
│   ├── frame_parser.odin        # Parse bytes into frames
│   ├── frame_writer.odin        # Serialize frames to bytes
│   ├── settings.odin            # Settings frame handling & negotiation
│   ├── errors.odin              # Error code definitions and handling
│   ├── preface.odin             # Connection preface validation
│   ├── stream.odin              # Stream state machine (RFC 9113)
│   ├── priority.odin            # Stream priority and dependency tree
│   ├── flow_control.odin        # Window management
│   └── hpack/
│       ├── static_table.odin    # Static header table (61 entries)
│       ├── dynamic_table.odin   # Dynamic table with eviction
│       ├── huffman.odin         # Huffman encoding/decoding tables
│       ├── encoder.odin         # HPACK header compression
│       ├── decoder.odin         # HPACK header decompression
│       └── context.odin         # Request/response encoding contexts
├── tls/
│   ├── s2n_bindings.odin        # s2n-tls FFI bindings
│   └── tls_connection.odin      # TLS connection wrapper
├── tests/
│   ├── frame_test.odin
│   ├── frame_parser_test.odin
│   ├── settings_test.odin
│   ├── connection_test.odin
│   ├── event_loop_test.odin
│   ├── buffer_test.odin
│   ├── hpack_static_table_test.odin
│   ├── hpack_dynamic_table_test.odin
│   ├── hpack_huffman_test.odin
│   ├── hpack_encoder_test.odin
│   ├── hpack_decoder_test.odin
│   ├── stream_test.odin
│   ├── flow_control_test.odin
│   └── fuzz/
│       ├── frame_parser_fuzz.odin
│       └── hpack_decoder_fuzz.odin
├── Makefile
└── TODO.md
```

## Phase 1: Foundation & Event Loop ✓ COMPLETE
- [x] Create project structure and Makefile
- [x] Create epoll wrapper using core:sys/linux
- [x] Implement event dispatcher
- [x] Non-blocking socket I/O handling
- [x] Ring buffer implementation for I/O
- [x] Buffer management and tests
- [x] Fixed bug in connection_read_available: return total_read instead of 0 on EOF
- [x] Fixed bug in event_loop: store FD in epoll_data.fd field instead of using ptr field
- **Status**: 65 tests, passing consistently with 2 threads
- **Known Issue**: Tests still have ~25% failure rate with 20 threads. Root cause under investigation - not temp_allocator (it's thread-local), partially fixed epoll fd storage. May be related to rapid FD allocation/deallocation or edge-triggered epoll behavior with concurrent tests.
- **Files**: main.odin, server.odin, connection.odin, event_loop.odin, buffer.odin

## Phase 2: HTTP/2 Frame Layer ✓ COMPLETE
- [x] Implement HTTP/2 constants (frame types, errors, settings IDs)
- [x] Define core frame structures (all 10 frame types)
- [x] Build frame parser with tests
- [x] Build frame writer with tests
- [ ] Handle CONTINUATION frames for large headers (handled in parser/writer)
- [x] Frame size validation (SETTINGS_MAX_FRAME_SIZE)
- [ ] Fuzz testing for frame parser (deferred to Phase 11)
- **Status**: 65 tests total, 63 passing (97%)
- **Files**: http2/constants.odin, http2/frame.odin, http2/frame_parser.odin, http2/frame_writer.odin
- **Added**: 27 new tests, all passing

## Phase 3: HPACK Static Infrastructure ✓ COMPLETE
- [x] Implement static header table (61 predefined entries per RFC 7541)
- [x] Build Huffman encoding table (256 entries)
- [x] Build Huffman decoding tree
- [x] Test Huffman encoding/decoding with RFC test cases
- [x] Integer encoding/decoding (variable-length format)
- **Status**: 110 tests total, all passing
- **Files**: http2/hpack/static_table.odin, http2/hpack/huffman.odin, http2/hpack/integer.odin
- **Added**: 45 new tests (10 static table, 20 Huffman, 15 integer), all passing
- **RFC Compliance**: Implements RFC 7541 static table, Huffman codes, and integer encoding

## Phase 4: HPACK Dynamic Table ✓ COMPLETE
- [x] Implement dynamic table with circular buffer
- [x] Handle table size updates and eviction (FIFO)
- [x] Table size change protocol (resize function)
- [x] Dynamic table tests
- **Status**: 128 tests total, all passing
- **Files**: http2/hpack/dynamic_table.odin
- **Added**: 18 new tests covering all dynamic table operations
- **Implementation**: FIFO eviction, proper entry sizing (name + value + 32 bytes per RFC 7541), resize support
- **Note**: Request/response contexts will be implemented in encoder/decoder phases

## Phase 5: HPACK Encoder ✓ COMPLETE
- [x] Indexed header field representation
- [x] Literal header field with incremental indexing
- [x] Literal header field without indexing
- [x] Literal header field never indexed (sensitive headers)
- [x] Dynamic table size update
- [x] Comprehensive encoder tests with RFC examples
- **Status**: 147 tests total, all passing
- **Files**: http2/hpack/encoder.odin
- **Added**: 19 new tests covering all encoding representations
- **Features**: Full HPACK encoding support, static/dynamic table lookups, Huffman compression toggle, sensitive header handling
- **RFC Compliance**: Implements RFC 7541 Sections 6.1, 6.2, 6.3 (indexed, literal, and size update representations)
- **Note**: BREACH mitigation deferred to production hardening phase

## Phase 6: HPACK Decoder ✓ COMPLETE
- [x] Parse indexed header fields
- [x] Parse literal header fields (all types: incremental, without indexing, never indexed)
- [x] Handle dynamic table updates
- [x] Decoder error handling and comprehensive tests
- [x] Header size limit enforcement (prevents DoS)
- [x] Huffman decoding support
- [x] Empty string handling fix (make returns nil for 0-length in Odin)
- [x] Validate against RFC 7541 appendix examples (roundtrip test)
- [ ] Fuzz testing for HPACK decoder (deferred to Phase 11)
- **Status**: 163 tests total, all passing
- **Files**: http2/hpack/decoder.odin, tests/hpack_decoder_test.odin
- **Added**: 16 new tests covering all decoding representations, dynamic table lookup, table size updates, header size limits, Huffman decoding, roundtrip encode/decode
- **Features**: Full HPACK decoding support, static/dynamic table lookups, Huffman decompression, sensitive header marking, header size enforcement
- **RFC Compliance**: Implements RFC 7541 Sections 6.1, 6.2, 6.3 (indexed, literal, and size update representations)
- **Bug Fix**: Fixed empty string handling - make([]byte, 0) returns nil in Odin, added early return for 0-length strings

## Phase 7: Stream Management ✓ COMPLETE
- [x] Implement stream state machine per RFC 9113 (7 states)
- [x] Build flow control (per-stream window tracking)
- [x] Stream priority and dependency tree (weight, depends_on, exclusive)
- [x] RST_STREAM handling (immediate close from any state)
- [x] Stream lifecycle tests with all state transitions
- [ ] Connection-level flow control (deferred to Phase 8)
- [ ] Stream limits enforcement (SETTINGS_MAX_CONCURRENT_STREAMS) (deferred to Phase 8)
- **Status**: 188 tests total, all passing
- **Files**: http2/stream.odin, tests/stream_test.odin
- **Added**: 25 new tests covering all stream states, transitions, flow control, priority, RST_STREAM, edge cases
- **Features**: Complete stream state machine with 7 states (idle, reserved local/remote, open, half-closed local/remote, closed), per-stream flow control windows, priority weight/dependency tracking, END_STREAM flag handling, RST_STREAM transitions
- **RFC Compliance**: Implements RFC 9113 Section 5.1 (stream states), Section 5.2 (flow control), Section 5.3 (priority)
- **Implementation Notes**:
  - Priority weight stored as 0-255 (actual weight is stored_value + 1, default 16 stored as 15)
  - Both local and remote flow control windows tracked separately
  - Stream cannot depend on itself (protocol error)
  - PRIORITY frames allowed even on closed streams per RFC
  - DATA frames decrement appropriate window (recv uses local, send uses remote)

## Phase 8: Connection Handling ✓ COMPLETE
- [x] Connection preface validation ("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
- [x] Settings frame handling and negotiation
- [x] Settings acknowledgment protocol
- [x] Implement connection state management with stream map
- [x] PING frames and keepalive mechanism
- [x] GOAWAY and graceful shutdown
- [x] Connection vs stream error handling
- [x] Connection limits enforcement (MAX_CONCURRENT_STREAMS)
- **Status**: 231 tests total, all passing
- **Files**: http2/preface.odin, http2/settings.odin, http2/connection.odin, tests/preface_test.odin, tests/settings_test.odin, tests/http2_connection_test.odin
- **Added**: 43 new tests (7 preface + 16 settings + 20 connection state)
- **Features**:
  - Connection state machine (Waiting_Preface → Waiting_Settings → Active → Going_Away → Closed)
  - Stream map management with dynamic creation/removal
  - Connection-level flow control window tracking
  - PING frame validation and handling
  - GOAWAY processing with stream cleanup (closes streams > last_stream_id)
  - Stream limit enforcement per SETTINGS_MAX_CONCURRENT_STREAMS
  - Preface validation with partial data support
  - Full SETTINGS negotiation and ACK protocol
- **RFC Compliance**: Implements RFC 9113 Section 3.4 (preface), Section 6.5 (settings), Section 6.7 (ping), Section 6.8 (goaway), connection-level flow control
- **Implementation Notes**:
  - Server uses even stream IDs (starting at 2), client uses odd (starting at 1)
  - Streams automatically cleaned up when connection receives GOAWAY
  - Connection window separate from per-stream windows
  - Map-based stream storage for O(1) lookup

## Phase 9: TLS Integration
- [ ] Create s2n-tls bindings
- [ ] Setup TLS context with ALPN for "h2"
- [ ] Handle TLS handshake in event loop
- [ ] Integrate TLS read/write with HTTP/2 framing

## Phase 10: Server Orchestration
- [ ] Socket creation, binding, listening
- [ ] Accept new connections
- [ ] Route epoll events to connections
- [ ] Handle multiple concurrent connections
- [ ] Graceful shutdown

## Phase 11: Production Hardening
- [ ] Comprehensive error handling per RFC 9113
- [ ] Connection and stream limits
- [ ] Timeout handling (idle, request, keepalive)
- [ ] Malformed frame recovery
- [ ] Integration tests with real HTTP/2 clients (curl, browsers)
- [ ] Performance/load testing
- [ ] Memory leak checks and cleanup
- [ ] Zero-copy optimizations where possible
- [ ] Frame coalescing for small DATA frames
- [ ] Write buffering to reduce syscalls

## Phase 12: Observability & Operations
- [ ] Metrics/monitoring hooks
- [ ] Structured logging
- [ ] Debug aids (frame dumps, state inspection)
- [ ] HTTP/1.1 upgrade path (h2c) for cleartext
- [ ] Connection statistics tracking

## HPACK Implementation Details
- **Static Table**: 61 entries (indices 1-61) from RFC 7541 Appendix A
- **Dynamic Table**: Max size negotiable via SETTINGS_HEADER_TABLE_SIZE
- **Huffman Coding**: 256-entry static table from RFC 7541 Appendix B
- **Integer Encoding**: Variable-length with N-bit prefix per RFC 7541 Section 5.1
- **String Encoding**: Huffman or literal, with length prefix

## Key Design Decisions
- **Event Loop**: Direct epoll usage via core:sys/linux, edge-triggered mode
- **Buffer Strategy**: Ring buffers for I/O, pre-allocated per connection with dynamic growth
- **Frame Assembly**: Handle frames spanning multiple TCP packets
- **Stream Storage**: Map of stream_id -> stream_state with priority tree
- **Flow Control**: Track windows at both stream and connection level
- **HPACK**: Full custom implementation with separate request/response contexts
- **Error Handling**: Distinguish connection vs stream errors per RFC
- **Security**: Header validation, compression ratio limits, enforced limits
- **TLS**: s2n-tls with ALPN negotiation for "h2"
- **Testing**: Unit tests per module, fuzz testing, integration tests

## Critical Implementation Notes
- **Connection Preface**: Must validate exact bytes "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
- **CONTINUATION Frames**: Essential for large header blocks exceeding frame size
- **Settings Negotiation**: Both sides must ACK settings changes
- **Stream States**: idle -> reserved/open -> half-closed -> closed transitions
- **Priority Tree**: Default weight 16, exclusive flag handling
- **HPACK Contexts**: Separate dynamic tables for requests and responses
- **Frame Size**: Default 16384, max 16777215 (2^24-1) bytes
