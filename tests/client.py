import socket, ssl, time
def tls(sni):
    s = socket.create_connection(("127.0.0.3", 18443), timeout=3)
    ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    try:
        ctx.wrap_socket(s, server_hostname=sni); return "handshake"
    except ConnectionResetError: return "reset"
    except (ssl.SSLError, OSError) as e: return "other:" + type(e).__name__
def proxy(host):
    s = socket.create_connection(("127.77.1.2", 18888), timeout=3)
    try:
        s.sendall(("CONNECT %s:443 HTTP/1.1\r\nHost: %s:443\r\n\r\n" % (host, host)).encode())
        time.sleep(0.3); d = s.recv(100); return "reply:" + d[:12].decode(errors="replace")
    except ConnectionResetError: return "reset"
    except OSError as e: return "other:" + type(e).__name__
for name, fn, arg in (("A tls hyperos", tls, "hyperos.developer.xiaomi.com"), ("B tls other", tls, "other.example.com"),
                      ("C connect hyperos", proxy, "hyperos.developer.xiaomi.com"), ("D connect other", proxy, "other.example.com"),
                      ("E tls HyperOS(mixed case)", tls, "HyperOS.Developer.Xiaomi.com")):
    print(name, "->", fn(arg), flush=True)
