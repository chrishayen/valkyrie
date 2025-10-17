package http

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/linux"
import "core:c"

// Signal handling
foreign import libc "system:c"

@(default_calling_convention="c")
foreign libc {
	signal :: proc(sig: c.int, handler: rawptr) -> rawptr ---
}

SIG_IGN :: rawptr(uintptr(1))
SIGPIPE :: c.int(13)

shutdown_requested := false

main :: proc() {
	// Parse command-line arguments
	host := "0.0.0.0"
	port := 8080
	max_connections := DEFAULT_MAX_CONNECTIONS
	enable_tls := false
	cert_path := "certs/server.crt"
	key_path := "certs/server.key"

	// Simple argument parsing
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		arg := args[i]

		switch arg {
		case "-h", "--host":
			if i + 1 < len(args) {
				i += 1
				host = args[i]
			}
		case "-p", "--port":
			if i + 1 < len(args) {
				i += 1
				port_val, ok := strconv.parse_int(args[i])
				if ok {
					port = port_val
				}
			}
		case "-m", "--max-connections":
			if i + 1 < len(args) {
				i += 1
				max_val, ok := strconv.parse_int(args[i])
				if ok {
					max_connections = max_val
				}
			}
		case "--tls":
			enable_tls = true
		case "--cert":
			if i + 1 < len(args) {
				i += 1
				cert_path = args[i]
			}
		case "--key":
			if i + 1 < len(args) {
				i += 1
				key_path = args[i]
			}
		case "--help":
			print_usage()
			return
		}
	}

	// Create server configuration
	config := Server_Config{
		host = host,
		port = port,
		max_connections = max_connections,
		backlog = DEFAULT_BACKLOG,
		enable_tls = enable_tls,
		cert_path = cert_path,
		key_path = key_path,
	}

	// Initialize server
	server, init_ok := server_init(config)
	if !init_ok {
		fmt.eprintln("Failed to initialize server")
		os.exit(1)
	}
	defer server_destroy(&server)

	// Bind to address
	if !server_bind(&server) {
		fmt.eprintfln("Failed to bind to %s:%d", config.host, config.port)
		os.exit(1)
	}

	// Start listening
	if !server_listen(&server) {
		fmt.eprintfln("Failed to listen on %s:%d", config.host, config.port)
		os.exit(1)
	}

	protocol := config.enable_tls ? "HTTPS" : "HTTP"
	fmt.printfln("%s/2 server listening on %s:%d", protocol, config.host, config.port)
	fmt.printfln("Max connections: %d", config.max_connections)
	if config.enable_tls {
		fmt.printfln("TLS enabled (cert: %s, key: %s)", config.cert_path, config.key_path)
	}
	fmt.println("Press Ctrl+C to stop...")

	// Setup signal handler for graceful shutdown
	setup_signal_handlers()

	// Run server
	if !server_run(&server) {
		fmt.eprintln("Server encountered an error")
		os.exit(1)
	}

	fmt.println("Server shutdown complete")
}

// print_usage displays usage information
print_usage :: proc() {
	fmt.println("HTTP/2 Server")
	fmt.println()
	fmt.println("Usage:")
	fmt.println("  http2_server [options]")
	fmt.println()
	fmt.println("Options:")
	fmt.println("  -h, --host <host>              Host to bind to (default: 0.0.0.0)")
	fmt.println("  -p, --port <port>              Port to listen on (default: 8080)")
	fmt.println("  -m, --max-connections <count>  Maximum concurrent connections (default: 1024)")
	fmt.println("  --tls                          Enable TLS/HTTPS")
	fmt.println("  --cert <path>                  Path to TLS certificate (default: certs/server.crt)")
	fmt.println("  --key <path>                   Path to TLS private key (default: certs/server.key)")
	fmt.println("  --help                         Show this help message")
}

// setup_signal_handlers configures signal handlers for graceful shutdown
setup_signal_handlers :: proc() {
	// Ignore SIGPIPE so we don't crash when clients disconnect abruptly
	signal(SIGPIPE, SIG_IGN)
}
