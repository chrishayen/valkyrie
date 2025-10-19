package main

import hpack "../../http2/hpack"
import "core:fmt"
import "core:time"

main :: proc() {
	fmt.println("=== HPACK Benchmark ===\n")

	benchmark_encode_static_headers()
	benchmark_encode_dynamic_headers()
	benchmark_encode_with_huffman()
	benchmark_encode_without_huffman()
	benchmark_decode()
	benchmark_roundtrip()

	fmt.println("\n=== Benchmark Complete ===")
}

benchmark_encode_static_headers :: proc() {
	fmt.println("--- Encoding Static Headers (common HTTP headers) ---")

	headers := []hpack.Header{
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":path", value = "/"},
		{name = ":authority", value = "example.com"},
		{name = "accept", value = "*/*"},
		{name = "accept-encoding", value = "gzip, deflate"},
		{name = "user-agent", value = "benchmark/1.0"},
	}

	encoder, enc_ok := hpack.encoder_init(4096, true)
	if !enc_ok {
		fmt.println("Failed to initialize encoder")
		return
	}
	defer hpack.encoder_destroy(&encoder)

	iterations :: 100_000
	start := time.now()

	for i in 0 ..< iterations {
		encoded, ok := hpack.encoder_encode_headers(&encoder, headers)
		if !ok {
			fmt.println("Encoding failed")
			return
		}
		delete(encoded)
	}

	duration := time.duration_seconds(time.since(start))
	throughput := f64(iterations) / duration

	fmt.printf("  Iterations: %d\n", iterations)
	fmt.printf("  Duration: %.3fs\n", duration)
	fmt.printf("  Throughput: %.0f encodes/sec\n", throughput)
	fmt.printf("  Latency: %.2f µs/encode\n\n", (duration * 1_000_000) / f64(iterations))
}

benchmark_encode_dynamic_headers :: proc() {
	fmt.println("--- Encoding Dynamic Headers (custom headers) ---")

	headers := []hpack.Header{
		{name = "x-custom-header", value = "custom-value-1"},
		{name = "x-request-id", value = "abc123def456"},
		{name = "x-trace-id", value = "trace-xyz-123"},
		{name = "x-user-session", value = "session-token-here"},
	}

	encoder, enc_ok := hpack.encoder_init(4096, true)
	if !enc_ok {
		fmt.println("Failed to initialize encoder")
		return
	}
	defer hpack.encoder_destroy(&encoder)

	iterations :: 100_000
	start := time.now()

	for i in 0 ..< iterations {
		encoded, ok := hpack.encoder_encode_headers(&encoder, headers)
		if !ok {
			fmt.println("Encoding failed")
			return
		}
		delete(encoded)
	}

	duration := time.duration_seconds(time.since(start))
	throughput := f64(iterations) / duration

	fmt.printf("  Iterations: %d\n", iterations)
	fmt.printf("  Duration: %.3fs\n", duration)
	fmt.printf("  Throughput: %.0f encodes/sec\n", throughput)
	fmt.printf("  Latency: %.2f µs/encode\n\n", (duration * 1_000_000) / f64(iterations))
}

benchmark_encode_with_huffman :: proc() {
	fmt.println("--- Encoding with Huffman ---")

	headers := []hpack.Header{
		{name = ":method", value = "POST"},
		{name = ":path", value = "/api/v1/users/profile"},
		{name = "content-type", value = "application/json"},
		{name = "authorization", value = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"},
	}

	encoder, enc_ok := hpack.encoder_init(4096, true)
	if !enc_ok {
		fmt.println("Failed to initialize encoder")
		return
	}
	defer hpack.encoder_destroy(&encoder)

	iterations :: 100_000
	start := time.now()

	for i in 0 ..< iterations {
		encoded, ok := hpack.encoder_encode_headers(&encoder, headers)
		if !ok {
			fmt.println("Encoding failed")
			return
		}
		delete(encoded)
	}

	duration := time.duration_seconds(time.since(start))
	throughput := f64(iterations) / duration

	fmt.printf("  Iterations: %d\n", iterations)
	fmt.printf("  Duration: %.3fs\n", duration)
	fmt.printf("  Throughput: %.0f encodes/sec\n", throughput)
	fmt.printf("  Latency: %.2f µs/encode\n\n", (duration * 1_000_000) / f64(iterations))
}

benchmark_encode_without_huffman :: proc() {
	fmt.println("--- Encoding without Huffman ---")

	headers := []hpack.Header{
		{name = ":method", value = "POST"},
		{name = ":path", value = "/api/v1/users/profile"},
		{name = "content-type", value = "application/json"},
		{name = "authorization", value = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"},
	}

	encoder, enc_ok := hpack.encoder_init(4096, false)
	if !enc_ok {
		fmt.println("Failed to initialize encoder")
		return
	}
	defer hpack.encoder_destroy(&encoder)

	iterations :: 100_000
	start := time.now()

	for i in 0 ..< iterations {
		encoded, ok := hpack.encoder_encode_headers(&encoder, headers)
		if !ok {
			fmt.println("Encoding failed")
			return
		}
		delete(encoded)
	}

	duration := time.duration_seconds(time.since(start))
	throughput := f64(iterations) / duration

	fmt.printf("  Iterations: %d\n", iterations)
	fmt.printf("  Duration: %.3fs\n", duration)
	fmt.printf("  Throughput: %.0f encodes/sec\n", throughput)
	fmt.printf("  Latency: %.2f µs/encode\n\n", (duration * 1_000_000) / f64(iterations))
}

benchmark_decode :: proc() {
	fmt.println("--- Decoding Headers ---")

	headers := []hpack.Header{
		{name = ":method", value = "GET"},
		{name = ":scheme", value = "https"},
		{name = ":path", value = "/"},
		{name = ":authority", value = "example.com"},
		{name = "accept", value = "*/*"},
	}

	encoder, enc_ok := hpack.encoder_init(4096, true)
	if !enc_ok {
		fmt.println("Failed to initialize encoder")
		return
	}
	defer hpack.encoder_destroy(&encoder)

	encoded, ok := hpack.encoder_encode_headers(&encoder, headers)
	if !ok {
		fmt.println("Failed to encode headers for benchmark")
		return
	}
	defer delete(encoded)

	decoder, dec_ok := hpack.decoder_init(4096)
	if !dec_ok {
		fmt.println("Failed to initialize decoder")
		return
	}
	defer hpack.decoder_destroy(&decoder)

	iterations :: 100_000
	start := time.now()

	for i in 0 ..< iterations {
		decoded, err := hpack.decoder_decode_headers(&decoder, encoded)
		if err != .None {
			fmt.printf("Decoding failed: %v\n", err)
			return
		}
		for header in decoded {
			delete(header.name)
			delete(header.value)
		}
		delete(decoded)
	}

	duration := time.duration_seconds(time.since(start))
	throughput := f64(iterations) / duration

	fmt.printf("  Iterations: %d\n", iterations)
	fmt.printf("  Duration: %.3fs\n", duration)
	fmt.printf("  Throughput: %.0f decodes/sec\n", throughput)
	fmt.printf("  Latency: %.2f µs/decode\n\n", (duration * 1_000_000) / f64(iterations))
}

benchmark_roundtrip :: proc() {
	fmt.println("--- Round-trip (Encode + Decode) ---")

	headers := []hpack.Header{
		{name = ":method", value = "POST"},
		{name = ":scheme", value = "https"},
		{name = ":path", value = "/api/v1/data"},
		{name = ":authority", value = "api.example.com"},
		{name = "content-type", value = "application/json"},
		{name = "accept", value = "application/json"},
		{name = "x-request-id", value = "req-123-456-789"},
	}

	encoder, enc_ok := hpack.encoder_init(4096, true)
	if !enc_ok {
		fmt.println("Failed to initialize encoder")
		return
	}
	defer hpack.encoder_destroy(&encoder)

	decoder, dec_ok := hpack.decoder_init(4096)
	if !dec_ok {
		fmt.println("Failed to initialize decoder")
		return
	}
	defer hpack.decoder_destroy(&decoder)

	iterations :: 100_000
	start := time.now()

	for i in 0 ..< iterations {
		encoded, enc_ok_iter := hpack.encoder_encode_headers(&encoder, headers)
		if !enc_ok_iter {
			fmt.println("Encoding failed")
			return
		}

		decoded, err := hpack.decoder_decode_headers(&decoder, encoded)
		if err != .None {
			fmt.printf("Decoding failed: %v\n", err)
			delete(encoded)
			return
		}

		for header in decoded {
			delete(header.name)
			delete(header.value)
		}
		delete(decoded)
		delete(encoded)
	}

	duration := time.duration_seconds(time.since(start))
	throughput := f64(iterations) / duration

	fmt.printf("  Iterations: %d\n", iterations)
	fmt.printf("  Duration: %.3fs\n", duration)
	fmt.printf("  Throughput: %.0f roundtrips/sec\n", throughput)
	fmt.printf("  Latency: %.2f µs/roundtrip\n\n", (duration * 1_000_000) / f64(iterations))
}
