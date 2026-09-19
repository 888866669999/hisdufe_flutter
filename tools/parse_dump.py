import re
import sys
s = open(sys.argv[1], encoding='utf-8', errors='replace').read()
out = []
for m in re.finditer(r'text="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', s):
    t = m.group(1).strip()
    if t:
        x = (int(m.group(2)) + int(m.group(4))) // 2
        y = (int(m.group(3)) + int(m.group(5))) // 2
        out.append('%-24s (%d,%d)' % (t[:24], x, y))
print('\n'.join(out) if out else '(no text nodes)')
