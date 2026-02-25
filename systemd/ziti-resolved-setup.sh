#!/bin/bash
# Configure systemd-resolved split DNS for OpenZiti tunnel on WSL2.
# Called as ExecStartPost after ziti-edge-tunnel creates the ziti0 interface.
#
# Both eth0 and ziti0 are set as default-route DNS links. systemd-resolved
# sends queries to ALL default-route links in parallel. Ziti DNS returns
# answers for intercepted hostnames and REFUSED for everything else;
# resolved uses whichever link answers successfully.
#
# This means NO hardcoded domain list — any new Ziti service is automatically
# resolvable without touching this script.

set -euo pipefail

# eth0: Rancher Desktop DNS (forwards to Windows host DNS)
resolvectl dns eth0 10.255.255.254
resolvectl domain eth0 ""
resolvectl default-route eth0 yes

# Wait for ziti0 TUN interface to come up
for i in $(seq 1 10); do
    if ip link show ziti0 &>/dev/null; then
        break
    fi
    sleep 1
done

if ! ip link show ziti0 &>/dev/null; then
    echo "ERROR: ziti0 interface did not appear after 10 seconds" >&2
    exit 1
fi

# Wait for the tunnel to finish its own resolved initialization
sleep 2

# ziti0: Ziti DNS as default route — resolved queries both links in parallel
resolvectl dns ziti0 100.64.0.2
resolvectl domain ziti0 ""
resolvectl default-route ziti0 yes

echo "Split DNS configured: eth0=10.255.255.254 + ziti0=100.64.0.2 (both default-route)"
