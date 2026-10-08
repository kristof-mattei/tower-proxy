FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie@sha256:7ea67e836ab768910de3810355ae0a0b06d63c14f2159708b6e5758c01532bf7

# trixie only has mold 2.37.1
ADD --checksum=sha256:6c90d4a474c7c0409dfb575be03a5345878ac14fdba18de8b40fa58c60121189 https://github.com/rui314/mold/releases/download/v3.0.0/mold-3.0.0-x86_64-linux.tar.gz /tmp/mold-x86_64.tar.gz
ADD --checksum=sha256:52c759d3689babaea4c42af2f31062a74ab83e17ffb5a8090232534c67b70577 https://github.com/rui314/mold/releases/download/v3.0.0/mold-3.0.0-aarch64-linux.tar.gz /tmp/mold-aarch64.tar.gz

RUN tar --extract --gzip --no-same-owner --strip-components 1 \
        --directory /usr/local \
        --file "/tmp/mold-$(uname --machine).tar.gz" \
    && rm /tmp/mold-*.tar.gz
