"""验证码模型量化评估：对比「原模型」与「量化模型」的识别率与体积。

为什么要先跑这一步：量化会改数值精度，而本项目刚因「字符表与模型不匹配」
踩过一次**静默降精度**的坑（不报错、只是识别率变差）。因此量化不能凭
「体积小了」就采用，必须用同一批语料跑出量化前后的识别率对比，
达不到「≥ 原模型 90%」就不用。

预处理**严格复刻**端上实现（lib/data/captcha_model.dart）：
  1. 等比缩放到高 64（保持宽高比，线性插值）
  2. 灰度 = 0.299R + 0.587G + 0.114B，再 /255
  3. 右侧用**白色(1.0)** 补齐到宽 160
  4. 输入 NCHW 1×1×64×160
解码：CTC 贪心（去连续重复、丢 blank）→ 字符表查表。

用法:
  python tools/quantize_eval.py
"""
import glob
import io
import os
import re
import sys

import numpy as np
import onnx
import onnxruntime as ort
from PIL import Image

H, W = 64, 160
CHARSET_PATH = 'lib/model/captcha_charset.dart'
MODEL = 'assets/captcha.onnx'
CORPUS = 'assets/ocr_eval'


def load_charset() -> dict:
    """从 Dart 字符表源文件里读出 index -> char 映射（单一事实来源，避免抄错）"""
    src = io.open(CHARSET_PATH, encoding='utf-8').read()
    m = re.search(r'_pairs\s*=\s*<List<int>>\[(.*?)\];', src, re.S)
    if not m:
        raise SystemExit('未能从 ' + CHARSET_PATH + ' 解析出 _pairs')
    pairs = {}
    for idx, code in re.findall(r'<int>\[(\d+),\s*(\d+)\]', m.group(1)):
        pairs[int(idx)] = int(code)
    return pairs


def preprocess(path: str) -> np.ndarray:
    im = Image.open(path).convert('RGB')
    scale = H / im.height
    tw = max(1, int(round(im.width * scale)))
    im = im.resize((tw, H), Image.BILINEAR)
    arr = np.asarray(im, dtype=np.float32)
    # BT.601 亮度，与端上同一组权重
    lum = 0.299 * arr[:, :, 0] + 0.587 * arr[:, :, 1] + 0.114 * arr[:, :, 2]
    lum = lum / 255.0
    canvas = np.ones((H, W), dtype=np.float32)  # 右侧补白
    canvas[:, :min(tw, W)] = lum[:, :min(tw, W)]
    return canvas.reshape(1, 1, H, W)


def decode(logits: np.ndarray, charset: dict) -> str:
    """CTC 贪心解码：argmax → 去连续重复 → 丢 blank(0)

    输出布局是 Paddle 的 **[T, N, C]**（时间步在前），不是 [N, T, C]。
    搞错这一维不会报错，只会把所有时间步压成一个 token（识别率恒为 0），
    端上 `_flatten` 也正是按最外层当时间步来遍历的。
    """
    a = np.asarray(logits, dtype=np.float32)
    if a.ndim == 3:
        if a.shape[1] == 1:      # [T, 1, C] —— 本模型的布局
            a = a[:, 0, :]
        elif a.shape[0] == 1:    # 兼容 [1, T, C]
            a = a[0]
        else:
            a = a.reshape(a.shape[0], -1)
    idx = a.argmax(axis=1)
    out, prev = [], -1
    for i in idx:
        i = int(i)
        if i != prev and i != 0:
            out.append(chr(charset[i]) if i in charset else '')
        prev = i
    return ''.join(out)


def weight_breakdown(model_path: str) -> str:
    """统计 initializer 的各精度占比——用来判断「是否已经量化过」"""
    import collections
    m = onnx.load(model_path)
    kinds = collections.Counter()
    nbytes = collections.Counter()
    for t in m.graph.initializer:
        kinds[str(t.data_type)] += 1
        nbytes[str(t.data_type)] += len(t.raw_data)
    # 1=float32 2=uint8 3=int8 6=int32 7=int64
    name = {'1': 'fp32', '2': 'uint8', '3': 'int8', '6': 'int32', '7': 'int64'}
    parts = []
    for k, n in kinds.most_common():
        parts.append(f'{name.get(k, k)}×{n} ({nbytes[k]/1048576:.2f}MB)')
    return ', '.join(parts)


def run(model_path: str, charset: dict, items):
    sess = ort.InferenceSession(model_path, providers=['CPUExecutionProvider'])
    inp = sess.get_inputs()[0].name
    ok = 0
    rows = []
    for truth, path in items:
        logits = sess.run(None, {inp: preprocess(path)})[0]
        got = decode(logits, charset)
        hit = got == truth
        ok += hit
        rows.append((truth, got, hit))
    return ok, rows


def main():
    charset = load_charset()
    items = []
    for p in sorted(glob.glob(os.path.join(CORPUS, '*.png'))):
        truth = os.path.basename(p).split('_')[0]
        items.append((truth, p))
    if not items:
        raise SystemExit('语料为空: ' + CORPUS)

    print(f'语料 {len(items)} 张, 字符表 {len(charset)} 项')
    print(f'原模型权重构成: {weight_breakdown(MODEL)}')
    base_ok, base_rows = run(MODEL, charset, items)
    base_size = os.path.getsize(MODEL) / 1048576
    print(f'\n=== 原模型 ===')
    print(f'  体积 {base_size:.2f} MB   正确 {base_ok}/{len(items)}'
          f' = {base_ok/len(items)*100:.1f}%')
    for t, g, h in base_rows:
        print(f'    {"ok " if h else "X  "} {t} -> {g}')

    # ---- 动态量化到 int8 ----
    out_dyn = 'build/captcha_dynamic_int8.onnx'
    os.makedirs('build', exist_ok=True)
    from onnxruntime.quantization import quantize_dynamic, QuantType
    quantize_dynamic(MODEL, out_dyn, weight_type=QuantType.QInt8)
    dyn_size = os.path.getsize(out_dyn) / 1048576
    dyn_ok, dyn_rows = run(out_dyn, charset, items)
    print(f'\n=== 动态量化 int8 ===')
    print(f'  体积 {dyn_size:.2f} MB ({dyn_size/base_size*100:.0f}% of 原)'
          f'   正确 {dyn_ok}/{len(items)} = {dyn_ok/len(items)*100:.1f}%')
    for t, g, h in dyn_rows:
        if not h:
            print(f'    X   {t} -> {g}')

    # ---- 结论 ----
    print('\n=== 判定（标准：量化后 ≥ 原模型 90%）===')
    need = base_ok * 0.9
    print(f'  门槛 {need:.1f}/{len(items)}（原模型 {base_ok} 的 90%）')
    print(f'  动态量化: {dyn_ok} -> '
          f'{"通过" if dyn_ok >= need else "不通过"}')
    print(f'  体积收益: {base_size - dyn_size:.2f} MB '
          f'({(1 - dyn_size/base_size)*100:.0f}% 减少)')


if __name__ == '__main__':
    main()
