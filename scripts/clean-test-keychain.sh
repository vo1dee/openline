#!/bin/bash
# Removes throwaway Keychain items left by UI test profiles.
security dump-keychain 2>/dev/null | grep -o '"org.openline.test[^"]*"' | tr -d '"' | sort -u | while read -r service; do
    while security delete-generic-password -s "$service" >/dev/null 2>&1; do :; done
done
