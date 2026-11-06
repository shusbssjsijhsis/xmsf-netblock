import socket
res = []
for name, addr in (("tls", ("127.0.0.3", 18443)), ("proxy", ("127.77.1.2", 18888))):
    try:
        s = socket.create_connection(addr, timeout=3); s.close(); res.append(name + "=connected")
    except ConnectionRefusedError: res.append(name + "=refused")
    except OSError as e: res.append(name + "=" + type(e).__name__)
try:
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(1)
    u.connect(("127.0.0.3", 18999)); u.send(b"x")
    try: u.recv(10); res.append("udp=reply")
    except ConnectionRefusedError: res.append("udp=refused")
    except socket.timeout: res.append("udp=timeout")
except PermissionError: res.append("udp=eperm")
except ConnectionRefusedError: res.append("udp=refused")
except OSError as e: res.append("udp=" + type(e).__name__)
print(" ".join(res), flush=True)
