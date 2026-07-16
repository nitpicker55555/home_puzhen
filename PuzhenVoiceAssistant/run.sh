#!/bin/bash
# Loads .env and launches the assistant, so the API key stays out of the code.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f .env ]; then
    echo "⚠️  没有找到 .env。请先执行：cp .env.example .env  然后填入你的 AIHUBMIX_API_KEY"
    exit 1
fi

set -a; . ./.env; set +a          # export everything defined in .env

BIN="./build/PuzhenAssistant.app/Contents/MacOS/PuzhenAssistant"
if [ ! -x "$BIN" ]; then
    echo "还没编译，正在编译…"; ./build.sh
fi
exec "$BIN"
