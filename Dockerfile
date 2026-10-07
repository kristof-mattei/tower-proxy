# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=skip=SecretsUsedInArgOrEnv,error=true

# Rust toolchain setup
FROM --platform=${BUILDPLATFORM} rust:1.99.0-slim-trixie@sha256:24e632c09342c20abf8312cf4f61430a911c01ed3a5e4c02b87292b1c39c5273 AS rust-base

ARG APPLICATION_NAME
ARG DEBIAN_FRONTEND=noninteractive

RUN rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

RUN apt-get update \
    && apt-get upgrade --yes \
    && apt-get install --no-install-recommends --yes \
        patch \
        xz-utils

# trixie only has cargo-auditable 0.6.6, we need >= 0.6.7 for a bare linker
ADD --checksum=sha256:7676443367c5e33d9fb22acef63cccb5e9202de12dae1b0579995eb3e2bc7a18 https://github.com/rust-secure-code/cargo-auditable/releases/download/v0.7.7/cargo-auditable-x86_64-unknown-linux-musl.tar.xz /tmp/cargo-auditable-x86_64.tar.xz
ADD --checksum=sha256:c324af56990601354bbf40080f582ba46f8ec8b807a1388e25bb7e429d285c18 https://github.com/rust-secure-code/cargo-auditable/releases/download/v0.7.7/cargo-auditable-aarch64-unknown-linux-musl.tar.xz /tmp/cargo-auditable-aarch64.tar.xz

RUN tar --extract --xz --no-same-owner --strip-components 1 \
        --directory /usr/local/cargo/bin \
        --file "/tmp/cargo-auditable-$(uname --machine).tar.xz" \
        "cargo-auditable-$(uname --machine)-unknown-linux-musl/cargo-auditable" \
    && rm /tmp/cargo-auditable-*.tar.xz

# trixie only has mold 2.37.1
ADD --checksum=sha256:6c90d4a474c7c0409dfb575be03a5345878ac14fdba18de8b40fa58c60121189 https://github.com/rui314/mold/releases/download/v3.0.0/mold-3.0.0-x86_64-linux.tar.gz /tmp/mold-x86_64.tar.gz
ADD --checksum=sha256:52c759d3689babaea4c42af2f31062a74ab83e17ffb5a8090232534c67b70577 https://github.com/rui314/mold/releases/download/v3.0.0/mold-3.0.0-aarch64-linux.tar.gz /tmp/mold-aarch64.tar.gz

RUN tar --extract --gzip --no-same-owner --strip-components 2 \
        --directory /usr/local/bin \
        --file "/tmp/mold-$(uname --machine).tar.gz" \
        --wildcards "*/bin/mold" \
    && rm /tmp/mold-*.tar.gz

ENV CC_x86_64_unknown_linux_musl=x86_64-linux-musl-gcc \
    CC_aarch64_unknown_linux_musl=aarch64-linux-musl-gcc \
    CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=mold \
    CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=mold \
    RUSTFLAGS="-Clink-self-contained=yes -Clinker-flavor=ld"

FROM rust-base AS rust-linux-amd64
ARG TARGET=x86_64-unknown-linux-musl
ARG TARGETVARIANT
# empty TARGETVARIANT adds nothing, v3 becomes -Ctarget-cpu=x86-64-v3
ENV RUSTFLAGS="${RUSTFLAGS}${TARGETVARIANT:+ -Ctarget-cpu=x86-64-}${TARGETVARIANT}"

FROM rust-base AS rust-linux-arm64
ARG TARGET=aarch64-unknown-linux-musl

FROM rust-linux-${TARGETARCH} AS rust-cargo-build

# amd64 or arm64
ARG TARGETARCH
# linux or ...
ARG TARGETOS
# v2, v3 or empty
ARG TARGETVARIANT
# like TARGETPLATFORM, but with dashes
ARG TARGETPLATFORMDASH="${TARGETOS}-${TARGETARCH}-${TARGETVARIANT:-base}"
ARG CARGO_TARGET_DIR=/build/target/${TARGETPLATFORMDASH}

# Debian architecture names match TARGETARCH for amd64 and arm64
RUN if [ "$(dpkg --print-architecture)" != "${TARGETARCH}" ]; then dpkg --add-architecture "${TARGETARCH}"; fi \
    && apt-get update \
    && apt-get install --no-install-recommends --yes "musl-tools:${TARGETARCH}"

RUN rustup target add ${TARGET}

# The following block
# creates an empty app, and we copy in Cargo.toml and Cargo.lock as they represent our dependencies
# This allows us to copy in the source in a different layer which in turn allows us to leverage Docker's layer caching
# That means that if our dependencies don't change rebuilding is much faster
WORKDIR /build
COPY ./.cargo ./.cargo
COPY ./Cargo.toml ./Cargo.lock ./

# main crate
WORKDIR /build/crates/
RUN cargo new --bin --vcs none ${APPLICATION_NAME}
COPY ./crates/${APPLICATION_NAME}/Cargo.toml ./${APPLICATION_NAME}/Cargo.toml
RUN echo "fn main() {}" > ./${APPLICATION_NAME}/src/build.rs

# repeat this for each crate
WORKDIR /build/crates/
RUN cargo new --lib --vcs none shared
COPY ./crates/shared/Cargo.toml ./shared/Cargo.toml

WORKDIR /build

RUN cargo fetch --locked

RUN cargo auditable build --frozen --release --target "${TARGET}"

# Rust full build
FROM rust-cargo-build AS rust-build

WORKDIR /build

# now we copy in the source which is more prone to changes and build it
COPY ./crates ./crates

# ensure cargo picks up on the fact that we copied in our code
RUN find ./crates -type f -name '*.rs' -exec touch {} +

ENV PATH="/output/bin:$PATH"

# build with sources with default version number
RUN cargo auditable build --frozen --release --target "${TARGET}"

# apply version bump (if any)
COPY ./version-bump.patch ./
RUN [ ! -s version-bump.patch ] || patch --strip 1 < version-bump.patch

# build with new version number, minor update
# --release not needed, it is implied with install
RUN cargo auditable install --frozen --path "./crates/${APPLICATION_NAME}/" --root /output --target "${TARGET}"

# Final stage, no `BUILDPLATFORM`, this one is run where it is deployed
FROM scratch

ARG APPLICATION_NAME

COPY <<EOF /etc/passwd
appuser:x:900:900:appuser:/home/appuser:/bin/false
EOF

COPY <<EOF /etc/group
appgroup:x:900:appuser
EOF

COPY --from=rust-build /output/bin/${APPLICATION_NAME} /app/tower-proxy

USER appuser

ENV RUST_BACKTRACE=full

WORKDIR /app

ENTRYPOINT ["/app/tower-proxy"]
