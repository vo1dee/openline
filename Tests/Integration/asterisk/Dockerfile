FROM alpine:3.22
RUN apk add --no-cache asterisk=20.11.1-r6 asterisk-srtp=20.11.1-r6 asterisk-opus=20.11.1-r6 asterisk-curl=20.11.1-r6 openssl || \
    apk add --no-cache asterisk=20.11.1-r6 asterisk-srtp=20.11.1-r6 openssl
COPY pjsip.conf extensions.conf rtp.conf logger.conf modules.conf asterisk.conf /etc/asterisk/
RUN mkdir -p /etc/asterisk/keys && chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk 2>/dev/null || true
EXPOSE 5060/udp 5060/tcp 5061/tcp
CMD ["sh", "/entry.sh"]
COPY entry.sh /entry.sh
