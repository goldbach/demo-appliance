FROM ubuntu:26.04

COPY scripts/install-build-deps.sh /tmp/
RUN /tmp/install-build-deps.sh

WORKDIR /work
