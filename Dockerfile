FROM --platform=$TARGETPLATFORM debian:bookworm-slim AS builder

ARG TARGETARCH

RUN apt-get update && apt-get install -y \
    git \
    gcc \
    make \
    autoconf \
    automake \
    libtool \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN git clone --depth 1 https://github.com/sustrik/libdill.git

WORKDIR /build/libdill

RUN ./autogen.sh \
    && ./configure --disable-shared --enable-static \
    && make

# Output stage - copy artifacts to /output with arch suffix
FROM scratch AS export
ARG TARGETARCH
COPY --from=builder /build/libdill/.libs/libdill.a /libdill-${TARGETARCH}.a
COPY --from=builder /build/libdill/libdill.h /
