# syntax=docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=skip=SecretsUsedInArgOrEnv,error=true

# Rust toolchain setup
FROM --platform=${BUILDPLATFORM} rust:1.98.0-slim-trixie@sha256:17d1ba895198f9934c6314ec5346a0d5115372f3243390c3d731e242f35c2f27 AS rust-base

ARG APPLICATION_NAME
ARG DEBIAN_FRONTEND=noninteractive

RUN rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

RUN apt-get update \
    && apt-get upgrade --yes \
    && apt-get install --no-install-recommends --yes \
        build-essential \
        musl-dev \
        patch \
        xz-utils

# trixie packages cargo-auditable 0.6.6, which predates the bare-linker (-Clinker=rust-lld) fixes from 0.7.3
ADD --checksum=sha256:3374daaf153e6f82028add5e4bf7cc2deab46537dee24f20be80df831193aeb4 https://github.com/rust-secure-code/cargo-auditable/releases/download/v0.7.5/cargo-auditable-x86_64-unknown-linux-musl.tar.xz /tmp/cargo-auditable-x86_64.tar.xz
ADD --checksum=sha256:35d90cee9648037eaa4c1a2649fdca9d1b9a9997b972d37be7f8629139ba1294 https://github.com/rust-secure-code/cargo-auditable/releases/download/v0.7.5/cargo-auditable-aarch64-unknown-linux-musl.tar.xz /tmp/cargo-auditable-aarch64.tar.xz

RUN tar --extract --xz --no-same-owner --strip-components 1 \
        --directory /usr/local/cargo/bin \
        --file "/tmp/cargo-auditable-$(uname --machine).tar.xz" \
        "cargo-auditable-$(uname --machine)-unknown-linux-musl/cargo-auditable" \
    && rm /tmp/cargo-auditable-*.tar.xz

FROM rust-base AS rust-linux-amd64
ARG TARGET=x86_64-unknown-linux-musl

FROM rust-base AS rust-linux-arm64
ARG TARGET=aarch64-unknown-linux-musl

FROM rust-linux-${TARGETARCH} AS rust-cargo-build

# amd64 or arm64
ARG TARGETARCH
# linux or ...
ARG TARGETOS
# used by `build.sh`, v2, v3 or empty
ARG TARGETVARIANT
# like TARGETPLATFORM, but with dashes
ARG TARGETPLATFORMDASH="${TARGETOS}-${TARGETARCH}-${TARGETVARIANT:-base}"
ARG CARGO_TARGET_DIR=/build/target/${TARGETPLATFORMDASH}

COPY ./build-scripts /build-scripts

RUN /build-scripts/setup-env.sh

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

RUN /build-scripts/build.sh build --frozen --release

# Rust full build
FROM rust-cargo-build AS rust-build

WORKDIR /build

# now we copy in the source which is more prone to changes and build it
COPY ./crates ./crates

# ensure cargo picks up on the fact that we copied in our code
RUN find ./crates -type f -name '*.rs' -exec touch {} +

ENV PATH="/output/bin:$PATH"

# build with sources with default version number
RUN /build-scripts/build.sh build --frozen --release

# apply version bump (if any)
COPY ./version-bump.patch ./
RUN [ ! -s version-bump.patch ] || patch --strip 1 < version-bump.patch

# build with new version number, minor update
# --release not needed, it is implied with install
RUN /build-scripts/build.sh install --frozen --path "./crates/${APPLICATION_NAME}/" --root /output

# Container user setup
FROM --platform=${BUILDPLATFORM} alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS passwd-build

# setting `--system` prevents prompting for a password
RUN addgroup --gid 900 appgroup \
    && adduser --ingroup appgroup --uid 900 --system --shell /bin/false appuser

RUN cat /etc/group | grep appuser > /tmp/group_appuser
RUN cat /etc/passwd | grep appuser > /tmp/passwd_appuser

# Final stage, no `BUILDPLATFORM`, this one is run where it is deployed
FROM scratch

ARG APPLICATION_NAME

COPY --from=passwd-build /tmp/group_appuser /etc/group
COPY --from=passwd-build /tmp/passwd_appuser /etc/passwd

COPY --from=rust-build /output/bin/${APPLICATION_NAME} /app/entrypoint

USER appuser

ENV RUST_BACKTRACE=full

WORKDIR /app

ENTRYPOINT ["/app/entrypoint"]
