package valkyrie_tests

import "core:testing"
import hpack "../http/hpack"

@(test)
test_dynamic_table_init :: proc(t: ^testing.T) {
	table, ok := hpack.dynamic_table_init(4096)
	defer hpack.dynamic_table_destroy(&table)

	testing.expect(t, ok, "Should initialize successfully")
	testing.expect(t, hpack.dynamic_table_length(&table) == 0, "Should be empty")
	testing.expect(t, hpack.dynamic_table_size(&table) == 0, "Should have size 0")
	testing.expect(t, hpack.dynamic_table_max_size(&table) == 4096, "Should have max size 4096")
}

@(test)
test_dynamic_table_init_zero_size :: proc(t: ^testing.T) {
	table, ok := hpack.dynamic_table_init(0)
	defer hpack.dynamic_table_destroy(&table)

	testing.expect(t, ok, "Should initialize with zero size")
	testing.expect(t, hpack.dynamic_table_max_size(&table) == 0, "Should have max size 0")
}

@(test)
test_dynamic_table_init_negative :: proc(t: ^testing.T) {
	_, ok := hpack.dynamic_table_init(-1)
	testing.expect(t, !ok, "Should fail with negative size")
}

@(test)
test_dynamic_table_add_single :: proc(t: ^testing.T) {
	table, _ := hpack.dynamic_table_init(4096)
	defer hpack.dynamic_table_destroy(&table)

	ok := hpack.dynamic_table_add(&table, "custom-key", "custom-value")
	testing.expect(t, ok, "Should add entry successfully")
	testing.expect(t, hpack.dynamic_table_length(&table) == 1, "Should have 1 entry")

	// Entry size = len("custom-key") + len("custom-value") + 32 = 10 + 12 + 32 = 54
	expected_size := 54
	testing.expect(t, hpack.dynamic_table_size(&table) == expected_size, "Should have correct size")
}

@(test)
test_dynamic_table_add_multiple :: proc(t: ^testing.T) {
	table, _ := hpack.dynamic_table_init(4096)
	defer hpack.dynamic_table_destroy(&table)

	hpack.dynamic_table_add(&table, "key1", "value1")
	hpack.dynamic_table_add(&table, "key2", "value2")
	hpack.dynamic_table_add(&table, "key3", "value3")

	testing.expect(t, hpack.dynamic_table_length(&table) == 3, "Should have 3 entries")

	// Most recent entry should be at index 0
	entry, ok := hpack.dynamic_table_lookup(&table, 0)
	testing.expect(t, ok, "Should find entry at index 0")
	testing.expect(t, entry.name == "key3", "Most recent should be key3")
	testing.expect(t, entry.value == "value3", "Most recent should be value3")

	// Oldest entry should be at index 2
	entry2, ok2 := hpack.dynamic_table_lookup(&table, 2)
	testing.expect(t, ok2, "Should find entry at index 2")
	testing.expect(t, entry2.name == "key1", "Oldest should be key1")
	testing.expect(t, entry2.value == "value1", "Oldest should be value1")
}

@(test)
test_dynamic_table_lookup :: proc(t: ^testing.T) {
	table, _ := hpack.dynamic_table_init(4096)
	defer hpack.dynamic_table_destroy(&table)

	hpack.dynamic_table_add(&table, "test-name", "test-value")

	entry, ok := hpack.dynamic_table_lookup(&table, 0)
	testing.expect(t, ok, "Should find entry")
	testing.expect(t, entry.name == "test-name", "Should have correct name")
	testing.expect(t, entry.value == "test-value", "Should have correct value")
}

@(test)
test_dynamic_table_lookup_invalid :: proc(t: ^testing.T) {
	table, _ := hpack.dynamic_table_init(4096)
	defer hpack.dynamic_table_destroy(&table)

	hpack.dynamic_table_add(&table, "key", "value")

	// Out of bounds
	_, ok := hpack.dynamic_table_lookup(&table, 1)
	testing.expect(t, !ok, "Should not find entry at index 1")

	_, ok2 := hpack.dynamic_table_lookup(&table, -1)
	testing.expect(t, !ok2, "Should not find entry at negative index")
}

@(test)
test_dynamic_table_find_exact :: proc(t: ^testing.T) {
	table, _ := hpack.dynamic_table_init(4096)
	defer hpack.dynamic_table_destroy(&table)

	hpack.dynamic_table_add(&table, "key1", "value1")
	hpack.dynamic_table_add(&table, "key2", "value2")
	hpack.dynamic_table_add(&table, "key3", "value3")

	index := hpack.dynamic_table_find_exact(&table, "key2", "value2")
	testing.expect(t, index == 1, "Should find key2 at index 1")

	index2 := hpack.dynamic_table_find_exact(&table, "key3", "value3")
	testing.expect(t, index2 == 0, "Should find key3 at index 0 (most recent)")
}

@(test)
test_dynamic_table_find_exact_no_match :: proc(t: ^testing.T) {
	table, _ := hpack.dynamic_table_init(4096)
	defer hpack.dynamic_table_destroy(&table)

	hpack.dynamic_table_add(&table, "key1", "value1")

	// Wrong value
	index := hpack.dynamic_table_find_exact(&table, "key1", "value2")
	testing.expect(t, index == -1, "Should not find with wrong value")

	// Wrong name
	index2 := hpack.dynamic_table_find_exact(&table, "key2", "value1")
	testing.expect(t, index2 == -1, "Should not find with wrong name")
}

@(test)
test_dynamic_table_find_name :: proc(t: ^testing.T) {
	table, _ := hpack.dynamic_table_init(4096)
	defer hpack.dynamic_table_destroy(&table)

	hpack.dynamic_table_add(&table, "key1", "value1")
	hpack.dynamic_table_add(&table, "key2", "value2")
	hpack.dynamic_table_add(&table, "key1", "value3") // Same name, different value

	// Should find the most recent "key1" (at index 0)
	index := hpack.dynamic_table_find_name(&table, "key1")
	testing.expect(t, index == 0, "Should find most recent key1 at index 0")

	entry, _ := hpack.dynamic_table_lookup(&table, index)
	testing.expect(t, entry.value == "value3", "Should be the most recent value")
}

@(test)
test_dynamic_table_find_name_no_match :: proc(t: ^testing.T) {
	table, _ := hpack.dynamic_table_init(4096)
	defer hpack.dynamic_table_destroy(&table)

	hpack.dynamic_table_add(&table, "key1", "value1")

	index := hpack.dynamic_table_find_name(&table, "key2")
	testing.expect(t, index == -1, "Should not find non-existent name")
}

@(test)
test_dynamic_table_eviction :: proc(t: ^testing.T) {
	// Small table that can hold ~2 entries
	// Entry size = 4 + 6 + 32 = 42 bytes each
	table, _ := hpack.dynamic_table_init(100)
	defer hpack.dynamic_table_destroy(&table)

	// Add first entry (42 bytes)
	hpack.dynamic_table_add(&table, "key1", "value1")
	testing.expect(t, hpack.dynamic_table_length(&table) == 1, "Should have 1 entry")

	// Add second entry (42 bytes, total 84)
	hpack.dynamic_table_add(&table, "key2", "value2")
	testing.expect(t, hpack.dynamic_table_length(&table) == 2, "Should have 2 entries")

	// Add third entry (42 bytes, total would be 126 > 100)
	// Should evict key1
	hpack.dynamic_table_add(&table, "key3", "value3")
	testing.expect(t, hpack.dynamic_table_length(&table) == 2, "Should still have 2 entries")

	// key3 should be at index 0 (most recent)
	entry0, _ := hpack.dynamic_table_lookup(&table, 0)
	testing.expect(t, entry0.name == "key3", "key3 should be at index 0")

	// key2 should be at index 1
	entry1, _ := hpack.dynamic_table_lookup(&table, 1)
	testing.expect(t, entry1.name == "key2", "key2 should be at index 1")

	// key1 should be evicted
	index := hpack.dynamic_table_find_name(&table, "key1")
	testing.expect(t, index == -1, "key1 should be evicted")
}

@(test)
test_dynamic_table_entry_larger_than_max :: proc(t: ^testing.T) {
	// Small table
	table, _ := hpack.dynamic_table_init(50)
	defer hpack.dynamic_table_destroy(&table)

	// Add entry that fits
	hpack.dynamic_table_add(&table, "key", "val") // 3 + 3 + 32 = 38 bytes
	testing.expect(t, hpack.dynamic_table_length(&table) == 1, "Should have 1 entry")

	// Add entry larger than max size (should clear table)
	hpack.dynamic_table_add(&table, "verylongkeyname", "verylongvaluename") // > 50 bytes
	testing.expect(t, hpack.dynamic_table_length(&table) == 0, "Should have 0 entries after clearing")
}

@(test)
test_dynamic_table_resize_smaller :: proc(t: ^testing.T) {
	table, _ := hpack.dynamic_table_init(200)
	defer hpack.dynamic_table_destroy(&table)

	// Add 3 entries (each ~42 bytes)
	hpack.dynamic_table_add(&table, "key1", "value1")
	hpack.dynamic_table_add(&table, "key2", "value2")
	hpack.dynamic_table_add(&table, "key3", "value3")
	testing.expect(t, hpack.dynamic_table_length(&table) == 3, "Should have 3 entries")

	// Resize to 100 bytes (can only hold ~2 entries)
	ok := hpack.dynamic_table_resize(&table, 100)
	testing.expect(t, ok, "Should resize successfully")
	testing.expect(t, hpack.dynamic_table_max_size(&table) == 100, "Should have new max size")

	// Should evict oldest entry (key1)
	testing.expect(t, hpack.dynamic_table_length(&table) == 2, "Should have 2 entries after resize")

	// key3 and key2 should remain
	entry0, _ := hpack.dynamic_table_lookup(&table, 0)
	testing.expect(t, entry0.name == "key3", "key3 should remain")

	entry1, _ := hpack.dynamic_table_lookup(&table, 1)
	testing.expect(t, entry1.name == "key2", "key2 should remain")

	// key1 should be evicted
	index := hpack.dynamic_table_find_name(&table, "key1")
	testing.expect(t, index == -1, "key1 should be evicted")
}

@(test)
test_dynamic_table_resize_larger :: proc(t: ^testing.T) {
	table, _ := hpack.dynamic_table_init(100)
	defer hpack.dynamic_table_destroy(&table)

	hpack.dynamic_table_add(&table, "key1", "value1")
	hpack.dynamic_table_add(&table, "key2", "value2")

	// Resize larger
	ok := hpack.dynamic_table_resize(&table, 500)
	testing.expect(t, ok, "Should resize successfully")
	testing.expect(t, hpack.dynamic_table_max_size(&table) == 500, "Should have new max size")
	testing.expect(t, hpack.dynamic_table_length(&table) == 2, "Should still have 2 entries")
}

@(test)
test_dynamic_table_resize_zero :: proc(t: ^testing.T) {
	table, _ := hpack.dynamic_table_init(100)
	defer hpack.dynamic_table_destroy(&table)

	hpack.dynamic_table_add(&table, "key1", "value1")
	testing.expect(t, hpack.dynamic_table_length(&table) == 1, "Should have 1 entry")

	// Resize to 0 (should clear all entries)
	ok := hpack.dynamic_table_resize(&table, 0)
	testing.expect(t, ok, "Should resize to 0")
	testing.expect(t, hpack.dynamic_table_length(&table) == 0, "Should have 0 entries")
	testing.expect(t, hpack.dynamic_table_size(&table) == 0, "Should have size 0")
}

@(test)
test_dynamic_table_clear :: proc(t: ^testing.T) {
	table, _ := hpack.dynamic_table_init(4096)
	defer hpack.dynamic_table_destroy(&table)

	hpack.dynamic_table_add(&table, "key1", "value1")
	hpack.dynamic_table_add(&table, "key2", "value2")
	testing.expect(t, hpack.dynamic_table_length(&table) == 2, "Should have 2 entries")

	hpack.dynamic_table_clear(&table)
	testing.expect(t, hpack.dynamic_table_length(&table) == 0, "Should have 0 entries after clear")
	testing.expect(t, hpack.dynamic_table_size(&table) == 0, "Should have size 0 after clear")
}

@(test)
test_dynamic_table_entry_size :: proc(t: ^testing.T) {
	// Per RFC 7541 Section 4.1: size = name_len + value_len + 32
	size := hpack.dynamic_table_entry_size("custom-key", "custom-value")
	expected := 10 + 12 + 32 // "custom-key" (10) + "custom-value" (12) + 32
	testing.expect(t, size == expected, "Should calculate correct entry size")

	size2 := hpack.dynamic_table_entry_size("", "")
	testing.expect(t, size2 == 32, "Empty entry should be 32 bytes")
}
