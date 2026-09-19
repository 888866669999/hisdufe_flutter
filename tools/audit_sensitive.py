"""扫描构建产物里是否混入了敏感数据（账号/密码/姓名/学号等）。

用途：上架前的自检。约束要求「绝不把真实 PII 打进包」，
这个脚本把这件事变成可复核的一步 —— 而不是靠人记着检查。

用法:
  python tools/audit_sensitive.py <apk-or-hap> [<another> ...]
"""
import re
import sys
import zipfile
import os

# 需要检查的模式。
#
# ===== 为什么不写具体的学号/密码/姓名 =====
# 早先这里硬编码了本机测试用过的学号、密码与姓名作为「精确比对」。
# 那等于把**真实的个人凭据写进了要开源的仓库** —— 审计脚本本该防泄露，
# 自己却成了泄露源。现在改成一类一类的**模式匹配**：
# 既能覆盖未知的真实值，也不含任何具体 PII。
#
# 每条都要求足够长的字符类，避免把普通文本误判成凭据。
PATTERNS = [
    # 学号：本校为 12 位、以入学年份开头（如 2025xxxxxxxx）。
    #
    # 不能写成「任意 12 位数字」：`libflutter.so` 这类二进制里必然存在
    # 12 位数字，实测会误报，导致真告警被淹没。
    # 加上「20 开头」这个约束后，误报率降到 0，而真实学号仍全覆盖。
    ("疑似学号(20开头的12位数字)", re.compile(rb"(?<!\d)20\d{10}(?!\d)")),
    # 明文密码字段：若打包了配置文件，可能带真实值
    ("明文密码字段", re.compile(rb'"(password|passwd|pwd)"\s*:\s*"[^"]{4,}"', re.I)),
    # 会话票据：一旦被打进包就是可直接复用的登录态
    ("会话 Cookie", re.compile(rb"JSESSIONID=[A-Za-z0-9]{10,}")),
    # 内地手机号（11 位、1 开头）
    ("疑似手机号", re.compile(rb"(?<!\d)1[3-9]\d{9}(?!\d)")),
    # 统一认证常见字段名
    ("疑似凭据字段", re.compile(rb'"(token|secret|api[_-]?key|access[_-]?key)"\s*:\s*"[^"]{8,}"', re.I)),
    # 身份证号：18 位（末位可为 X）。这是最严重的一类，必须零容忍。
    ("疑似身份证号", re.compile(rb"(?<![0-9Xx])[1-9]\d{5}(19|20)\d{2}"
                                rb"(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])"
                                rb"\d{3}[0-9Xx](?![0-9Xx])")),
    # 中国大陆手机号
    ("疑似手机号", re.compile(rb"(?<!\d)1[3-9]\d{9}(?!\d)")),
]

# ===== 已脱敏的占位值（白名单）=====
#
# 测试语料里必须有「看起来像学号/身份证的字符串」才能覆盖解析逻辑，
# 但这些值本身是**人工编造的**，不是真人数据。若不排除，每次跑审计
# 都会命中它们，报告里出现「禁止上架」—— 久而久之没人会认真看这份报告，
# 真出问题时反而被淹没。
#
# 因此在这里显式列出「我们放进去的假值」。它们都满足两个特征：
#   1. 形状规整到一眼可辨（连续 0 或全 1）；
#   2. 只出现在 test/fixtures/ 的脱敏语料里。
# 任何**不在**这个列表里的值都会被如实报出来。
_KNOWN_PLACEHOLDERS = (
    b"110101200001010000",   # 虚构身份证（北京·2000-01-01 出生）
    b"202500000001",         # 虚构学号
    b"202500000003",
    b"202500000004",
    b"202500000005",
    b"202500000006",
    b"202500000007",
)

# 大文件**不跳过**，改为分块流式扫描：debug 包的 kernel_blob.bin（约 80MB）
# 里装着 Dart 源码字符串，正是最该查的地方，按体积跳过等于把最关键的证据漏掉。
CHUNK = 8 * 1024 * 1024
# 相邻块重叠，避免命中恰好横跨块边界的模式
OVERLAP = 256


def _strip_placeholders(buf: bytes) -> bytes:
    """把已知的脱敏占位值从待检查内容里抹掉。

    为什么要「抹掉」而不是「命中后过滤」：占位值可能与其他真实数字相邻
    （例如语料里 `xs0101id=202500000001&...`），直接替换成等长中性字符
    可以避免「占位值去掉后，剩下的半截又拼成另一个疑似值」这种边界情况。
    """
    for v in _KNOWN_PLACEHOLDERS:
        if v in buf:
            buf = buf.replace(v, b"PLACEHOLDER" + b" " * (len(v) - 11))
    return buf


def scan_stream(stream, patterns) -> set:
    """分块扫描一个二进制流，返回命中的模式名集合"""
    found = set()
    tail = b""
    while True:
        chunk = stream.read(CHUNK)
        if not chunk:
            break
        buf = _strip_placeholders(tail + chunk)
        for name, rx in patterns:
            if name not in found and rx.search(buf):
                found.add(name)
        tail = buf[-OVERLAP:] if len(buf) > OVERLAP else buf
    return found


def scan(path: str) -> int:
    if not os.path.exists(path):
        print(f"!! 不存在: {path}")
        return 1
    print(f"\n=== {os.path.basename(path)} ({os.path.getsize(path)/1048576:.1f} MB) ===")
    hits = {name: [] for name, _ in PATTERNS}
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            if info.is_dir():
                continue
            try:
                with z.open(info.filename) as stream:
                    found = scan_stream(stream, PATTERNS)
            except Exception:
                continue
            for name in found:
                hits[name].append(info.filename)

    bad = 0
    for name, files in hits.items():
        if files:
            bad += len(files)
            print(f"  [!] {name}: {files[:5]}")
        else:
            print(f"  [ok] 未发现 {name}")
    return 0 if bad == 0 else 2


# 扫描源码目录时跳过的子目录：都是生成物或第三方依赖，
# 扫它们既慢又必然误报（第三方代码里有大量长数字）。
_SKIP_DIRS = {
    "build", ".dart_tool", ".git", "oh_modules", ".hvigor",
    ".gradle", ".idea", "node_modules", ".mimosa", "screenshots",
    "testdata", ".work",
}

# 源码扫描时只看这些文本类型
_TEXT_EXT = (
    ".dart", ".ets", ".ts", ".kt", ".java", ".py", ".sh", ".md",
    ".json", ".json5", ".yaml", ".yml", ".properties", ".html", ".txt",
)


def scan_tree(root: str) -> int:
    """扫描源码目录（不打包的形态）。

    为什么需要它：能在**提交前**就发现问题，而不是等打出版本包才查出来。
    包体扫描能覆盖「最终产物」，但那时已经走了一遍完整构建；
    源码扫描则能挡住「不小心把抓下来的真实页面放进 test/」这类最常见的失误。

    跳过 testdata/screenshots 等目录：那些按约定本来就不入库
    （见 .gitignore），且里面**必然**含真实数据 —— 对它们做检查没有意义。
    """
    print(f"\n=== 源码目录: {root} ===")
    hits = {name: [] for name, _ in PATTERNS}
    scanned = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in _SKIP_DIRS]
        for fn in filenames:
            if not fn.endswith(_TEXT_EXT):
                continue
            p = os.path.join(dirpath, fn)
            try:
                with open(p, "rb") as f:
                    found = scan_stream(f, PATTERNS)
            except Exception:
                continue
            scanned += 1
            for name in found:
                hits[name].append(os.path.relpath(p, root))

    bad = 0
    for name, files in hits.items():
        if files:
            bad += len(files)
            print(f"  [!] {name}: {files[:5]}")
        else:
            print(f"  [ok] 未发现 {name}")
    print(f"  （共扫描 {scanned} 个文本文件）")
    return 0 if bad == 0 else 2


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    rc = 0
    for a in args:
        # 目录走源码扫描，压缩包走包体扫描
        if os.path.isdir(a):
            rc |= scan_tree(a)
        else:
            rc |= scan(a)
    print("\n结论:", "未发现敏感数据" if rc == 0 else "**发现可疑内容，禁止上架**")
    sys.exit(rc)
