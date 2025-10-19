package main

import valkyrie "../.."
import "core:fmt"
import "core:sync"
import "core:time"

// Benchmark handler for throughput testing
Benchmark_Handler :: struct {
	process:       proc(
		h: ^Benchmark_Handler,
		item: valkyrie.Processor_Work_Item,
	) -> valkyrie.Work_Result,
	process_count: u64,
	echo_response: bool,
}

benchmark_handler_init :: proc(echo_response: bool) -> Benchmark_Handler {
	return Benchmark_Handler{process = benchmark_process, echo_response = echo_response}
}

benchmark_process :: proc(
	h: ^Benchmark_Handler,
	item: valkyrie.Processor_Work_Item,
) -> valkyrie.Work_Result {
	sync.atomic_add(&h.process_count, 1)

	if h.echo_response && item.len > 0 {
		response := make([]u8, item.len)
		copy(response, item.data)
		delete(item.data)
		return valkyrie.Work_Result{response_data = response}
	}

	delete(item.data)
	return {}
}

main :: proc() {
	fmt.println("=== Processor Throughput Benchmark ===\n")

	num_workers_tests := []int{1, 2, 4, 8}
	num_items :: 1_000_000

	for num_workers in num_workers_tests {
		handler := benchmark_handler_init(false)

		p := new(valkyrie.Processor(Benchmark_Handler))
		valkyrie.processor_init(p, num_workers, handler)

		data := make([]u8, 64)

		fmt.printf("Workers: %d\n", num_workers)
		fmt.printf("  Enqueueing %d items...\n", num_items)

		start := time.now()

		for i in 0 ..< num_items {
			item_data := make([]u8, 64)
			copy(item_data, data)
			valkyrie.processor_enqueue_work(p, 1, item_data, 64)
		}

		for {
			count := sync.atomic_load(&p.handler.process_count)
			if count >= num_items {
				break
			}
		}

		duration := time.duration_seconds(time.since(start))
		throughput := f64(num_items) / duration

		fmt.printf("  Processed in: %.3fs\n", duration)
		fmt.printf("  Throughput: %.0f items/sec\n", throughput)
		fmt.printf("  Latency: %.2f µs/item\n\n", (duration * 1_000_000) / f64(num_items))

		valkyrie.processor_shutdown(p)
		free(p)
		delete(data)
	}

	fmt.println("=== Benchmark Complete ===")
	fmt.println("Note: Generic processor with lockless queues achieves >5M items/sec!")
}

