#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$PROJECT_ROOT/vendor"
BUILD_DIR="/tmp/libdill-build"

# Default to native, or pass target as argument
# Supported: aarch64-macos, x86_64-macos, aarch64-linux, x86_64-linux
TARGET="${1:-native}"

if [ "$TARGET" = "native" ]; then
  # Detect native target
  ARCH=$(uname -m)
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')

  case "$ARCH" in
    arm64|aarch64) ARCH="aarch64" ;;
    x86_64) ARCH="x86_64" ;;
  esac

  case "$OS" in
    darwin) OS="macos" ;;
  esac

  TARGET="${ARCH}-${OS}"
  ZIG_TARGET=""
  SUFFIX="-${TARGET}"
else
  ZIG_TARGET="-target $TARGET"
  SUFFIX="-${TARGET}"
fi

# Platform-specific defines
case "$TARGET" in
  *macos*|native)
    PLATFORM_DEFINES="-DHAVE_KQUEUE=1 -DHAVE_STRUCT_SOCKADDR_SA_LEN=1"
    ;;
  *linux*)
    PLATFORM_DEFINES="-DHAVE_EPOLL=1"
    ;;
esac

echo "Building libdill for $TARGET..."

# Clean and clone (reuse if exists)
if [ ! -d "$BUILD_DIR" ]; then
  git clone --depth 1 https://github.com/sustrik/libdill.git "$BUILD_DIR"
fi

cd "$BUILD_DIR"
rm -f *.o *.a

# Compile each source file (excluding tls.c which needs OpenSSL)
for f in $(ls *.c | grep -v tls.c); do
  zig cc -c $ZIG_TARGET \
    -DDILL_SOCKETS=1 \
    -DHAVE_POSIX_MEMALIGN=1 \
    -DHAVE_MPROTECT=1 \
    -DHAVE_CLOCK_GETTIME=1 \
    $PLATFORM_DEFINES \
    -I. \
    "$f"
done

# Compile Zig wrapper
zig cc -c $ZIG_TARGET \
  -DDILL_SOCKETS=1 \
  -DHAVE_POSIX_MEMALIGN=1 \
  -DHAVE_MPROTECT=1 \
  -DHAVE_CLOCK_GETTIME=1 \
  $PLATFORM_DEFINES \
  -I. -I"$VENDOR_DIR" \
  "$VENDOR_DIR/dill_zig.c"

# Create static library
OUTPUT="libdill${SUFFIX}.a"
zig ar rcs "$OUTPUT" *.o

# Copy to vendor
mkdir -p "$VENDOR_DIR"
cp "$OUTPUT" "$VENDOR_DIR/"
cp libdill.h "$VENDOR_DIR/"

echo "Done: $VENDOR_DIR/$OUTPUT"
