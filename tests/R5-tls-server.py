import socket
import ssl
import sys

def arg(name, default=None):
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default

cert = arg('--cert')
key = arg('--key')
ready = arg('--ready')
result = arg('--result')
if not all([cert, key, ready, result]):
    raise SystemExit('missing arguments')

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_2
ctx.maximum_version = ssl.TLSVersion.TLSv1_2
ctx.load_cert_chain(certfile=cert, keyfile=key)

listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(('127.0.0.1', 0))
listener.listen(1)
listener.settimeout(12)
port = listener.getsockname()[1]
with open(ready, 'w', encoding='ascii') as f:
    f.write(str(port))

conn = None
tls = None
try:
    conn, _ = listener.accept()
    conn.settimeout(15)
    tls = ctx.wrap_socket(conn, server_side=True)
    tls.settimeout(15)
    data = b''
    while b'\r\n\r\n' not in data and len(data) < 65536:
        chunk = tls.recv(4096)
        if not chunk:
            break
        data += chunk
    body = b'R5-TLS-FIXTURE'
    response = (
        b'HTTP/1.1 200 OK\r\n'
        b'Content-Type: text/plain\r\n'
        b'Content-Length: ' + str(len(body)).encode('ascii') + b'\r\n'
        b'Connection: close\r\n\r\n' + body
    )
    tls.sendall(response)
    with open(result, 'w', encoding='ascii') as f:
        f.write('served')
except Exception as exc:
    name = type(exc).__name__
    text = str(exc).replace('\r', ' ').replace('\n', ' ')[:300]
    with open(result, 'w', encoding='ascii') as f:
        f.write('failed:' + name + ':' + text)
finally:
    for obj in (tls, conn, listener):
        try:
            if obj is not None:
                obj.close()
        except Exception:
            pass
