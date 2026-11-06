import socket, threading, time, sys
log = open(sys.argv[1], "a", buffering=1)
def serve(addr, reply):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(addr); s.listen(16)
    while True:
        c, _ = s.accept()
        c.settimeout(1.5)
        data = b""
        try:
            data = c.recv(4096)
            if reply and data: c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        except Exception:
            pass
        low = data.lower()
        tag = "hyperos" if b"hyperos.developer.xiaomi.com" in low else ("other" if b"other.example.com" in low else "-")
        log.write("%d len=%d %s\n" % (addr[1], len(data), tag))
        c.close()
threading.Thread(target=serve, args=(("127.0.0.3", 18443), False), daemon=True).start()
threading.Thread(target=serve, args=(("127.77.1.2", 18888), True), daemon=True).start()
print("ready", flush=True)
time.sleep(120)
