"""用 Flutter VM Service 的 WebSocket 拉取真实帧耗时，量化「流畅度」。

为什么要自己写 WebSocket 客户端：这台机器上没装 websockets / websocket-client，
而 Flutter 的帧统计只能从 VM Service 拿 —— gfxinfo 与 SurfaceFlinger --latency
对 Flutter 的 SurfaceView 都返回空（实测：Total frames rendered = 0、
latency 缓冲只有 1 行），靠它们测不出真实帧率。

用法:
  python tools/flutter_frames.py --uri ws://127.0.0.1:41777/9DQmB910fqg=/ --seconds 8
"""
import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import time

MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'


class Ws:
    """极简 WebSocket 客户端（仅文本帧，够用即可）"""

    def __init__(self, host, port, path):
        self.sock = socket.create_connection((host, port), timeout=20)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f'GET {path} HTTP/1.1\r\n'
            f'Host: {host}:{port}\r\n'
            'Upgrade: websocket\r\n'
            'Connection: Upgrade\r\n'
            f'Sec-WebSocket-Key: {key}\r\n'
            'Sec-WebSocket-Version: 13\r\n\r\n'
        )
        self.sock.sendall(req.encode())
        buf = b''
        while b'\r\n\r\n' not in buf:
            buf += self.sock.recv(4096)
        # SHA-1 是 WebSocket 握手规范（RFC 6455 §4.2.2）**强制要求**的校验算法，
        # 不是安全措施：它只把客户端随机数回显成 Accept 头。换成 SHA-256
        # 会直接导致握手被服务端拒绝。此处无保密性/完整性诉求。
        accept = base64.b64encode(
            hashlib.sha1((key + MAGIC).encode()).digest()).decode()
        if accept.lower() not in buf.decode('latin-1').lower():
            raise RuntimeError('WebSocket 握手失败')
        self.buf = buf.split(b'\r\n\r\n', 1)[1]

    def send(self, text):
        payload = text.encode()
        header = bytearray([0x81])  # FIN + text
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack('>H', n)
        else:
            header.append(0x80 | 127)
            header += struct.pack('>Q', n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def _fill(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self):
        while True:
            b0, b1 = self._fill(2)
            opcode = b0 & 0x0F
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack('>H', self._fill(2))[0]
            elif length == 127:
                length = struct.unpack('>Q', self._fill(8))[0]
            payload = self._fill(length)
            if opcode == 0x8:
                raise EOFError
            if opcode in (0x9,):  # ping -> pong
                continue
            if opcode in (0x1, 0x2):
                return payload.decode('utf-8', 'replace')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--uri', required=True, help='VM Service ws URI')
    ap.add_argument('--seconds', type=float, default=8.0)
    args = ap.parse_args()

    u = args.uri.replace('ws://', '')
    hostport, path = u.split('/', 1)
    path = '/' + path
    # VM Service 的 WebSocket 端点是 <uri>/ws；只传 /<token>/ 会被拒握手
    if not path.endswith('/ws'):
        path = path.rstrip('/') + '/ws'
    host, port = hostport.split(':')

    ws = Ws(host, int(port), path)
    nxt = [1]

    def call(method, params=None):
        nxt[0] += 1
        mid = str(nxt[0])
        ws.send(json.dumps({'jsonrpc': '2.0', 'id': mid,
                            'method': method, 'params': params or {}}))
        while True:
            msg = json.loads(ws.recv())
            if msg.get('id') == mid:
                return msg

    # 订阅 Timeline 流，并要求记录 Embedder 事件（帧起止都在这里）。
    #
    # 注意两点（都踩过）：
    #   1. 帧事件来自 **Timeline** 流，不是 Extension 流；
    #   2. 必须先 setVMTimelineFlags 打开记录，否则订阅成功但收不到任何
    #      事件 —— 表现为「静默无输出」，很容易误判成脚本坏了。
    call('streamListen', {'streamId': 'Timeline'})
    try:
        call('setVMTimelineFlags', {
            'recordedStreams': ['Dart', 'Embedder', 'GC', 'Compiler', 'API'],
        })
    except Exception as e:
        print('setVMTimelineFlags 失败:', e)

    events = []
    t_end = time.time() + args.seconds
    ws.sock.settimeout(1.0)
    while time.time() < t_end:
        try:
            msg = json.loads(ws.recv())
        except socket.timeout:
            continue
        except EOFError:
            break
        for e in (msg.get('params', {}).get('event', {})
                  .get('timelineEvents', []) or []):
            events.append(e)

    # 用 Animator::BeginFrame 的起始时刻算真实帧周期
    starts = {}
    for e in events:
        if e.get('name') == 'Animator::BeginFrame' and e.get('ph') == 'B':
            starts.setdefault(e.get('tid', 0), []).append(e.get('ts', 0))

    periods = []
    for seq in starts.values():
        seq.sort()
        for i in range(len(seq) - 1):
            d = seq[i + 1] - seq[i]
            if 0 < d < 500000:
                periods.append(float(d))

    if not periods:
        print(f'未采集到帧事件（收到 timeline 事件 {len(events)} 条）。'
              f'提示：需要在手机上有真实滑动/动画。')
        return

    periods.sort()

    def pct(a, p):
        return a[min(len(a) - 1, int(len(a) * p))]

    us = lambda v: v / 1000.0
    print(f'帧数 = {len(periods)}')
    print(f'帧周期  中位 {us(pct(periods,0.5)):6.1f} ms'
          f'   p90 {us(pct(periods,0.9)):6.1f} ms'
          f'   p99 {us(pct(periods,0.99)):6.1f} ms'
          f'   最大 {us(periods[-1]):6.1f} ms')
    avg = sum(periods) / len(periods)
    print(f'折算平均帧率 ≈ {1e6 / avg:.1f} fps')
    over = sum(1 for v in periods if v > 16700)
    print(f'超 16.7ms 的帧: {over}/{len(periods)} = {over/len(periods)*100:.1f}%'
          f'（掉帧比例）')
    worst = sum(1 for v in periods if v > 33300)
    print(f'超 33.3ms 的帧: {worst}/{len(periods)} = {worst/len(periods)*100:.1f}%'
          f'（明显卡顿）')


if __name__ == '__main__':
    main()
