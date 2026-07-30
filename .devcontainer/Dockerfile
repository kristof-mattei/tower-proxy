FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie@sha256:0ef7110175191659b975c1b89217217a093667851bde031b48f8ceab9cd1be1f

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get --yes install --no-install-recommends mold
