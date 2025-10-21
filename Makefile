.PHONY: build build-nix test install clean dev run-tls benchmark build-arm64

ODIN := odin
BUILD_DIR := build
BINARY := valkyrie
BENCHMARK_BINARY := benchmark_mechanics

build:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build . -o:speed -extra-linker-flags:"-static -Wl,--start-group -ls2n -lssl -lcrypto -Wl,--end-group" -out:$(BUILD_DIR)/$(BINARY)

build-nix:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build . -o:speed -extra-linker-flags:"-static -Wl,--start-group -ls2n -lssl -lcrypto -Wl,--end-group" -out:$(BUILD_DIR)/$(BINARY)

build-arm64:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build . -o:speed -target:linux_arm64 -extra-linker-flags:"--target=aarch64-linux-gnu -static -Wl,--start-group -ls2n -lssl -lcrypto -Wl,--end-group" -out:$(BUILD_DIR)/$(BINARY)-arm64

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

install: build
	@cp $(BUILD_DIR)/$(BINARY) ~/bin/ 2>/dev/null || cp $(BUILD_DIR)/$(BINARY) /usr/local/bin/

clean:
	@rm -rf $(BUILD_DIR)
