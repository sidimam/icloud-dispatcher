#!/bin/bash
# iCloudpd 2FA Bot: dispatcher Telegram per i container iCloudpd (un solo bot di casa, prefisso #nome).
# Gira nel container "iCloudpd-2FA-Bot" (immagine docker:cli + bash/curl/jq, socket Docker montato).
# Comandi accettati SOLO dalle chat in ALLOWED_CHATS (chat privata di Simone e gruppo di famiglia):
#   #sofia auth        → avvia la riautenticazione di iCloudpd-sofdimambro (Apple manda il codice ai dispositivi di Sofia)
#   #sofia 123456      → consegna il codice al container (expect in ascolto per 10 minuti dopo l'avvio)
#   #stato             → giorni rimanenti del cookie di ogni container
#   #aiuto             → elenco comandi
# Nomi: famiglia simone daniela sofia maria. Richiede: TELEGRAM_TOKEN, ALLOWED_CHATS (separate da virgola).
set -u
API="https://api.telegram.org/bot${TELEGRAM_TOKEN}"
STATE=/app/state; mkdir -p "$STATE"; OFF="$STATE/offset"; [ -f "$OFF" ] || echo 0 > "$OFF"
declare -A C=([famiglia]=iCloudpd-Family [simone]=iCloudpd-sdimambro [daniela]=iCloudpd-dmanieri [sofia]=iCloudpd-sofdimambro [maria]=iCloudpd-mdimambro)
log(){ echo "$(date '+%F %T') $*"; }
say(){ curl -s -X POST "$API/sendMessage" -d chat_id="$1" --data-urlencode text="$2" >/dev/null; }
allowed(){ case ",${ALLOWED_CHATS}," in *",$1,"*) return 0;; *) return 1;; esac; }
cookie_of(){ docker exec "$1" sh -c 'ls /config | grep -E "^[a-z0-9]+(com|it)$" | head -1'; }
auth_running(){ docker exec "$1" sh -c 'pgrep -f authenticate.exp >/dev/null' 2>/dev/null; }
start_auth(){ # $1 container
  local ck; ck=$(cookie_of "$1")
  docker exec "$1" sh -c "rm -f /config/${ck} /config/${ck}.session; mkdir -p /tmp/icloudpd; : > /tmp/icloudpd/expect_input.txt; chmod 666 /tmp/icloudpd/expect_input.txt; nohup /usr/bin/expect /opt/authenticate.exp >/tmp/icloudpd/reauth.log 2>&1 &"
}
days_of(){ docker exec "$1" cat /config/DAYS_REMAINING 2>/dev/null | tr -dc '0-9-'; }
log "avvio; chat ammesse: ${ALLOWED_CHATS}; container: ${!C[*]}"
while true; do
  OFFSET=$(( $(cat "$OFF") + 1 ))
  R=$(curl -s --max-time 70 "$API/getUpdates" -d offset="$OFFSET" -d timeout=50 -d allowed_updates='["message"]') || { sleep 5; continue; }
  echo "$R" | jq -e '.ok' >/dev/null 2>&1 || { log "risposta non valida: ${R:0:120}"; sleep 10; continue; }
  while IFS=$'\t' read -r UPD CHAT TEXT FROM; do
    [ -z "$UPD" ] && continue
    echo "$UPD" > "$OFF"
    allowed "$CHAT" || { log "ignoro chat $CHAT ($FROM): $TEXT"; continue; }
    T=$(echo "$TEXT" | tr 'A-Z' 'a-z' | sed -E 's/^\s+|\s+$//g')
    case "$T" in
      "#aiuto"|"#help") say "$CHAT" "Comandi iCloudpd: #stato · #<nome> auth (riautentica) · #<nome> 123456 (codice Apple). Nomi: famiglia, simone, daniela, sofia, maria.";;
      "#stato") M="📷 iCloudpd, giorni al rinnovo 2FA:"; for n in famiglia simone daniela sofia maria; do d=$(days_of "${C[$n]}"); M="$M"$'\n'"• $n: ${d:-n/d}"; auth_running "${C[$n]}" && M="$M (autenticazione in corso)"; done; say "$CHAT" "$M";;
      \#*)
        N=${T#\#}; N=${N%% *}; A=${T#* }; CT=${C[$N]:-}
        [ -z "$CT" ] && { say "$CHAT" "Nome '$N' sconosciuto. Nomi: ${!C[*]}"; continue; }
        if [ "$A" = "auth" ]; then
          if auth_running "$CT"; then say "$CHAT" "⏳ $N: autenticazione già in corso, aspetto il codice (#$N 123456)."; continue; fi
          start_auth "$CT"; log "$FROM avvia auth su $CT"
          say "$CHAT" "🔐 $N: riautenticazione avviata su $CT. Apple sta inviando il codice a 6 cifre ai dispositivi dell'account. Rispondi entro 10 minuti con: #$N 123456"
        elif [[ "$A" =~ ^[0-9]{6}$ ]]; then
          if ! auth_running "$CT"; then say "$CHAT" "⚠️ $N: nessuna autenticazione in corso. Prima: #$N auth"; continue; fi
          docker exec "$CT" sh -c "printf '%s\n' '$A' >> /tmp/icloudpd/expect_input.txt"; log "$FROM consegna codice a $CT"
          sleep 20
          if auth_running "$CT"; then say "$CHAT" "⏳ $N: codice consegnato, Apple sta verificando…"; sleep 25; fi
          d=$(days_of "$CT"); ck=$(cookie_of "$CT")
          if [ -n "$ck" ] && docker exec "$CT" grep -q "X-APPLE-WEBAUTH-USER" "/config/$ck" 2>/dev/null; then say "$CHAT" "✅ $N: autenticazione riuscita, cookie rinnovato${d:+ ($d giorni)}. Il download riprende da solo."; else say "$CHAT" "❌ $N: autenticazione non riuscita (codice errato o scaduto). Riprova con #$N auth"; fi
        else say "$CHAT" "Comando non capito. Usa: #$N auth oppure #$N 123456"; fi;;
      *) ;;
    esac
  done < <(echo "$R" | jq -r '.result[] | [.update_id, .message.chat.id, (.message.text // ""), (.message.from.first_name // "")] | @tsv')
done
