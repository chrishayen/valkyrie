package hpack

// Dynamic_Table_Entry represents a name-value pair stored in the dynamic table
Dynamic_Table_Entry :: struct {
	name:  string,
	value: string,
	size:  int, // Size in bytes (name length + value length + 32 per RFC 7541)
}

// Dynamic_Table maintains a FIFO table of recently used headers
// Per RFC 7541 Section 2.3, the dynamic table is a FIFO queue where
// new entries are added at index 0 and old entries are evicted from the end.
Dynamic_Table :: struct {
	entries:     [dynamic]Dynamic_Table_Entry,
	max_size:    int, // Maximum size in bytes
	current_size: int, // Current size in bytes
	allocator:   runtime.Allocator,
}

import "base:runtime"

// dynamic_table_init creates a new dynamic table with the given maximum size
dynamic_table_init :: proc(max_size: int, allocator := context.allocator) -> (table: Dynamic_Table, ok: bool) {
	if max_size < 0 {
		return {}, false
	}

	entries := make([dynamic]Dynamic_Table_Entry, 0, 16, allocator)
	if entries == nil {
		return {}, false
	}

	return Dynamic_Table{
		entries = entries,
		max_size = max_size,
		current_size = 0,
		allocator = allocator,
	}, true
}

// dynamic_table_destroy frees all resources used by the dynamic table
dynamic_table_destroy :: proc(table: ^Dynamic_Table) {
	if table == nil {
		return
	}

	// Free all entry strings
	for entry in table.entries {
		delete(entry.name, table.allocator)
		delete(entry.value, table.allocator)
	}

	delete(table.entries)
	table.current_size = 0
}

// dynamic_table_entry_size calculates the size of an entry per RFC 7541 Section 4.1
// Size = length of name + length of value + 32 bytes
dynamic_table_entry_size :: proc(name: string, value: string) -> int {
	return len(name) + len(value) + 32
}

// dynamic_table_add inserts a new entry at the beginning of the table
// Evicts old entries if necessary to stay within max_size
dynamic_table_add :: proc(table: ^Dynamic_Table, name: string, value: string) -> bool {
	if table == nil {
		return false
	}

	entry_size := dynamic_table_entry_size(name, value)

	// If entry is larger than max size, clear entire table
	if entry_size > table.max_size {
		dynamic_table_clear(table)
		return true
	}

	// Evict entries until we have room
	for table.current_size + entry_size > table.max_size && len(table.entries) > 0 {
		// Remove last entry (oldest)
		last_idx := len(table.entries) - 1
		last_entry := table.entries[last_idx]

		table.current_size -= last_entry.size
		delete(last_entry.name, table.allocator)
		delete(last_entry.value, table.allocator)

		pop(&table.entries)
	}

	// Copy strings to ensure ownership
	name_copy := make([]byte, len(name), table.allocator)
	if name_copy == nil {
		return false
	}
	copy(name_copy, transmute([]byte)name)

	value_copy := make([]byte, len(value), table.allocator)
	if value_copy == nil {
		delete(name_copy, table.allocator)
		return false
	}
	copy(value_copy, transmute([]byte)value)

	// Create entry
	entry := Dynamic_Table_Entry{
		name = string(name_copy),
		value = string(value_copy),
		size = entry_size,
	}

	// Insert at beginning (index 0)
	inject_at(&table.entries, 0, entry)
	table.current_size += entry_size

	return true
}

// dynamic_table_lookup returns the entry at the given 0-based index
// Returns (entry, true) if found, ({}, false) otherwise
dynamic_table_lookup :: proc(table: ^Dynamic_Table, index: int) -> (entry: Dynamic_Table_Entry, ok: bool) {
	if table == nil || index < 0 || index >= len(table.entries) {
		return {}, false
	}

	return table.entries[index], true
}

// dynamic_table_find_exact searches for an exact match of both name and value
// Returns the 0-based index if found, -1 otherwise
dynamic_table_find_exact :: proc(table: ^Dynamic_Table, name: string, value: string) -> int {
	if table == nil {
		return -1
	}

	for entry, i in table.entries {
		if entry.name == name && entry.value == value {
			return i
		}
	}

	return -1
}

// dynamic_table_find_name searches for a name match (value may differ)
// Returns the 0-based index of the first match, -1 otherwise
dynamic_table_find_name :: proc(table: ^Dynamic_Table, name: string) -> int {
	if table == nil {
		return -1
	}

	for entry, i in table.entries {
		if entry.name == name {
			return i
		}
	}

	return -1
}

// dynamic_table_resize changes the maximum size of the table
// Evicts entries if necessary to fit within new size
dynamic_table_resize :: proc(table: ^Dynamic_Table, new_max_size: int) -> bool {
	if table == nil || new_max_size < 0 {
		return false
	}

	table.max_size = new_max_size

	// Evict entries from end until we fit
	for table.current_size > table.max_size && len(table.entries) > 0 {
		last_idx := len(table.entries) - 1
		last_entry := table.entries[last_idx]

		table.current_size -= last_entry.size
		delete(last_entry.name, table.allocator)
		delete(last_entry.value, table.allocator)

		pop(&table.entries)
	}

	return true
}

// dynamic_table_clear removes all entries from the table
dynamic_table_clear :: proc(table: ^Dynamic_Table) {
	if table == nil {
		return
	}

	for entry in table.entries {
		delete(entry.name, table.allocator)
		delete(entry.value, table.allocator)
	}

	clear(&table.entries)
	table.current_size = 0
}

// dynamic_table_length returns the number of entries in the table
dynamic_table_length :: proc(table: ^Dynamic_Table) -> int {
	if table == nil {
		return 0
	}
	return len(table.entries)
}

// dynamic_table_size returns the current size in bytes
dynamic_table_size :: proc(table: ^Dynamic_Table) -> int {
	if table == nil {
		return 0
	}
	return table.current_size
}

// dynamic_table_max_size returns the maximum size in bytes
dynamic_table_max_size :: proc(table: ^Dynamic_Table) -> int {
	if table == nil {
		return 0
	}
	return table.max_size
}
