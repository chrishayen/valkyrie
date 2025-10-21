package valkyrie

import "core:fmt"
import "core:os"
import "core:strconv"

// Server_Args contains all command-line arguments for the HTTP/2 server
Server_Args :: struct {
	host:            string,
	port:            int,
	max_connections: int,
	enable_tls:      bool,
	cert_path:       string,
	key_path:        string,
	num_workers:     int,
	log_level:       Log_Level,
	show_help:       bool,
}

// parse_args parses command-line arguments and returns a Server_Args struct
parse_args :: proc() -> Server_Args {
	args := Server_Args {
		host            = "0.0.0.0",
		port            = 8080,
		max_connections = 1024,
		enable_tls      = false,
		cert_path       = "",
		key_path        = "",
		num_workers     = DEFAULT_NUM_REACTORS,
		log_level       = .INFO,
		show_help       = false,
	}

	cmd_args := os.args[1:]
	for i := 0; i < len(cmd_args); i += 1 {
		arg := cmd_args[i]

		switch arg {
		case "-h", "--host":
			if i + 1 < len(cmd_args) {
				i += 1
				args.host = cmd_args[i]
			}
		case "-p", "--port":
			if i + 1 < len(cmd_args) {
				i += 1
				port_val, ok := strconv.parse_int(cmd_args[i])
				if ok {
					args.port = port_val
				}
			}
		case "-m", "--max-connections":
			if i + 1 < len(cmd_args) {
				i += 1
				max_val, ok := strconv.parse_int(cmd_args[i])
				if ok {
					args.max_connections = max_val
				}
			}
		case "-w", "--workers":
			if i + 1 < len(cmd_args) {
				i += 1
				workers_val, ok := strconv.parse_int(cmd_args[i])
				if ok {
					args.num_workers = workers_val
				}
			}
		case "--tls":
			args.enable_tls = true
		case "--cert":
			if i + 1 < len(cmd_args) {
				i += 1
				args.cert_path = cmd_args[i]
			}
		case "--key":
			if i + 1 < len(cmd_args) {
				i += 1
				args.key_path = cmd_args[i]
			}
		case "--log-level":
			if i + 1 < len(cmd_args) {
				i += 1
				switch cmd_args[i] {
				case "debug":
					args.log_level = .DEBUG
				case "info":
					args.log_level = .INFO
				case "warn":
					args.log_level = .WARN
				case "error":
					args.log_level = .ERROR
				case "none":
					args.log_level = .NONE
				}
			}
		case "--help":
			args.show_help = true
		}
	}

	return args
}
