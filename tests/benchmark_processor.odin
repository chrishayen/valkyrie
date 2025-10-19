package valkyrie_tests

import "core:sync"
import valkyrie ".."

// Simple benchmark handler that does minimal work
// Perfect for measuring pure processor throughput
Benchmark_Handler :: struct {
	process:       proc(h: ^Benchmark_Handler, item: valkyrie.Processor_Work_Item) -> valkyrie.Work_Result,
	process_count: u64,
	echo_response: bool,
}

benchmark_handler_init :: proc(echo_response: bool) -> Benchmark_Handler {
	return Benchmark_Handler{
		process = benchmark_process,
		echo_response = echo_response,
	}
}

// Minimal processing: just count and optionally echo
benchmark_process :: proc(h: ^Benchmark_Handler, item: valkyrie.Processor_Work_Item) -> valkyrie.Work_Result {
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
