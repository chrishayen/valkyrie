package valkyrie_tests

import "core:testing"
import "core:sync"
import "core:time"
import valkyrie ".."

// Test handler that echoes data back
Test_Handler :: struct {
	process:       proc(h: ^Test_Handler, item: valkyrie.Processor_Work_Item) -> valkyrie.Work_Result,
	process_count: int,
	mutex:         sync.Mutex,
}

test_handler_process :: proc(h: ^Test_Handler, item: valkyrie.Processor_Work_Item) -> valkyrie.Work_Result {
	sync.mutex_lock(&h.mutex)
	h.process_count += 1
	sync.mutex_unlock(&h.mutex)
	
	if item.len > 0 {
		response := make([]u8, item.len)
		copy(response, item.data)
		delete(item.data)
		return valkyrie.Work_Result{response_data = response}
	}
	
	delete(item.data)
	return {}
}

@(test)
test_processor_lockless_queue :: proc(t: ^testing.T) {
	queue := valkyrie.processor_lockless_queue_init(int)

	testing.expect(t, valkyrie.processor_lockless_queue_is_empty(&queue))

	testing.expect(t, valkyrie.processor_lockless_queue_push(&queue, 1))
	testing.expect(t, valkyrie.processor_lockless_queue_push(&queue, 2))
	testing.expect(t, valkyrie.processor_lockless_queue_push(&queue, 3))

	testing.expect(t, !valkyrie.processor_lockless_queue_is_empty(&queue))

	items := make([dynamic]int)
	for !valkyrie.processor_lockless_queue_is_empty(&queue) {
		if item, ok := valkyrie.processor_lockless_queue_try_pop(&queue); ok {
			append(&items, item)
		}
	}

	testing.expect(t, len(items) == 3)

	found := make(map[int]bool)
	for item in items {
		found[item] = true
	}
	testing.expect(t, found[1] && found[2] && found[3])

	delete(items)
}

@(test)
test_processor_init :: proc(t: ^testing.T) {
	handler := Test_Handler{
		process = test_handler_process,
	}

	p: valkyrie.Processor(Test_Handler)
	valkyrie.processor_init(&p, 2, handler)

	testing.expect(t, valkyrie.processor_lockless_queue_is_empty(&p.io_to_worker_queue))
	testing.expect(t, valkyrie.processor_lockless_queue_is_empty(&p.worker_to_io_queue))
	testing.expect(t, len(p.workers) == 2)

	valkyrie.processor_shutdown(&p)
}

@(test)
test_processor_throughput :: proc(t: ^testing.T) {
	handler := benchmark_handler_init(false)

	p: valkyrie.Processor(Benchmark_Handler)
	valkyrie.processor_init(&p, 4, handler)
	defer valkyrie.processor_shutdown(&p)

	num_items :: 100_000
	data := make([]u8, 64)
	defer delete(data)

	start := time.now()

	for i in 0..<num_items {
		item_data := make([]u8, 64)
		copy(item_data, data)
		valkyrie.processor_enqueue_work(&p, 1, item_data, 64)
	}

	for {
		count := sync.atomic_load(&p.handler.process_count)
		if count >= num_items {
			break
		}
		sync.cpu_relax()
	}
	
	duration := time.duration_seconds(time.since(start))
	throughput := f64(num_items) / duration
	
	testing.logf(t, "Processed %d items in %.3fs (%.0f items/sec)", num_items, duration, throughput)
	testing.expect(t, throughput > 100_000, "Expected >100k items/sec throughput")
}