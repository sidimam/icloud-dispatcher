#!/bin/bash
# iCloudpd: il giorno prima della scadenza del cookie 2FA avvisa su Telegram e avvia da solo la riautenticazione
# (User Scripts, ogni giorno alle 09:30). Si appoggia alle funzioni native dell'immagine boredazfcuk/icloudpd:
#  - il container, con notification_type=telegram + telegram_polling=true, manda i promemoria da notification_days giorni
#    prima; i comandi "#nome auth" e "#nome 123456" li legge il container iCloudpd-dispatcher (scripts/unraid/icloudpd_2fa_bot.sh) dal bot di casa;
#  - qui, quando /config/DAYS_REMAINING vale 1 (o il cookie e' gia' scaduto), facciamo noi quello che farebbe "<user> auth":
#    avviso in chat, 60 s di attesa, poi rimozione del cookie e avvio di /opt/authenticate.exp. Apple manda il codice ai
#    dispositivi dell'utente, che risponde nella chat del bot con "<user> 123456": il polling del container lo passa a expect.
# Un solo bot (quello di casa): il polling lo fa SOLO il dispatcher, i container iCloudpd hanno telegram_polling=false.
STATE=/boot/config/plugins/user.scripts/icloudpd_2fa_state; mkdir -p "$STATE"
# Chat del GRUPPO per i messaggi del flusso 2FA (promemoria a 3/2 giorni, avvio a 1 giorno). Le notifiche operative dei container
# (avvio, download, re-confirmed) vanno invece nella chat privata del bot (telegram_chat_id dei container).
source /boot/config/secrets/telegram.env 2>/dev/null; GROUP=$(echo "${TELEGRAM_CHAT_ID_FAMIGLIA:-}" | tr -d '"')
for C in $(docker ps --format '{{.Names}}' | grep -i '^icloudpd'); do
  env_of(){ docker inspect "$C" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^$1=" | cut -d= -f2-; }
  TOKEN=$(env_of telegram_token); CHAT=$(env_of telegram_chat_id); APPLE=$(env_of apple_id)
  case "$C" in iCloudpd-Family) USR=famiglia;; iCloudpd-sdimambro) USR=simone;; iCloudpd-dmanieri) USR=daniela;; iCloudpd-sofdimambro) USR=sofia;; iCloudpd-mdimambro) USR=maria;; *) echo "$C: nome non mappato, salto"; continue;; esac
  DAYS=$(docker exec "$C" cat /config/DAYS_REMAINING 2>/dev/null | tr -dc '0-9-')
  [ -z "$DAYS" ] && { echo "$C: giorni n/d, salto"; continue; }
  [ -z "$TOKEN" ] || [ -z "$CHAT" ] && { echo "$C: Telegram non configurato (token/chat), salto ($DAYS giorni)"; continue; }
  echo "$C: $DAYS giorni, utente $USR"
  TODAY=$(date +%F); DEST="${GROUP:-$CHAT}"
  if [ "$DAYS" -gt 3 ]; then rm -f "$STATE/$C" "$STATE/$C.reminder"; continue; fi
  if [ "$DAYS" -gt 1 ]; then
    [ "$(cat "$STATE/$C.reminder" 2>/dev/null)" = "$TODAY" ] && continue
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" -d chat_id="${DEST}" --data-urlencode text="📷 iCloud Foto di ${USR}: il cookie Apple scade tra ${DAYS} giorni. Il rinnovo partirà da solo il giorno prima alle 09:30; per anticiparlo rispondi qui con: #${USR} auth" >/dev/null
    echo "$TODAY" > "$STATE/$C.reminder"; echo "$C: promemoria inviato"; continue
  fi
  [ "$(cat "$STATE/$C" 2>/dev/null)" = "$TODAY" ] && { echo "$C: gia' avviato oggi"; continue; }
  MSG="🔐 iCloud Foto di ${USR}: il cookie Apple di ${APPLE} scade domani. Tra 1 minuto avvio la riautenticazione: Apple inviera' il codice a 6 cifre sui tuoi dispositivi. Quando arriva rispondi QUI con: #${USR} 123456 (al posto di 123456 il codice ricevuto). Hai 10 minuti."
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" -d chat_id="${DEST}" --data-urlencode text="$MSG" >/dev/null
  sleep 60
  CK=$(docker exec "$C" sh -c 'ls /config | grep -E "^[a-z0-9]+(com|it)$" | head -1')
  docker exec "$C" sh -c "rm -f /config/${CK} /config/${CK}.session; mkdir -p /tmp/icloudpd; touch /tmp/icloudpd/expect_input.txt; chmod 666 /tmp/icloudpd/expect_input.txt; nohup /usr/bin/expect /opt/authenticate.exp >/tmp/icloudpd/reauth.log 2>&1 &"
  echo "$TODAY" > "$STATE/$C"; echo "$C: riautenticazione avviata"
done
