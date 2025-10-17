.PHONY: build test install clean

ODIN := odin
BUILD_DIR := build
BINARY := http2_server

build:
	@mkdir -p $(BUILD_DIR)
	$(ODIN) build . -out:$(BUILD_DIR)/$(BINARY)

dev:
	odin run . -- --tls

test:
	@$(ODIN) test tests -all-packages -define:ODIN_TEST_THREADS=2

install: build
	@cp $(BUILD_DIR)/$(BINARY) ~/bin/ 2>/dev/null || cp $(BUILD_DIR)/$(BINARY) /usr/local/bin/

clean:
	@rm -rf $(BUILD_DIR)
