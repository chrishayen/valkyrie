package main

import valkyrie "../.."
import "core:fmt"
import "core:sync"
import "core:time"

// Benchmark handler for lockless work pool
Lockless_Handler :: struct {
	process:       proc(
		h: ^Lockless_Handler,
		item: valkyrie.Processor_Work_Item,
	) -> valkyrie.Work_Result,
	process_count: u64,
}

lockless_process :: proc(
	h: ^Lockless_Handler,
	item: valkyrie.Processor_Work_Item,
) -> valkyrie.Work_Result {
	sync.atomic_add(&h.process_count, 1)
	delete(item.data)
	return {}
}

// Benchmark handler for mutex work pool
Mutex_Handler :: struct {
	process:       proc(h: ^Mutex_Handler, item: valkyrie.WP_Work_Item) -> valkyrie.Work_Result,
	process_count: u64,
}

mutex_process :: proc(h: ^Mutex_Handler, item: valkyrie.WP_Work_Item) -> valkyrie.Work_Result {
	sync.atomic_add(&h.process_count, 1)
	delete(item.data)
	return {}
}

run_lockless_benchmark :: proc(num_workers: int, num_items: int) -> f64 {
	handler := Lockless_Handler {
		process = lockless_process,
	}

	p := new(valkyrie.Processor(Lockless_Handler, 2_097_152))
	valkyrie.processor_init(p, num_workers, handler)

	data := make([]u8, 64)

	start := time.now()

	for i in 0 ..< num_items {
		item_data := make([]u8, 64)
		copy(item_data, data)
		valkyrie.processor_enqueue_work(p, 1, item_data, 64)
	}

	for {
		count := sync.atomic_load(&p.handler.process_count)
		if count >= u64(num_items) {
			break
		}
	}

	duration := time.duration_seconds(time.since(start))
	throughput := f64(num_items) / duration

	valkyrie.processor_shutdown(p)
	free(p)
	delete(data)

	return throughput
}

run_mutex_benchmark :: proc(num_workers: int, num_items: int) -> f64 {
	handler := Mutex_Handler {
		process = mutex_process,
	}

	pool := new(valkyrie.Work_Pool(Mutex_Handler))
	valkyrie.work_pool_init(pool, num_workers, handler)

	data := make([]u8, 64)

	start := time.now()

	for i in 0 ..< num_items {
		item_data := make([]u8, 64)
		copy(item_data, data)
		valkyrie.work_pool_enqueue(pool, 1, item_data, 64)
	}

	for {
		count := sync.atomic_load(&pool.handler.process_count)
		if count >= u64(num_items) {
			break
		}
	}

	duration := time.duration_seconds(time.since(start))
	throughput := f64(num_items) / duration

	valkyrie.work_pool_shutdown(pool)
	free(pool)
	delete(data)

	return throughput
}

main :: proc() {
	fmt.println("=== Work Pool Style Comparison ===\n")

	num_workers_tests := []int{1, 2, 4}
	num_items :: 1_000_000

	fmt.println("Testing: Lockless Queue (Atomics)")
	fmt.println("----------------------------------")
	for num_workers in num_workers_tests {
		throughput := run_lockless_benchmark(num_workers, num_items)
		fmt.printf("Workers: %d → %.2fM items/sec\n", num_workers, throughput / 1_000_000)
	}

	fmt.println("\nTesting: Mutex Queue")
	fmt.println("----------------------------------")
	for num_workers in num_workers_tests {
		throughput := run_mutex_benchmark(num_workers, num_items)
		fmt.printf("Workers: %d → %.2fM items/sec\n", num_workers, throughput / 1_000_000)
	}

	fmt.println("\n=== Comparison Complete ===")
}

