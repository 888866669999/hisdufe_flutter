"""分析培养方案页的滚动性能：帧内工作时长 + 玻璃离屏层开销。

与 flutter_frames.py 的区别：那个算「帧周期」（vsync 间隔），只能看出有没有
整帧丢失。帧周期恒为 16.6ms 也可能「感觉卡」—— 只要每帧工作耗时逼近预算，
任何一点额外负担都会掉帧，而掉帧在 adb 合成滑动下未必稳定复现。
本脚本配对 `Animator::BeginFrame` 的 B/E 事件算出**帧内实际工作时长**，
并单独统计 `Canvas::saveLayer`（玻璃离屏层）的次数与总耗时，
用于判断余量还剩多少、瓶颈在哪。

用法: python tools/analyze_timeline.py <seconds> <port> <token>
（只连接、只打印，不落盘）
"""
import base64
import json
import os
import socket
import struct
import sys
import time

BUDGET_MS = 16.7


def connect(port, token):
    s = socket.create_connection(('127.0.0.1', int(port)), timeout=15)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f'GET /{token}/ws HTTP/1.1\r\n'
        f'Host: 127.0.0.1:{port}\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        f'Sec-WebSocket-Key: {key}\r\n'
        'Sec-WebSocket-Version: 13\r\n\r\n'
    )
    s.sendall(req.encode())
    buf = b''
    while b'\r\n\r\n' not in buf:
        buf += s.recv(4096)
    return s, buf.split(b'\r\n\r\n', 1)[1]


def make_io(s, buf):
    def send(text):
        p = text.encode()
        h = bytearray([0x81])
        n = len(p)
        if n < 126:
            h.append(0x80 | n)
        elif n < 65536:
            h.append(0x80 | 126)
            h += struct.pack('>H', n)
        else:
            h.append(0x80 | 127)
            h += struct.pack('>Q', n)
        mask = os.urandom(4)
        h += mask
        s.sendall(bytes(h) + bytes(b ^ mask[i % 4] for i, b in enumerate(p)))

    def fill(n):
        nonlocal buf
        while len(buf) < n:
            chunk = s.recv(1 << 20)
            if not chunk:
                raise EOFError
            buf += chunk
        out, buf = buf[:n], buf[n:]
        return out

    def recv():
        while True:
            b0, b1 = fill(2)
            op = b0 & 0x0F
            ln = b1 & 0x7F
            if ln == 126:
                ln = struct.unpack('>H', fill(2))[0]
            elif ln == 127:
                ln = struct.unpack('>Q', fill(8))[0]
            payload = fill(ln)
            if op == 0x8:
                raise EOFError
            if op in (1, 2):
                return payload.decode('utf-8', 'replace')

    return send, recv


def pct(a, p):
    return a[min(len(a) - 1, int(len(a) * p))]


def main():
    seconds = float(sys.argv[1])
    port = sys.argv[2]
    token = sys.argv[3]

    s, buf = connect(port, token)
    send, recv = make_io(s, buf)

    send(json.dumps({'jsonrpc': '2.0', 'id': '1',
                     'method': 'streamListen',
                     'params': {'streamId': 'Timeline'}}))
    recv()
    send(json.dumps({'jsonrpc': '2.0', 'id': '2',
                     'method': 'setVMTimelineFlags',
                     'params': {'recordedStreams':
                                ['Dart', 'Embedder', 'GC', 'Compiler', 'API']}}))
    try:
        recv()
    except Exception:
        pass

    events = []
    end = time.time() + seconds
    s.settimeout(1.0)
    while time.time() < end:
        try:
            msg = json.loads(recv())
        except socket.timeout:
            continue
        except EOFError:
            break
        events += (msg.get('params', {}).get('event', {})
                   .get('timelineEvents', []) or [])

    if not events:
        print('未捕获到 timeline 事件')
        return

    # ---- 帧内工作时长：Animator::BeginFrame 的 B/E 配对 ----
    stacks = {}
    work = []
    for e in events:
        if e.get('name') != 'Animator::BeginFrame':
            continue
        tid = e.get('tid', 0)
        ph = e.get('ph')
        if ph == 'B':
            stacks.setdefault(tid, []).append(e.get('ts', 0))
        elif ph == 'E':
            lst = stacks.get(tid)
            if lst:
                work.append(float(e.get('ts', 0) - lst.pop()))
    work = [w for w in work if 0 < w < 500000]
    work.sort()

    # ---- 玻璃离屏层（Canvas::saveLayer）----
    sl_stack = {}
    sl = []
    for e in events:
        if e.get('name') != 'Canvas::saveLayer':
            continue
        tid = e.get('tid', 0)
        ph = e.get('ph')
        if ph == 'B':
            sl_stack.setdefault(tid, []).append(e.get('ts', 0))
        elif ph == 'E':
            lst = sl_stack.get(tid)
            if lst:
                d = float(e.get('ts', 0) - lst.pop())
                if 0 < d < 500000:
                    sl.append(d)
    sl.sort()

    # ---- 后端/栅格化相关事件计数（用于定位瓶颈线程）----
    from collections import Counter
    cats = Counter(e.get('cat', '?') for e in events)

    if work:
        print(f'帧内工作时长样本 = {len(work)}')
        print(f'  中位 {pct(work,0.5)/1000:6.2f} ms'
              f'   p90 {pct(work,0.9)/1000:6.2f} ms'
              f'   p99 {pct(work,0.99)/1000:6.2f} ms'
              f'  最大 {work[-1]/1000:6.2f} ms')
        over = sum(1 for w in work if w / 1000 > BUDGET_MS)
        print(f'  超 {BUDGET_MS}ms 预算: {over}/{len(work)}'
              f' = {over/len(work)*100:.1f}%')
        tight = sum(1 for w in work if w / 1000 > BUDGET_MS * 0.5)
        print(f'  超半预算({BUDGET_MS*0.5:.1f}ms): {tight}/{len(work)}'
              f' = {tight/len(work)*100:.1f}%  ← 余量指标')
    else:
        print('未配对到 BeginFrame 工作量')

    if sl:
        total = sum(sl) / 1000
        print(f'玻璃 saveLayer: {len(sl)} 次, 合计 {total:.0f} ms'
              f'（占采集窗口 {total/(seconds*1000)*100:.0f}%）')
        print(f'  单次 中位 {pct(sl,0.5)/1000:.3f} ms'
              f'   p99 {pct(sl,0.99)/1000:.2f} ms'
              f'   最大 {sl[-1]/1000:.2f} ms')

    print('事件类别分布:', dict(cats.most_common(6)))


if __name__ == '__main__':
    main()
