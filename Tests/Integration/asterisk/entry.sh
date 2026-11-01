#!/bin/sh
# A throwaway certificate for testing rejection of untrusted TLS servers.
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=openline-test" \
    -keyout /etc/asterisk/keys/tls.key -out /etc/asterisk/keys/tls.crt 2>/dev/null
exec asterisk -f -U root -vvv
