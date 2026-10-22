# iCloudpd-dispatcher: bot Telegram + GUI web. Costruire su Unraid: docker build -t icloudpd-dispatcher:local .
FROM docker:cli
RUN apk add --no-cache bash curl jq python3 py3-flask tzdata
COPY bot.sh /opt/dispatcher/bot.sh
COPY gui/ /opt/dispatcher/gui/
COPY entrypoint.sh /opt/dispatcher/entrypoint.sh
RUN chmod 755 /opt/dispatcher/bot.sh /opt/dispatcher/entrypoint.sh
ENV TZ=Europe/Rome GUI_PORT=8787 APP_DIR=/app
EXPOSE 8787
ENTRYPOINT ["/opt/dispatcher/entrypoint.sh"]
