FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie@sha256:1648c1ac19ef6b55a001048d832956c109a5a9ad37fc6b3c82d37b6cd462bbf3

# trixie only has mold 2.37.1
ADD --checksum=sha256:6ff270c9bf07d2bec5c98aa324eb7c4daf6a1a4d815c05ff1708049616047855 https://github.com/rui314/mold/releases/download/v2.42.1/mold-2.42.1-x86_64-linux.tar.gz /tmp/mold-x86_64.tar.gz
ADD --checksum=sha256:16b025652d3d7456689e6025a77e1903bb2a15e7630877c26cc133f5df95b9c6 https://github.com/rui314/mold/releases/download/v2.42.1/mold-2.42.1-aarch64-linux.tar.gz /tmp/mold-aarch64.tar.gz

RUN tar --extract --gzip --no-same-owner --strip-components 1 \
        --directory /usr/local \
        --file "/tmp/mold-$(uname --machine).tar.gz" \
    && rm /tmp/mold-*.tar.gz
