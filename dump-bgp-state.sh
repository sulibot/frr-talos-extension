#!/bin/sh
set -eu
CONFIG_JSON="/tmp/config.json"

if [ ! -f "$CONFIG_JSON" ]; then
  exit 0
fi

PEER_IPV6=$(python3 <<'PY'
import json, sys
try:
    ctx = json.load(open('/tmp/config.json'))
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(0)
pc = ctx.get('bgp', {}).get('cilium', {}).get('peering', {}).get('ipv6', {})
print(pc.get('remote', '') if isinstance(pc, dict) else '')
PY
)

if [ -z "$PEER_IPV6" ]; then
  exit 0
fi

echo "[$(date -Is)] Dumping BGP neighbor state for ${PEER_IPV6}"
vtysh -c "show bgp neighbor ${PEER_IPV6} detail" || true
