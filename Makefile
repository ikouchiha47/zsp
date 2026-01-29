.PHONY: all deps deps-all dill run test clean

all: deps dill

# Build libdill for native architecture (detects arch automatically)
deps:
	./scripts/build-libdill.sh

# Build for all targets
deps-all: deps-macos-arm64 deps-macos-x86 deps-linux-arm64 deps-linux-x86

deps-macos-arm64: vendor/libdill-aarch64-macos.a
deps-macos-x86: vendor/libdill-x86_64-macos.a
deps-linux-arm64: vendor/libdill-aarch64-linux.a
deps-linux-x86: vendor/libdill-x86_64-linux.a

vendor/libdill-aarch64-macos.a:
	./scripts/build-libdill.sh aarch64-macos

vendor/libdill-x86_64-macos.a:
	./scripts/build-libdill.sh x86_64-macos

vendor/libdill-aarch64-linux.a:
	./scripts/build-libdill.sh aarch64-linux

vendor/libdill-x86_64-linux.a:
	./scripts/build-libdill.sh x86_64-linux

# Build and run dill example
dill: deps
	zig build dill

run: dill

test:
	zig build test

clean:
	rm -rf zig-out .zig-cache
	rm -f vendor/libdill*.a vendor/libdill.h
