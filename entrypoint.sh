#!/bin/bash
# Avvia bot Telegram e GUI; se uno dei due muore, il container esce e Docker lo riavvia.
set -u
mkdir -p "${APP_DIR:-/app}/state"
[ -f "${APP_DIR:-/app}/config.json" ] || cp /opt/dispatcher/gui/config.example.json "${APP_DIR:-/app}/config.json"
bash /opt/dispatcher/bot.sh & BOT=$!
python3 /opt/dispatcher/gui/app.py & GUI=$!
wait -n $BOT $GUI; echo "un processo è terminato, esco"; kill $BOT $GUI 2>/dev/null; exit 1
