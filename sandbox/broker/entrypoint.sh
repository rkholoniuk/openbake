#!/bin/sh
set -eu
KEY="$(tr -d '\r\n' < /run/secrets/llm_key)"
[ -n "$KEY" ] || { echo "secrets/llm_key is empty" >&2; exit 1; }

# sk-ant-oat...  subscription token from `claude setup-token` -> Authorization: Bearer
# anything else  Console API key                              -> x-api-key
case "$KEY" in
  sk-ant-oat*) AUTHORIZATION="Bearer $KEY"; X_API_KEY=""; echo "broker: subscription token" ;;
  *)           AUTHORIZATION="";            X_API_KEY="$KEY"; echo "broker: API key" ;;
esac

# The runtime's own resolver: 127.0.0.11 under Docker, the VM's nameserver elsewhere.
RESOLVER="$(sed -n 's/^nameserver[[:space:]]*//p' /etc/resolv.conf | head -1)"
[ -n "$RESOLVER" ] || { echo "no nameserver in /etc/resolv.conf" >&2; exit 1; }
case "$RESOLVER" in *:*) RESOLVER="[$RESOLVER]" ;; esac

sed -e "s|__AUTHORIZATION__|$AUTHORIZATION|" -e "s|__X_API_KEY__|$X_API_KEY|" \
  -e "s|__RESOLVER__|$RESOLVER|" \
  /etc/openbake/nginx.conf.template > /tmp/nginx.conf
chmod 600 /tmp/nginx.conf
exec nginx -g 'daemon off;' -c /tmp/nginx.conf
