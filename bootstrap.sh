#!/usr/bin/env bash
# bootstrap.sh — the ONE script for a freshly installed Raspberry Pi.
#
# Same script for every device: it finds out by itself whether an Aether
# gateway already exists. If it does, this Pi joins as a node (enrollment with
# a 6-digit code to confirm on the gateway); if not, it offers to become the
# gateway of a new Aether.
#
# Before: Raspberry Pi Imager -> Raspberry Pi OS Lite 64-bit (trixie), with
# hostname, user, WiFi and SSH key set in the advanced options.
# Then, on the Pi, as the normal user:
#
#   curl -fsSL https://raw.githubusercontent.com/mcarli-dev/aether-bootstrap/main/bootstrap.sh | sudo bash
#
# It asks for a GitHub token with read access to mcarli-dev/aether-services (or takes
# AETHER_TOKEN from the environment: sudo AETHER_TOKEN=... bash bootstrap.sh).
# Safe to re-run: every step checks before acting.
#
# After it: `aether modules`, `aether add <module>`, `aether apply` — or the
# local GUI at https://<hostname>.local:8099.
set -euo pipefail

REPO_URL="${AETHER_REPO_URL:-https://github.com/mcarli-dev/aether-services.git}"
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
ask()  { local a; read -r -p "$1 " a </dev/tty; printf '%s' "$a"; }

# ---- 0. who and where ---------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "run it with sudo (… | sudo bash)"
U="${SUDO_USER:-}"
[ -n "$U" ] && [ "$U" != root ] || die "run it as a normal user with sudo, not as root"
H="$(getent passwd "$U" | cut -d: -f6)"
MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo unknown)"
grep -q "Raspberry Pi" <<<"$MODEL" || die "not a Raspberry Pi ($MODEL)"
[ "$(dpkg --print-architecture)" = arm64 ] || die "64-bit Raspberry Pi OS required"
. /etc/os-release
[ "${VERSION_CODENAME:-}" = trixie ] || echo "warning: tested on Debian 13 trixie, this is ${PRETTY_NAME:-?}"
as_user() { runuser -u "$U" -- env HOME="$H" "$@"; }
say "Aether bootstrap — $(hostname) ($MODEL), user $U"

# ---- 1. packages ----------------------------------------------------------------------
say "1/5 base packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git curl ca-certificates openssl \
    avahi-daemon avahi-utils python3 python3-yaml i2c-tools >/dev/null
echo "    ok"

# ---- 2. the repository ------------------------------------------------------------------
say "2/5 Aether repository in $H/aether"
TOKEN_FILE="$H/.aether-token"
if [ ! -s "$TOKEN_FILE" ]; then
    T="${AETHER_TOKEN:-}"
    [ -n "$T" ] || T="$(ask "GitHub token (read access to mcarli-dev/aether-services):")"
    [ -n "$T" ] || die "a token is required"
    install -m 600 -o "$U" -g "$U" /dev/null "$TOKEN_FILE"
    printf '%s\n' "$T" > "$TOKEN_FILE"
fi
RTOKEN="$H/.aether-registry-token"          # classic token, read:packages only: release images
if [ ! -s "$RTOKEN" ]; then
    R="${AETHER_REGISTRY_TOKEN:-}"
    [ -n "$R" ] || R="$(ask "Registry token (classic, read:packages) for the release images — empty: build them on this Pi:")"
    if [ -n "$R" ]; then
        install -m 600 -o "$U" -g "$U" /dev/null "$RTOKEN"
        printf '%s\n' "$R" > "$RTOKEN"
    fi
fi
HELPER='!f() { echo username=x-access-token; echo "password=$(cat ~/.aether-token)"; }; f'
if [ -d "$H/aether/.git" ] && as_user git -C "$H/aether" remote get-url origin | grep -q "/aether.git$"; then
    as_user git -C "$H/aether" pull --rebase --quiet && echo "    updated"
else
    [ ! -e "$H/aether" ] || die "$H/aether exists and is not a checkout of aether-services: move it away and run again"
    as_user git -c credential.helper="$HELPER" clone --quiet "$REPO_URL" "$H/aether" || die "clone failed: token or network?"
    echo "    cloned"
fi
as_user git -C "$H/aether" config credential.helper "$HELPER"
as_user git -C "$H/aether" config user.name "$(hostname)"
as_user git -C "$H/aether" config user.email "$(hostname)@aether.local"
ln -sf "$H/aether/bin/aether" /usr/local/bin/aether
A="$H/aether"
DEVFILE="$H/.aether/state/devices/$(hostname).yaml"     # desired state: outside the repository

# ---- 3. docker ----------------------------------------------------------------------------
say "3/5 Docker"
if command -v docker >/dev/null 2>&1; then echo "    present: $(docker --version)"
else sh "$A/modules/docker/get-docker.sh" >/dev/null && echo "    installed"; fi
usermod -aG docker "$U"
systemctl enable --now docker >/dev/null

# ---- 4. join an Aether, or start one --------------------------------------------------------
say "4/5 looking for an Aether gateway"
if ip link show eth0 >/dev/null 2>&1 && [ ! -f "$DEVFILE" ]; then
    # Wired: the gateway hands out the address. Fails harmlessly (and restores
    # the previous profile) if there is no gateway yet.
    bash "$A/modules/network/node-eth0.sh" >/dev/null 2>&1 || true
fi
# Any announcement means a gateway exists; `aether enroll` then picks the
# address this Pi can actually reach (a WiFi node cannot reach the wired one).
GW="$(avahi-browse -rtpk _aether-enroll._tcp 2>/dev/null | awk -F';' '$1=="=" && $3=="IPv4"{print $8}' | paste -sd' ')"
if [ -f "$DEVFILE" ]; then
    echo "    $(hostname) is already configured ($DEVFILE)"
elif [ -n "$GW" ]; then
    echo "    gateway found: $GW — this Pi joins as a NODE"
    echo "    A code will be shown: approve it on the gateway (GUI, Nodes tab, or: aether nodes approve <code>)."
    as_user env PYTHONUNBUFFERED=1 aether enroll </dev/tty
else
    echo "    no gateway found on the network (mDNS _aether-enroll._tcp)."
    a="$(ask "Make this Pi the GATEWAY of a new Aether? [y/N]")"
    [[ "$a" =~ ^[yY] ]] || die "nothing to do: power on the gateway and run the script again"
    if [ ! -f "$H/.aether-ca/node-ca.key" ]; then
        a="$(ask "CA: [r]estore from a backup (put the files in ~/.aether-ca, then press r) or [n]ew Aether? [r/n]")"
        if [[ "$a" =~ ^[nN] ]]; then as_user bash "$A/modules/identity/aether-pki.sh" init-ca
        else [ -f "$H/.aether-ca/node-ca.key" ] || die "~/.aether-ca/node-ca.key not found"; fi
    fi
    b="$(ask "Backup of the system state (aether backup) to restore, if any — path or empty:")"
    if [ -n "$b" ]; then
        as_user aether restore "$b" || die "restore failed"
    fi
    if [ ! -f "$DEVFILE" ]; then
        as_user python3 - "$A" "$(hostname)" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
from aether import device
d = device.Device(host=sys.argv[2], node_id="gateway",
    modules={m: {} for m in ["zenoh-router", "enrollment", "dhcp", "firewall", "ptp", "vehicle-state-manager",
                             "gateway-logic", "liveness-monitor", "system-monitor", "dashboard-bridge",
                             "system-status"]})
d.save()
print(f"    {d.host} configured as the gateway, with the system modules")
PY
    fi
fi

# ---- 5. apply ---------------------------------------------------------------------------------
say "5/5 applying the configuration (core modules: network, docker, identity, agent, GUI)"
as_user aether apply </dev/tty || die "aether apply did not succeed (see above)"
say "Done."
cat <<EOF
  This Pi is on Aether. From here:
    aether modules            catalog (★ = hardware detected)
    aether add <module>       asks only for the pins
    aether apply              applies
  or the GUI: https://$(hostname).local:8099  (the password is printed above; for a new one:
  aether gui --set-password)
  The desired state of every device lives on the gateway: back it up there with
  aether backup (keys excluded: keep ~/.aether-ca offline).
EOF
