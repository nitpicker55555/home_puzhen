#!/bin/bash
# 汇总助手实际的 API 花费(精确 token,来自 usage 台账)。
U=~/Library/Logs/PuzhenAssistant-usage.jsonl
[ -f "$U" ] || { echo "还没有用量记录 —— 说几轮话后再看。"; exit 0; }
python3 - "$U" <<'PY'
import json, sys
tot=n=tin=ain=tout=aout=0
first=last=None
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: j=json.loads(line)
    except: continue
    n+=1; tot+=j.get("usd",0)
    tin+=j.get("tin",0); ain+=j.get("ain",0); tout+=j.get("tout",0); aout+=j.get("aout",0)
    first=first or j.get("time"); last=j.get("time")
print(f"时间范围: {first} ~ {last}")
print(f"API 调用: {n} 次")
print(f"tokens:   文字入 {tin}  音频入 {ain}  文字出 {tout}  音频出 {aout}")
print(f"累计花费: ${tot:.4f}  ≈  ¥{tot*7.2:.3f}")
PY
