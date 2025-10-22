.PHONY: build build-nix build-dynamic test install clean dev run-tls benchmark build-arm64

ODIN := odin
BUILD_DIR := build
BINARY := valkyrie
BENCHMARK_BINARY := benchmark_mechanics

build:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build . -o:speed -extra-linker-flags:"-static -static-libgcc -L/usr/local/lib -lwolfssl" -out:$(BUILD_DIR)/$(BINARY)

build-nix:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build . -o:speed -extra-linker-flags:"-static -static-libgcc -lwolfssl" -out:$(BUILD_DIR)/$(BINARY)

build-dynamic:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build . -o:speed -extra-linker-flags:"-L/usr/local/lib -Wl,-rpath,/usr/local/lib -lwolfssl" -out:$(BUILD_DIR)/$(BINARY)

build-arm64:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build . -o:speed -target:linux_arm64 -extra-linker-flags:"--target=aarch64-linux-gnu -static -static-libgcc -lwolfssl" -out:$(BUILD_DIR)/$(BINARY)-arm64

dev:
	odin run . -- --tls --port 8443 --cert dev.crt --key dev.key --log-level debug

run-tls: build
	$(BUILD_DIR)/$(BINARY) --tls --port 8443 --cert dev.crt --key dev.key

test:
	@$(ODIN) test tests -all-packages -define:ODIN_TEST_THREADS=2

benchmark:
	@mkdir -p $(BUILD_DIR)
	@$(ODIN) build benchmarks/processor/benchmark_mechanics.odin -file -out:$(BUILD_DIR)/$(BENCHMARK_BINARY) -o:speed
	@$(BUILD_DIR)/$(BENCHMARK_BINARY)

benchmark-compare:
	@mkdir -p $(BUILD_DIR)
	@$(ODIN) build benchmarks/processor/benchmark_comparison.odin -file -out:$(BUILD_DIR)/benchmark_comparison -o:speed
	@$(BUILD_DIR)/benchmark_comparison

benchmark-hpack:
	@mkdir -p $(BUILD_DIR)
	@$(ODIN) build benchmarks/hpack/benchmark_hpack.odin -file -out:$(BUILD_DIR)/benchmark_hpack -o:speed
	@$(BUILD_DIR)/benchmark_hpack

benchmark-server:
	@echo "Building server..."
	@$(MAKE) build-dynamic > /dev/null
	@echo "Killing any existing server..."
	@killall -9 $(BINARY) 2>/dev/null || true
	@sleep 1
	@echo "Starting server with 16 workers..."
	@setsid ./$(BUILD_DIR)/$(BINARY) --tls --cert dev.crt --key dev.key --port 8443 --workers 16 > /tmp/server.log 2>&1 < /dev/null &
	@sleep 3
	@echo "Running h2load benchmark (30s, 500 connections, 8 threads, 50 streams)..."
	@h2load -n 5000000 -c 500 -t 8 -m 50 --duration 30s https://localhost:8443
	@echo ""
	@echo "Stopping server..."
	@killall -9 $(BINARY) 2>/dev/null || true

install: build
	@cp $(BUILD_DIR)/$(BINARY) ~/bin/ 2>/dev/null || cp $(BUILD_DIR)/$(BINARY) /usr/local/bin/

clean:
	@rm -rf $(BUILD_DIR)
