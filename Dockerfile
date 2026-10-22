# Immagine opzionale: equivale a docker:cli + bash/curl/jq con bot.sh incorporato.
FROM docker:cli
RUN apk add --no-cache bash curl jq
COPY bot.sh /app/bot.sh
RUN chmod 755 /app/bot.sh
ENV TZ=Europe/Rome
ENTRYPOINT ["bash","/app/bot.sh"]
