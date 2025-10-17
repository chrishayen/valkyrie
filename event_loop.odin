package http

import "core:sys/linux"
import "core:c"

// Event_Type represents types of events we care about
Event_Type :: enum {
	Read,
	Write,
	Error,
	HangUp,
}

// Event_Flags is a set of event types
Event_Flags :: bit_set[Event_Type]

// Event represents an I/O event from epoll
Event :: struct {
	fd:    linux.Fd,
	flags: Event_Flags,
	data:  rawptr,
}

// Event_Loop manages epoll-based event handling
Event_Loop :: struct {
	epoll_fd:     linux.Fd,
	max_events:   int,
	events:       []linux.EPoll_Event,
}

// event_loop_init creates a new event loop
event_loop_init :: proc(max_events := 128) -> (el: Event_Loop, ok: bool) {
	if max_events <= 0 {
		return {}, false
	}

	// Create epoll instance
	epoll_fd, epoll_err := linux.epoll_create1({})
	if epoll_err != .NONE {
		return {}, false
	}

	// Allocate event buffer
	events, events_err := make([]linux.EPoll_Event, max_events)
	if events_err != nil {
		linux.close(epoll_fd)
		return {}, false
	}

	return Event_Loop{
		epoll_fd = epoll_fd,
		max_events = max_events,
		events = events,
	}, true
}

// event_loop_destroy cleans up event loop resources
event_loop_destroy :: proc(el: ^Event_Loop) {
	if el.epoll_fd >= 0 {
		linux.close(el.epoll_fd)
		el.epoll_fd = -1
	}

	if el.events != nil {
		delete(el.events)
		el.events = nil
	}

	el.max_events = 0
}

// event_loop_add registers a file descriptor with the event loop
event_loop_add :: proc(el: ^Event_Loop, fd: linux.Fd, flags: Event_Flags, data: rawptr = nil) -> bool {
	if el.epoll_fd < 0 || fd < 0 {
		return false
	}

	event := linux.EPoll_Event{
		events = epoll_flags_from_event_flags(flags) | {.ET}, // Edge-triggered
		data = linux.EPoll_Data{fd = fd},
	}

	result := linux.epoll_ctl(el.epoll_fd, .ADD, fd, &event)
	return result == .NONE
}

// event_loop_modify changes the events we're monitoring for a file descriptor
event_loop_modify :: proc(el: ^Event_Loop, fd: linux.Fd, flags: Event_Flags, data: rawptr = nil) -> bool {
	if el.epoll_fd < 0 || fd < 0 {
		return false
	}

	event := linux.EPoll_Event{
		events = epoll_flags_from_event_flags(flags) | {.ET}, // Edge-triggered
		data = linux.EPoll_Data{fd = fd},
	}

	result := linux.epoll_ctl(el.epoll_fd, .MOD, fd, &event)
	return result == .NONE
}

// event_loop_remove unregisters a file descriptor from the event loop
event_loop_remove :: proc(el: ^Event_Loop, fd: linux.Fd) -> bool {
	if el.epoll_fd < 0 || fd < 0 {
		return false
	}

	result := linux.epoll_ctl(el.epoll_fd, .DEL, fd, nil)
	return result == .NONE
}

// event_loop_wait waits for events and returns them.
// timeout_ms: milliseconds to wait (-1 for infinite, 0 for non-blocking)
// Returns slice of events that occurred.
event_loop_wait :: proc(el: ^Event_Loop, timeout_ms: int = -1) -> (events: []Event, ok: bool) {
	if el.epoll_fd < 0 {
		return nil, false
	}

	// Wait for events
	count, wait_err := linux.epoll_wait(el.epoll_fd, raw_data(el.events), c.int(el.max_events), c.int(timeout_ms))
	if wait_err != .NONE {
		return nil, false
	}

	if count == 0 {
		return nil, true
	}

	// Convert epoll events to our Event type
	result, result_err := make([]Event, count, context.temp_allocator)
	if result_err != nil {
		return nil, false
	}

	for i in 0..<count {
		epoll_event := &el.events[i]
		result[i] = Event{
			fd = epoll_event.data.fd,
			flags = event_flags_from_epoll_flags(epoll_event.events),
			data = rawptr(uintptr(epoll_event.data.fd)),
		}
	}

	return result, true
}

// Helper: convert our event flags to epoll flags
epoll_flags_from_event_flags :: proc(flags: Event_Flags) -> linux.EPoll_Event_Set {
	result := linux.EPoll_Event_Set{}

	if .Read in flags {
		result += {.IN}
	}
	if .Write in flags {
		result += {.OUT}
	}
	if .Error in flags {
		result += {.ERR}
	}
	if .HangUp in flags {
		result += {.HUP}
	}

	return result
}

// Helper: convert epoll flags to our event flags
event_flags_from_epoll_flags :: proc(epoll_flags: linux.EPoll_Event_Set) -> Event_Flags {
	result := Event_Flags{}

	if .IN in epoll_flags {
		result += {.Read}
	}
	if .OUT in epoll_flags {
		result += {.Write}
	}
	if .ERR in epoll_flags {
		result += {.Error}
	}
	if .HUP in epoll_flags || .RDHUP in epoll_flags {
		result += {.HangUp}
	}

	return result
}
