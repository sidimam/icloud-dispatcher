# iCloudpd-dispatcher

Rinnovo del cookie 2FA Apple dei container [boredazfcuk/icloudpd](https://github.com/boredazfcuk/docker-icloudpd) **con un solo bot Telegram**,
condiviso fra più container e con il resto della casa.

## Il problema

Il cookie di autenticazione Apple dura circa 30 giorni. L'immagine icloudpd sa già riautenticarsi da Telegram
(`telegram_polling=true`: legge `<user> auth` e `<user> 123456` dalla chat), ma il polling di Telegram (`getUpdates` con offset)
è esclusivo: due container sullo stesso bot si rubano i messaggi. Servirebbe un bot per container.

## La soluzione

Un piccolo container, `iCloudpd-dispatcher`, è l'unico a leggere il bot. Riconosce il prefisso `#nome` e consegna il comando
al container giusto tramite il socket Docker:

| Messaggio in chat        | Effetto                                                                                  |
|--------------------------|------------------------------------------------------------------------------------------|
| `#sofia auth`            | cancella cookie+sessione di `iCloudpd-sofdimambro` e avvia `/opt/authenticate.exp` (password dal portachiavi del container); Apple invia il codice ai dispositivi dell'account |
| `#sofia 123456`          | scrive il codice in `/tmp/icloudpd/expect_input.txt` del container (expect lo attende 10 minuti) e conferma l'esito |
| `#stato`                 | giorni rimanenti del cookie di ogni container                                            |
| `#aiuto`                 | elenco comandi                                                                           |

I container iCloudpd restano con `telegram_polling=false` e usano il bot solo per **inviare** i promemoria
(`notification_type=telegram`, `telegram_token`, `telegram_chat_id`, `notification_days=3`).

Lo script `unraid/icloudpd_2fa_autostart.sh` (User Scripts, ogni giorno) completa il flusso: a **1 giorno** dalla scadenza avvisa
nella chat e avvia da solo la riautenticazione, così all'utente resta solo da rispondere `#nome 123456`.

## Installazione (Unraid)

1. Copia `bot.sh` in `/mnt/user/appdata/icloudpd-dispatcher/bot.sh`.
2. Importa `unraid/my-iCloudpd-dispatcher.xml` in `/boot/config/plugins/dockerMan/templates-user/` e compila
   `TELEGRAM_TOKEN` e `ALLOWED_CHATS` (chat id separate da virgola: solo da queste chat vengono accettati i comandi).
3. Avvia il container (immagine `docker:cli`; all'avvio installa bash, curl e jq ed esegue `bot.sh`). In alternativa costruisci
   l'immagine con il `Dockerfile`.
4. Adatta la mappa nome → container in `bot.sh` (`declare -A C=(...)`) e in `unraid/icloudpd_2fa_autostart.sh`.
5. Nei container iCloudpd: `notification_type=telegram`, `telegram_token`, `telegram_chat_id`, `telegram_polling=false`,
   `notification_days=3`. Attenzione: se il container era già inizializzato, i valori vanno cambiati anche in `/config/icloudpd.conf`,
   perché l'immagine non riscrive quelli esistenti.

## Sicurezza

- Il socket Docker dà al dispatcher il controllo dell'host: il container esegue solo `docker exec` sui nomi mappati, ma va trattato come root.
- I comandi sono accettati solo dalle chat in `ALLOWED_CHATS`; nessuno stato persistente oltre all'offset Telegram (`state/offset`).
- Il codice 2FA transita in chiaro nella chat Telegram: è monouso e vale pochi minuti.

Licenza MIT.
