#!/bin/bash
# iCloud 2FA autostart (User Scripts, ogni giorno alle 09:30): per ogni container iCloud di Unraid avvisa su Telegram
# quando la sessione Apple sta per scadere e il giorno prima avvia da solo la riautenticazione; l'utente risponde nel
# gruppo con "#nome 123456" e il container icloud-dispatcher consegna il codice.
#   • boredazfcuk/icloudpd  (foto):         giorni da /config/DAYS_REMAINING; riautenticazione = /opt/authenticate.exp
#   • mandarons/icloud-drive (iCloud Drive): giorni = scadenza del cookie di fiducia X-APPLE-WEBAUTH-HSA-TRUST (~90 gg,
#     l'app lo rinnova da sola finche' la sessione vive); riautenticazione = `icloud --username …`
#     con il codice letto da una FIFO (/tmp/2fa.fifo), password dal keyring del container (primo login manuale)
# Nomi utente da config.json del dispatcher (/mnt/user/appdata/icloud-dispatcher/config.json), chiave "container".
STATE=/boot/config/plugins/user.scripts/icloud_2fa_state; mkdir -p "$STATE"
CFG=/mnt/user/appdata/icloud-dispatcher/config.json
source /boot/config/secrets/telegram.env 2>/dev/null; GROUP=$(echo "${TELEGRAM_CHAT_ID_FAMIGLIA:-}" | tr -d '"'); TOKEN=${TELEGRAM_BOT_TOKEN:-}
name_of(){ tr -d '\n' < "$CFG" | grep -o "\"[a-z0-9-]*\": *{[^}]*\"container\": *\"$1\"" | sed 's/^"\([^"]*\)".*/\1/' | head -1; }
tg(){ curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" -d chat_id="$1" --data-urlencode text="$2" >/dev/null; }
for C in $(docker ps --format '{{.Names}}'); do
  IMG=$(docker inspect "$C" --format '{{.Config.Image}}')
  case "$IMG" in *icloudpd*) TYPE=icloudpd; ICON="📷"; WHAT="iCloud Foto";; *icloud-drive*) TYPE=iclouddrive; ICON="📁"; WHAT="iCloud Drive";; *) continue;; esac
  USR=$(name_of "$C"); [ -z "$USR" ] && { echo "$C: non in config.json, salto"; continue; }
  env_of(){ docker inspect "$C" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^$1=" | cut -d= -f2-; }
  if [ "$TYPE" = icloudpd ]; then
    [ -z "$TOKEN" ] && TOKEN=$(env_of telegram_token); CHAT=$(env_of telegram_chat_id); APPLE=$(env_of apple_id)
    DAYS=$(docker exec "$C" cat /config/DAYS_REMAINING 2>/dev/null | tr -dc '0-9-')
  else
    CONF=$(docker inspect "$C" --format '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}')
    APPLE=$(grep -m1 'username:' "$CONF/config.yaml" 2>/dev/null | sed 's/.*username: *"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/')
    J=$(ls "$CONF"/session_data/* 2>/dev/null | grep -v '\.session$' | head -1)
    E=$(sed -n 's/^Set-Cookie3: X-APPLE-WEBAUTH-HSA-TRUST=.*expires="\([^"]*\)Z".*/\1/p' "$J" 2>/dev/null | head -1)
    [ -n "$E" ] && DAYS=$(( ($(date -u -d "$E" +%s) - $(date +%s)) / 86400 )) || DAYS=""
    CHAT=$GROUP
  fi
  [ -z "$DAYS" ] && { echo "$C: giorni n/d, salto"; continue; }
  [ -z "$TOKEN" ] && { echo "$C: token Telegram mancante, salto ($DAYS giorni)"; continue; }
  echo "$C ($TYPE): $DAYS giorni, utente $USR"
  TODAY=$(date +%F); DEST="${GROUP:-$CHAT}"
  if [ "$DAYS" -gt 3 ]; then rm -f "$STATE/$C" "$STATE/$C.reminder"; continue; fi
  if [ "$DAYS" -gt 1 ]; then
    [ "$(cat "$STATE/$C.reminder" 2>/dev/null)" = "$TODAY" ] && continue
    tg "$DEST" "$ICON $WHAT di ${USR}: la sessione Apple scade tra ${DAYS} giorni. Il rinnovo partirà da solo il giorno prima alle 09:30; per anticiparlo rispondi qui con: #${USR} auth"
    echo "$TODAY" > "$STATE/$C.reminder"; echo "$C: promemoria inviato"; continue
  fi
  [ "$(cat "$STATE/$C" 2>/dev/null)" = "$TODAY" ] && { echo "$C: gia' avviato oggi"; continue; }
  tg "$DEST" "🔐 $ICON $WHAT di ${USR}: la sessione Apple di ${APPLE} scade domani. Tra 1 minuto avvio la riautenticazione: Apple inviera' il codice a 6 cifre sui tuoi dispositivi. Quando arriva rispondi QUI con: #${USR} 123456 (al posto di 123456 il codice ricevuto). Hai 10 minuti."
  sleep 60
  if [ "$TYPE" = icloudpd ]; then
    CK=$(docker exec "$C" sh -c 'ls /config | grep -E "^[a-z0-9]+(com|it)$" | head -1')
    docker exec "$C" sh -c "rm -f /config/${CK} /config/${CK}.session; mkdir -p /tmp/icloudpd; touch /tmp/icloudpd/expect_input.txt; chmod 666 /tmp/icloudpd/expect_input.txt; nohup /usr/bin/expect /opt/authenticate.exp >/tmp/icloudpd/reauth.log 2>&1 &"
  else
    docker exec "$C" sh -c "rm -f /tmp/2fa.fifo /tmp/2fa.log; mkfifo -m 666 /tmp/2fa.fifo; nohup sh -c 'exec 3<>/tmp/2fa.fifo; su-exec abc icloud --username=$APPLE --session-directory=/config/session_data <&3 >/tmp/2fa.log 2>&1; echo EXIT=\$? >>/tmp/2fa.log; rm -f /tmp/2fa.fifo' >/dev/null 2>&1 &"
  fi
  echo "$TODAY" > "$STATE/$C"; echo "$C: riautenticazione avviata"
done
