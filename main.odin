package valkyrie

import "core:c"
import "core:fmt"

// Signal handling
foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	signal :: proc(sig: c.int, handler: rawptr) -> rawptr ---
}

SIG_IGN :: rawptr(uintptr(1))
SIGPIPE :: c.int(13)

// Constants
DEFAULT_NUM_REACTORS :: 20

main :: proc() {
	// Parse command-line arguments
	args := parse_args()

	if args.show_help {
		print_usage()
		return
	}

	// Setup signal handler
	signal(SIGPIPE, SIG_IGN)

	// CRITICAL: Call s2n_init() ONCE before forking
	// Each child will create its own TLS config but NOT call s2n_init() again
	if args.enable_tls {
		if !tls_global_init() {
			fmt.eprintln("Failed to initialize s2n-tls library")
			return
		}
	}

	// Determine number of reactor processes
	num_cores := args.num_workers > 0 ? args.num_workers : DEFAULT_NUM_REACTORS

	// Initialize main reactor
	main_reactor, ok := main_reactor_init(
		args.host,
		args.port,
		args.enable_tls,
		args.cert_path,
		args.key_path,
		num_cores,
	)
	if !ok {
		fmt.eprintln("Failed to initialize main reactor")
		return
	}
	defer main_reactor_shutdown(main_reactor)

	protocol := args.enable_tls ? "HTTPS" : "HTTP"
	fmt.printfln("%s/2 server listening on %s:%d", protocol, args.host, args.port)
	fmt.printfln("Max connections: %d", args.max_connections)
	fmt.printfln("Reactors (pinned to CPU cores): %d", num_cores)
	if args.enable_tls {
		fmt.printfln("TLS enabled (cert: %s, key: %s)", args.cert_path, args.key_path)
	}
	fmt.println("Press Ctrl+C to stop...")

	// Run the server (forks children and waits for signal)
	main_reactor_run(main_reactor)
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
	fmt.println("  -w, --workers <count>          Number of reactor threads (default: 20, one per CPU core)")
	fmt.println("  --tls                          Enable TLS/HTTPS")
	fmt.println(
		"  --cert <path>                  Path to TLS certificate (default: certs/server.crt)",
	)
	fmt.println(
		"  --key <path>                   Path to TLS private key (default: certs/server.key)",
	)
	fmt.println("  --help                         Show this help message")
}
