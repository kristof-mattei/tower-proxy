FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie@sha256:1648c1ac19ef6b55a001048d832956c109a5a9ad37fc6b3c82d37b6cd462bbf3

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get --yes install --no-install-recommends mold
