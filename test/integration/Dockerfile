FROM debian:stable-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        iproute2 \
        iputils-ping \
        tcpdump \
        iptables \
        python3 \
        procps \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /repo
