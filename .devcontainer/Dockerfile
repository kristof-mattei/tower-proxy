FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie@sha256:b12e288bacbb5633f9b7655ba1a2cf69dd2fecef662346f2a9754f019af82483

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get --yes install --no-install-recommends mold
