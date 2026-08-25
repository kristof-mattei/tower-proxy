FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie@sha256:b9c0a67721f1c23613122c447a587bf6d5913b79b713a69427d617ca24be7258

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get --yes install --no-install-recommends mold
