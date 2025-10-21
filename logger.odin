package valkyrie

import "core:fmt"
import "core:time"

// Log_Level defines the severity levels for logging
Log_Level :: enum {
	DEBUG = 0,
	INFO  = 1,
	WARN  = 2,
	ERROR = 3,
	NONE  = 4,
}

// Global log level - can be set via command-line argument
global_log_level: Log_Level = .INFO

// set_log_level sets the global log level
set_log_level :: proc(level: Log_Level) {
	global_log_level = level
}

// log_debug logs a debug message
log_debug :: #force_inline proc(format: string, args: ..any) {
	if global_log_level > .DEBUG do return
	fmt.printf("[DEBUG] ")
	fmt.printfln(format, ..args)
}

// log_info logs an info message
log_info :: #force_inline proc(format: string, args: ..any) {
	if global_log_level > .INFO do return
	fmt.printf("[INFO ] ")
	fmt.printfln(format, ..args)
}

// log_warn logs a warning message
log_warn :: #force_inline proc(format: string, args: ..any) {
	if global_log_level > .WARN do return
	fmt.eprintf("[WARN ] ")
	fmt.eprintfln(format, ..args)
}

// log_error logs an error message
log_error :: #force_inline proc(format: string, args: ..any) {
	if global_log_level > .ERROR do return
	fmt.eprintf("[ERROR] ")
	fmt.eprintfln(format, ..args)
}
