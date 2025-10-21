package valkyrie

import linux "core:sys/linux"

// ARM64-compatible EPoll_Event with proper alignment.
//
// On ARM64, the C struct epoll_event has different layout than on x86_64:
// - x86_64: uint32 events (4B) + epoll_data_t data (8B) = 12 bytes (#packed)
// - ARM64:  uint32 events (4B) + 4B padding + epoll_data_t data (8B) = 16 bytes
//
// The Linux kernel's epoll_event on ARM64 adds 4 bytes of padding between
// the events field and data field for proper 8-byte alignment of the union,
// even with __attribute__((packed)). Odin's #packed removes ALL padding,
// causing a struct size mismatch that results in garbage fd values from epoll_wait().
//
// This fix adds explicit padding for ARM64 to match the kernel's struct layout.
EPoll_Event_ARM64 :: struct {
	events: linux.EPoll_Event_Set,
	_pad:   u32, // Explicit padding for ARM64 8-byte alignment
	data:   linux.EPoll_Data,
}
