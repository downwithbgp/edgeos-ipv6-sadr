#!/usr/bin/env python3
# Minimal IPv6 echo helper for the namespace proof of concept.
#
# server-udp PORT   bind ::/PORT and echo "pong:" + payload
# server-tcp PORT   bind ::/PORT, accept, read once, echo "pong:" + payload
# client-udp SRC DST PORT
# client-tcp SRC DST PORT
#
# The client binds SRC explicitly so the test exercises source-dependent
# routing rather than relying on automatic source selection.
import socket
import sys
import time

TIMEOUT = 3.0


def server_udp(port):
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("::", port))
    while True:
        data, addr = sock.recvfrom(65535)
        sock.sendto(b"pong:" + data, addr)


def server_tcp(port):
    sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("::", port))
    sock.listen(8)
    while True:
        conn, _ = sock.accept()
        try:
            while True:
                data = conn.recv(65535)
                if not data:
                    break
                conn.sendall(b"pong:" + data)
        finally:
            conn.close()


def client_udp(src, dst, port):
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    sock.bind((src, 0))
    sock.settimeout(TIMEOUT)
    sock.sendto(b"probe", (dst, port))
    data, _ = sock.recvfrom(65535)
    if not data.startswith(b"pong:"):
        raise SystemExit("unexpected UDP reply: %r" % (data,))


def client_tcp(src, dst, port):
    sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    sock.bind((src, 0))
    sock.settimeout(TIMEOUT)
    sock.connect((dst, port))
    sock.sendall(b"probe")
    data = sock.recv(65535)
    sock.close()
    if not data.startswith(b"pong:"):
        raise SystemExit("unexpected TCP reply: %r" % (data,))


def client_udp_stream(src, dst, port, count, delay):
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    sock.bind((src, 0))
    sock.settimeout(TIMEOUT)
    for _ in range(count):
        sock.sendto(b"probe", (dst, port))
        data, _ = sock.recvfrom(65535)
        if not data.startswith(b"pong:"):
            raise SystemExit("unexpected UDP reply: %r" % (data,))
        time.sleep(delay)
    print("stream-ok")


def client_tcp_stream(src, dst, port, count, delay):
    sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    sock.bind((src, 0))
    sock.settimeout(TIMEOUT)
    sock.connect((dst, port))
    for _ in range(count):
        sock.sendall(b"probe")
        data = sock.recv(65535)
        if not data.startswith(b"pong:"):
            raise SystemExit("unexpected TCP reply: %r" % (data,))
        time.sleep(delay)
    sock.close()
    print("stream-ok")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    mode = sys.argv[1]
    if mode == "server-udp":
        server_udp(int(sys.argv[2]))
    elif mode == "server-tcp":
        server_tcp(int(sys.argv[2]))
    elif mode == "client-udp":
        client_udp(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    elif mode == "client-tcp":
        client_tcp(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    elif mode == "client-udp-stream":
        client_udp_stream(sys.argv[2], sys.argv[3], int(sys.argv[4]),
                          int(sys.argv[5]), float(sys.argv[6]))
    elif mode == "client-tcp-stream":
        client_tcp_stream(sys.argv[2], sys.argv[3], int(sys.argv[4]),
                          int(sys.argv[5]), float(sys.argv[6]))
    else:
        raise SystemExit("unknown mode: %s" % mode)


if __name__ == "__main__":
    main()
