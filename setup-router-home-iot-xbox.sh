#!/bin/sh
#
# ============================================================
# OpenWrt HOME + IoT + Xbox — REINSTALL / RESET SCRIPT
# ============================================================
#
# Topology:
#
#   HOME
#     Network : 192.168.1.0/24
#     Router  : 192.168.1.1
#     DHCP    : 192.168.1.100 - 192.168.1.249
#     Wi-Fi   : HOME 2.4 GHz + HOME 5 GHz
#     LAN     : LAN1 + LAN2 + LAN3
#
#   IoT
#     Network : 192.168.50.0/24
#     Router  : 192.168.50.1
#     DHCP    : 192.168.50.100 - 192.168.50.249
#     Wi-Fi   : IoT 2.4 GHz
#
#   Xbox
#     Network : 192.168.51.0/24
#     Router  : 192.168.51.1
#     DHCP    : 192.168.51.100 - 192.168.51.104
#     Physical port : LAN4
#
# DNS:
#   Only 192.168.1.3 and 192.168.1.4 are advertised/allowed
#   for IoT and Xbox.
#
# IPv6:
#   Disabled on IoT and Xbox.
#
# Firewall:
#   HOME  -> Internet: allowed
#   HOME  -> IoT/Xbox: disabled by default, configurable below
#   IoT   -> Internet: allowed
#   IoT   -> HOME: blocked
#   Xbox  -> Internet: allowed
#   Xbox  -> HOME: blocked
#   IoT/Xbox -> DNS: local Pi-hole DNS1/DNS2 allowed; external DNS is redirected to DNS1
#   IoT/Xbox -> DoT/853: blocked
#   DoH/443 is NOT blocked by this script.
#
# Intended use:
#   Run after an OpenWrt reset or on a replacement router.
#
# IMPORTANT:
#   Run from HOME Wi-Fi or LAN1-LAN3.
#   LAN4 becomes Xbox-only.
#
# OpenWrt:
#   Designed for OpenWrt 25.12+ / DSA.
#
# Example:
#   chmod +x setup-router.sh
#   HOME_WIFI_KEY='...' IOT_WIFI_KEY='...' sh setup-router.sh
#
# Optional:
#   HOME_SSID_2G='HOME-2G'
#   HOME_SSID_5G='HOME-5G'
#   IOT_SSID='HOME-IOT'
#   HOME_ENCRYPTION='sae-mixed'
#   IOT_ENCRYPTION='sae-mixed'
#   HOME_RADIO_2G='radio0'
#   HOME_RADIO_5G='radio1'
#   IOT_RADIO='radio0'
#   ALLOW_HOME_TO_IOT=0
#   ALLOW_HOME_TO_XBOX=0
#
# ============================================================

set -eu

# ------------------------------------------------------------
# User settings
# ------------------------------------------------------------

HOME_SSID_2G="${HOME_SSID_2G:-HOME-2G}"
HOME_SSID_5G="${HOME_SSID_5G:-HOME-5G}"
IOT_SSID="${IOT_SSID:-HOME-IOT}"

HOME_ENCRYPTION="${HOME_ENCRYPTION:-sae-mixed}"
IOT_ENCRYPTION="${IOT_ENCRYPTION:-sae-mixed}"

HOME_KEY="${HOME_WIFI_KEY:-password-home}"
IOT_KEY="${IOT_WIFI_KEY:-password-iot}"

# Wi-Fi radio overrides.
# On the Dynalink DL-WRX36 these are normally:
#   radio0 = 2.4 GHz
#   radio1 = 5 GHz
HOME_RADIO_2G="${HOME_RADIO_2G:-radio0}"
HOME_RADIO_5G="${HOME_RADIO_5G:-radio1}"
IOT_RADIO="${IOT_RADIO:-$HOME_RADIO_2G}"

# Firewall policy.
ALLOW_HOME_TO_IOT="${ALLOW_HOME_TO_IOT:-0}"
ALLOW_HOME_TO_XBOX="${ALLOW_HOME_TO_XBOX:-0}"

# Physical DSA ports.
LAN_PORT_1="${LAN_PORT_1:-lan1}"
LAN_PORT_2="${LAN_PORT_2:-lan2}"
LAN_PORT_3="${LAN_PORT_3:-lan3}"
XBOX_PORT="${XBOX_PORT:-lan4}"

# Networks.
HOME_ROUTER="192.168.1.1"
HOME_NET="192.168.1.0/24"

IOT_ROUTER="192.168.50.1"
IOT_NET="192.168.50.0/24"

XBOX_ROUTER="192.168.51.1"
XBOX_NET="192.168.51.0/24"
XBOX_VLAN="21"

# Pi-hole servers.
DNS1="192.168.1.3"
DNS2="192.168.1.4"

BACKUP_DIR="/root/backup/home-iot-xbox-$(date +%Y%m%d-%H%M%S)"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

del() {
    uci -q delete "$1" || true
}

die() {
    echo ""
    echo "ERROR: $*"
    exit 1
}

valid_key() {
    key="$1"
    len="${#key}"
    [ "$len" -ge 8 ] && [ "$len" -le 63 ]
}

on_exit() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo ""
        echo "============================================================"
        echo " SCRIPT FAILED — exit code $rc"
        echo "============================================================"
        if [ -d "$BACKUP_DIR" ]; then
            echo "Backup: $BACKUP_DIR"
            echo ""
            echo "To restore the backed-up UCI files:"
            echo "  cp $BACKUP_DIR/* /etc/config/"
            echo "  reboot"
        fi
    fi
}
trap on_exit EXIT

# ------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------

echo "============================================================"
echo " OpenWrt HOME + IoT + Xbox setup"
echo "============================================================"
echo ""

command -v uci >/dev/null 2>&1 || die "uci not found."
command -v service >/dev/null 2>&1 || die "service command not found."

[ "$(id -u)" = "0" ] || die "Run as root."

for file in /etc/config/network /etc/config/wireless /etc/config/dhcp /etc/config/firewall; do
    [ -f "$file" ] || die "Missing configuration file: $file"
done

for radio in "$HOME_RADIO_2G" "$HOME_RADIO_5G" "$IOT_RADIO"; do
    uci -q get "wireless.$radio" >/dev/null || die "Wi-Fi radio '$radio' does not exist."
done

for port in "$LAN_PORT_1" "$LAN_PORT_2" "$LAN_PORT_3" "$XBOX_PORT"; do
    [ -e "/sys/class/net/$port" ] || die "DSA port '$port' was not found."
done

LAN_DEVICE="$(uci -q get network.lan.device || true)"
[ "$LAN_DEVICE" = "br-lan" ] || die \
    "Expected network.lan.device=br-lan before installation. Current: ${LAN_DEVICE:-not set}"

valid_key "$HOME_KEY" || die "HOME_WIFI_KEY must contain 8-63 characters."
valid_key "$IOT_KEY" || die "IOT_WIFI_KEY must contain 8-63 characters."

echo "HOME 2.4 GHz radio : $HOME_RADIO_2G"
echo "HOME 5 GHz radio   : $HOME_RADIO_5G"
echo "IoT radio           : $IOT_RADIO"
echo "HOME SSID 2.4 GHz  : $HOME_SSID_2G"
echo "HOME SSID 5 GHz    : $HOME_SSID_5G"
echo "IoT SSID            : $IOT_SSID"
echo "Xbox port           : $XBOX_PORT"
echo ""
echo "WARNING: LAN4/Xbox will be removed from the normal LAN."
echo "Use HOME Wi-Fi or LAN1-LAN3 for administration."
echo ""

# ------------------------------------------------------------
# Backup
# ------------------------------------------------------------

mkdir -p "$BACKUP_DIR"

cp \
    /etc/config/network \
    /etc/config/wireless \
    /etc/config/dhcp \
    /etc/config/firewall \
    "$BACKUP_DIR"/

echo "Backup saved to: $BACKUP_DIR"

# ------------------------------------------------------------
# NETWORK
# ------------------------------------------------------------

echo ""
echo "[1/5] Configuring network..."

# Remove objects managed by this script.
del network.xbox_vlan
del network.lan_vlan
del network.xbox
del network.iot_dev
del network.iot

# Normal LAN = VLAN 1 on br-lan.
uci set network.lan.device="br-lan.1"

uci set network.lan_vlan="bridge-vlan"
uci set network.lan_vlan.device="br-lan"
uci set network.lan_vlan.vlan="1"
uci add_list network.lan_vlan.ports="${LAN_PORT_1}:u*"
uci add_list network.lan_vlan.ports="${LAN_PORT_2}:u*"
uci add_list network.lan_vlan.ports="${LAN_PORT_3}:u*"

# Xbox = VLAN 21 on LAN4.
uci set network.xbox_vlan="bridge-vlan"
uci set network.xbox_vlan.device="br-lan"
uci set network.xbox_vlan.vlan="$XBOX_VLAN"
uci add_list network.xbox_vlan.ports="${XBOX_PORT}:u*"

uci set network.xbox="interface"
uci set network.xbox.proto="static"
uci set network.xbox.device="br-lan.$XBOX_VLAN"
uci set network.xbox.ipaddr="$XBOX_ROUTER/24"
uci set network.xbox.ipv6="0"

# IoT uses a dedicated bridge because it is Wi-Fi only.
uci set network.iot_dev="device"
uci set network.iot_dev.type="bridge"
uci set network.iot_dev.name="br-iot"
uci set network.iot_dev.bridge_empty="1"
uci set network.iot_dev.ipv6="0"

uci set network.iot="interface"
uci set network.iot.proto="static"
uci set network.iot.device="br-iot"
uci set network.iot.ipaddr="$IOT_ROUTER/24"
uci set network.iot.ipv6="0"

uci commit network

service network reload
sleep 4

# ------------------------------------------------------------
# WIRELESS
# ------------------------------------------------------------

echo ""
echo "[2/5] Configuring Wi-Fi..."

# Remove only Wi-Fi interfaces created by this script.
del wireless.home_2g
del wireless.home_5g
del wireless.iot

# HOME 2.4 GHz
uci set wireless.home_2g="wifi-iface"
uci set wireless.home_2g.device="$HOME_RADIO_2G"
uci set wireless.home_2g.mode="ap"
uci set wireless.home_2g.network="lan"
uci set wireless.home_2g.ssid="$HOME_SSID_2G"
uci set wireless.home_2g.encryption="$HOME_ENCRYPTION"
uci set wireless.home_2g.key="$HOME_KEY"
uci set wireless.home_2g.disabled="0"

# HOME 5 GHz
uci set wireless.home_5g="wifi-iface"
uci set wireless.home_5g.device="$HOME_RADIO_5G"
uci set wireless.home_5g.mode="ap"
uci set wireless.home_5g.network="lan"
uci set wireless.home_5g.ssid="$HOME_SSID_5G"
uci set wireless.home_5g.encryption="$HOME_ENCRYPTION"
uci set wireless.home_5g.key="$HOME_KEY"
uci set wireless.home_5g.disabled="0"

# IoT 2.4 GHz
uci set wireless.iot="wifi-iface"
uci set wireless.iot.device="$IOT_RADIO"
uci set wireless.iot.mode="ap"
uci set wireless.iot.network="iot"
uci set wireless.iot.ssid="$IOT_SSID"
uci set wireless.iot.encryption="$IOT_ENCRYPTION"
uci set wireless.iot.key="$IOT_KEY"

# Client isolation for IoT.
uci set wireless.iot.isolate="1"
uci set wireless.iot.bridge_isolate="1"
uci set wireless.iot.disabled="0"

uci commit wireless
wifi reload
sleep 3

# ------------------------------------------------------------
# DHCP
# ------------------------------------------------------------

echo ""
echo "[3/5] Configuring DHCP..."

# HOME DHCP is intentionally preserved as the main LAN DHCP,
# but its pool/options are made explicit for repeatability.
del dhcp.lan

uci set dhcp.lan="dhcp"
uci set dhcp.lan.interface="lan"
uci set dhcp.lan.dhcpv4="server"
uci set dhcp.lan.start="100"
uci set dhcp.lan.limit="150"
uci set dhcp.lan.leasetime="12h"
uci set dhcp.lan.force="1"

# HOME advertises both Pi-hole servers.
uci add_list dhcp.lan.dhcp_option="6,${DNS1},${DNS2}"

# No IPv6 DHCP/RA from the HOME dnsmasq instance.
# IPv6 on the main LAN is not forcibly disabled here because this
# script does not know whether the WAN/ISP requires IPv6.

# IoT DHCP.
del dhcp.iot

uci set dhcp.iot="dhcp"
uci set dhcp.iot.interface="iot"
uci set dhcp.iot.dhcpv4="server"
uci set dhcp.iot.start="100"
uci set dhcp.iot.limit="150"
uci set dhcp.iot.leasetime="1h"
uci set dhcp.iot.force="1"
uci add_list dhcp.iot.dhcp_option="6,${DNS1},${DNS2}"
uci set dhcp.iot.dhcpv6="disabled"
uci set dhcp.iot.ra="disabled"
uci set dhcp.iot.ndp="disabled"
uci set dhcp.iot.dns_service="0"
uci set dhcp.iot.ra_dns="0"

# Xbox DHCP.
del dhcp.xbox

uci set dhcp.xbox="dhcp"
uci set dhcp.xbox.interface="xbox"
uci set dhcp.xbox.dhcpv4="server"
uci set dhcp.xbox.start="100"
uci set dhcp.xbox.limit="5"
uci set dhcp.xbox.leasetime="12h"
uci set dhcp.xbox.force="1"
uci add_list dhcp.xbox.dhcp_option="6,${DNS1},${DNS2}"
uci set dhcp.xbox.dhcpv6="disabled"
uci set dhcp.xbox.ra="disabled"
uci set dhcp.xbox.ndp="disabled"
uci set dhcp.xbox.dns_service="0"
uci set dhcp.xbox.ra_dns="0"

uci commit dhcp

service dnsmasq restart
service odhcpd restart 2>/dev/null || true
sleep 2

# ------------------------------------------------------------
# FIREWALL
# ------------------------------------------------------------

echo ""
echo "[4/5] Configuring firewall..."

# ============================================================
# IoT zone
# ============================================================

del firewall.iot

uci set firewall.iot="zone"
uci set firewall.iot.name="iot"
uci set firewall.iot.network="iot"
uci set firewall.iot.input="REJECT"
uci set firewall.iot.output="ACCEPT"
uci set firewall.iot.forward="REJECT"

del firewall.iot_wan
uci set firewall.iot_wan="forwarding"
uci set firewall.iot_wan.src="iot"
uci set firewall.iot_wan.dest="wan"

# ============================================================
# Xbox zone
# ============================================================

del firewall.xbox

uci set firewall.xbox="zone"
uci set firewall.xbox.name="xbox"
uci set firewall.xbox.network="xbox"
uci set firewall.xbox.input="REJECT"
uci set firewall.xbox.output="ACCEPT"
uci set firewall.xbox.forward="REJECT"

del firewall.xbox_wan
uci set firewall.xbox_wan="forwarding"
uci set firewall.xbox_wan.src="xbox"
uci set firewall.xbox_wan.dest="wan"

# ============================================================
# Optional HOME -> IoT / Xbox
# ============================================================

del firewall.lan_iot
if [ "$ALLOW_HOME_TO_IOT" = "1" ]; then
    uci set firewall.lan_iot="forwarding"
    uci set firewall.lan_iot.src="lan"
    uci set firewall.lan_iot.dest="iot"
fi

del firewall.lan_xbox
if [ "$ALLOW_HOME_TO_XBOX" = "1" ]; then
    uci set firewall.lan_xbox="forwarding"
    uci set firewall.lan_xbox.src="lan"
    uci set firewall.lan_xbox.dest="xbox"
fi

# ============================================================
# DHCP rules
# ============================================================

del firewall.iot_dhcp
uci set firewall.iot_dhcp="rule"
uci set firewall.iot_dhcp.name="Allow-DHCP-IoT"
uci set firewall.iot_dhcp.src="iot"
uci set firewall.iot_dhcp.src_port="68"
uci set firewall.iot_dhcp.dest_port="67"
uci set firewall.iot_dhcp.proto="udp"
uci set firewall.iot_dhcp.family="ipv4"
uci set firewall.iot_dhcp.target="ACCEPT"

del firewall.xbox_dhcp
uci set firewall.xbox_dhcp="rule"
uci set firewall.xbox_dhcp.name="Allow-DHCP-Xbox"
uci set firewall.xbox_dhcp.src="xbox"
uci set firewall.xbox_dhcp.src_port="68"
uci set firewall.xbox_dhcp.dest_port="67"
uci set firewall.xbox_dhcp.proto="udp"
uci set firewall.xbox_dhcp.family="ipv4"
uci set firewall.xbox_dhcp.target="ACCEPT"

# ============================================================
# IPv6 protection for IoT / Xbox
# ============================================================

for section in \
    iot_block_ipv6_input \
    iot_block_ipv6_lan \
    iot_block_ipv6_wan \
    xbox_block_ipv6_input \
    xbox_block_ipv6_lan \
    xbox_block_ipv6_wan
do
    del "firewall.$section"
done

uci set firewall.iot_block_ipv6_input="rule"
uci set firewall.iot_block_ipv6_input.name="Block-IoT-IPv6-Input"
uci set firewall.iot_block_ipv6_input.src="iot"
uci set firewall.iot_block_ipv6_input.family="ipv6"
uci set firewall.iot_block_ipv6_input.proto="all"
uci set firewall.iot_block_ipv6_input.target="DROP"

uci set firewall.iot_block_ipv6_lan="rule"
uci set firewall.iot_block_ipv6_lan.name="Block-IoT-IPv6-LAN"
uci set firewall.iot_block_ipv6_lan.src="iot"
uci set firewall.iot_block_ipv6_lan.dest="lan"
uci set firewall.iot_block_ipv6_lan.family="ipv6"
uci set firewall.iot_block_ipv6_lan.proto="all"
uci set firewall.iot_block_ipv6_lan.target="DROP"

uci set firewall.iot_block_ipv6_wan="rule"
uci set firewall.iot_block_ipv6_wan.name="Block-IoT-IPv6-WAN"
uci set firewall.iot_block_ipv6_wan.src="iot"
uci set firewall.iot_block_ipv6_wan.dest="wan"
uci set firewall.iot_block_ipv6_wan.family="ipv6"
uci set firewall.iot_block_ipv6_wan.proto="all"
uci set firewall.iot_block_ipv6_wan.target="DROP"

uci set firewall.xbox_block_ipv6_input="rule"
uci set firewall.xbox_block_ipv6_input.name="Block-Xbox-IPv6-Input"
uci set firewall.xbox_block_ipv6_input.src="xbox"
uci set firewall.xbox_block_ipv6_input.family="ipv6"
uci set firewall.xbox_block_ipv6_input.proto="all"
uci set firewall.xbox_block_ipv6_input.target="DROP"

uci set firewall.xbox_block_ipv6_lan="rule"
uci set firewall.xbox_block_ipv6_lan.name="Block-Xbox-IPv6-LAN"
uci set firewall.xbox_block_ipv6_lan.src="xbox"
uci set firewall.xbox_block_ipv6_lan.dest="lan"
uci set firewall.xbox_block_ipv6_lan.family="ipv6"
uci set firewall.xbox_block_ipv6_lan.proto="all"
uci set firewall.xbox_block_ipv6_lan.target="DROP"

uci set firewall.xbox_block_ipv6_wan="rule"
uci set firewall.xbox_block_ipv6_wan.name="Block-Xbox-IPv6-WAN"
uci set firewall.xbox_block_ipv6_wan.src="xbox"
uci set firewall.xbox_block_ipv6_wan.dest="wan"
uci set firewall.xbox_block_ipv6_wan.family="ipv6"
uci set firewall.xbox_block_ipv6_wan.proto="all"
uci set firewall.xbox_block_ipv6_wan.target="DROP"

# ============================================================
# DNS / DoT policy
# ============================================================

# Generic function is not used here deliberately:
# explicit UCI sections make the resulting firewall easy to audit.

for section in \
    iot_dns1 iot_dns2 iot_block_lan_dns iot_block_dns \
    iot_redirect_dns iot_block_lan_dot iot_block_dot \
    xbox_dns1 xbox_dns2 xbox_block_lan_dns xbox_block_dns \
    xbox_redirect_dns xbox_block_lan_dot xbox_block_dot
do
    del "firewall.$section"
done

# ---- IoT DNS ----
# Allow the two local Pi-hole servers directly.
uci set firewall.iot_dns1="rule"
uci set firewall.iot_dns1.name="Allow-IoT-DNS-${DNS1}"
uci set firewall.iot_dns1.src="iot"
uci set firewall.iot_dns1.dest="lan"
uci set firewall.iot_dns1.dest_ip="$DNS1"
uci set firewall.iot_dns1.dest_port="53"
uci set firewall.iot_dns1.proto="tcp udp"
uci set firewall.iot_dns1.family="ipv4"
uci set firewall.iot_dns1.target="ACCEPT"

uci set firewall.iot_dns2="rule"
uci set firewall.iot_dns2.name="Allow-IoT-DNS-${DNS2}"
uci set firewall.iot_dns2.src="iot"
uci set firewall.iot_dns2.dest="lan"
uci set firewall.iot_dns2.dest_ip="$DNS2"
uci set firewall.iot_dns2.dest_port="53"
uci set firewall.iot_dns2.proto="tcp udp"
uci set firewall.iot_dns2.family="ipv4"
uci set firewall.iot_dns2.target="ACCEPT"

# DNS redirect is implemented by the generated nftables drop-in below.
# Do not use src_dip with multiple negated addresses: fw4/UCI rejects it.

uci set firewall.iot_block_lan_dot="rule"
uci set firewall.iot_block_lan_dot.name="Block-IoT-LAN-DNS-over-TLS"
uci set firewall.iot_block_lan_dot.src="iot"
uci set firewall.iot_block_lan_dot.dest="lan"
uci set firewall.iot_block_lan_dot.dest_port="853"
uci set firewall.iot_block_lan_dot.proto="tcp udp"
uci set firewall.iot_block_lan_dot.family="ipv4"
uci set firewall.iot_block_lan_dot.target="REJECT"

uci set firewall.iot_block_dot="rule"
uci set firewall.iot_block_dot.name="Block-IoT-External-DNS-over-TLS"
uci set firewall.iot_block_dot.src="iot"
uci set firewall.iot_block_dot.dest="wan"
uci set firewall.iot_block_dot.dest_port="853"
uci set firewall.iot_block_dot.proto="tcp udp"
uci set firewall.iot_block_dot.family="ipv4"
uci set firewall.iot_block_dot.target="REJECT"

# ---- Xbox DNS ----
# Allow the two local Pi-hole servers directly.
uci set firewall.xbox_dns1="rule"
uci set firewall.xbox_dns1.name="Allow-Xbox-DNS-${DNS1}"
uci set firewall.xbox_dns1.src="xbox"
uci set firewall.xbox_dns1.dest="lan"
uci set firewall.xbox_dns1.dest_ip="$DNS1"
uci set firewall.xbox_dns1.dest_port="53"
uci set firewall.xbox_dns1.proto="tcp udp"
uci set firewall.xbox_dns1.family="ipv4"
uci set firewall.xbox_dns1.target="ACCEPT"

uci set firewall.xbox_dns2="rule"
uci set firewall.xbox_dns2.name="Allow-Xbox-DNS-${DNS2}"
uci set firewall.xbox_dns2.src="xbox"
uci set firewall.xbox_dns2.dest="lan"
uci set firewall.xbox_dns2.dest_ip="$DNS2"
uci set firewall.xbox_dns2.dest_port="53"
uci set firewall.xbox_dns2.proto="tcp udp"
uci set firewall.xbox_dns2.family="ipv4"
uci set firewall.xbox_dns2.target="ACCEPT"

# DNS redirect is implemented by the generated nftables drop-in below.
# Do not use src_dip with multiple negated addresses: fw4/UCI rejects it.

uci set firewall.xbox_block_lan_dot="rule"
uci set firewall.xbox_block_lan_dot.name="Block-Xbox-LAN-DNS-over-TLS"
uci set firewall.xbox_block_lan_dot.src="xbox"
uci set firewall.xbox_block_lan_dot.dest="lan"
uci set firewall.xbox_block_lan_dot.dest_port="853"
uci set firewall.xbox_block_lan_dot.proto="tcp udp"
uci set firewall.xbox_block_lan_dot.family="ipv4"
uci set firewall.xbox_block_lan_dot.target="REJECT"

uci set firewall.xbox_block_dot="rule"
uci set firewall.xbox_block_dot.name="Block-Xbox-External-DNS-over-TLS"
uci set firewall.xbox_block_dot.src="xbox"
uci set firewall.xbox_block_dot.dest="wan"
uci set firewall.xbox_block_dot.dest_port="853"
uci set firewall.xbox_block_dot.proto="tcp udp"
uci set firewall.xbox_block_dot.family="ipv4"
uci set firewall.xbox_block_dot.target="REJECT"

# ============================================================
# DNS redirect nftables drop-in
# ============================================================
# fw4/UCI cannot express:
#   destination != DNS1 AND destination != DNS2
# using src_dip. Native nftables can express both exclusions.
#
# Approved Pi-hole destinations are left untouched. Every other
# IPv4 DNS query from IoT/Xbox is DNATed to DNS1.
DNS_REDIRECT_DROPIN="/etc/nftables.d/91-iot-xbox-dns-redirect.nft"
mkdir -p /etc/nftables.d

cat > "$DNS_REDIRECT_DROPIN" <<EOF
chain iot_xbox_dns_redirect {
    type nat hook prerouting priority dstnat; policy accept;
    ip saddr $IOT_NET ip daddr != $DNS1 ip daddr != $DNS2 udp dport 53 dnat ip to $DNS1:53 comment "Redirect-IoT-DNS-to-$DNS1"
    ip saddr $IOT_NET ip daddr != $DNS1 ip daddr != $DNS2 tcp dport 53 dnat ip to $DNS1:53 comment "Redirect-IoT-DNS-to-$DNS1-TCP"
    ip saddr $XBOX_NET ip daddr != $DNS1 ip daddr != $DNS2 udp dport 53 dnat ip to $DNS1:53 comment "Redirect-Xbox-DNS-to-$DNS1"
    ip saddr $XBOX_NET ip daddr != $DNS1 ip daddr != $DNS2 tcp dport 53 dnat ip to $DNS1:53 comment "Redirect-Xbox-DNS-to-$DNS1-TCP"
}
EOF

uci commit firewall

if command -v fw4 >/dev/null 2>&1; then
    fw4 check || die "fw4 validation failed. Firewall was not restarted."
fi

service firewall restart
sleep 2

# ------------------------------------------------------------
# VALIDATION
# ------------------------------------------------------------

echo ""
echo "[5/5] Validation..."
echo ""

echo "--- Interfaces ---"
ubus call network.interface.lan status || true
ubus call network.interface.iot status || true
ubus call network.interface.xbox status || true

echo ""
echo "--- VLANs ---"
uci show network.lan_vlan || true
uci show network.xbox_vlan || true

echo ""
echo "--- IP addresses ---"
ip addr show br-lan || true
ip addr show br-lan.1 || true
ip addr show br-lan.21 || true
ip addr show br-iot || true

echo ""
echo "--- DHCP ---"
uci show dhcp.lan
uci show dhcp.iot
uci show dhcp.xbox

echo ""
echo "--- DNS advertised ---"
echo "HOME:"
uci -q get dhcp.lan.dhcp_option || true
echo "IoT:"
uci -q get dhcp.iot.dhcp_option || true
echo "Xbox:"
uci -q get dhcp.xbox.dhcp_option || true

echo ""
echo "--- Wi-Fi (keys hidden) ---"
uci show wireless.home_2g | grep -v '\.key=' || true
uci show wireless.home_5g | grep -v '\.key=' || true
uci show wireless.iot | grep -v '\.key=' || true

echo ""
echo "--- Firewall ---"
uci show firewall | grep -E \
    'firewall\.(iot|xbox|lan_iot|lan_xbox|iot_wan|xbox_wan|iot_redirect_dns|xbox_redirect_dns)' || true

echo ""
echo "--- Effective DHCP ranges ---"
grep -n "dhcp-range=" /var/etc/dnsmasq.conf.* 2>/dev/null || true

echo ""
echo "--- Effective DNS options ---"
grep -n "dhcp-option=.*6," /var/etc/dnsmasq.conf.* 2>/dev/null || true

echo ""
echo "--- IPv6 IoT/Xbox ---"
echo "IoT interface:"
uci -q get network.iot.ipv6 || true
echo "IoT DHCPv6:"
uci -q get dhcp.iot.dhcpv6 || true
echo "IoT RA:"
uci -q get dhcp.iot.ra || true
echo "Xbox interface:"
uci -q get network.xbox.ipv6 || true
echo "Xbox DHCPv6:"
uci -q get dhcp.xbox.dhcpv6 || true
echo "Xbox RA:"
uci -q get dhcp.xbox.ra || true

echo ""
echo "--- DNS redirect configuration ---"
echo "Legacy UCI redirect sections (should be absent):"
uci show firewall | grep -E 'firewall\.(iot_redirect_dns|xbox_redirect_dns)' || \
    echo "  none"
echo "nftables drop-in:"
if [ -f /etc/nftables.d/91-iot-xbox-dns-redirect.nft ]; then
    sed 's/^/  /' /etc/nftables.d/91-iot-xbox-dns-redirect.nft
else
    echo "  MISSING"
fi

echo ""
echo "--- Effective DNS DNAT rules ---"
if command -v fw4 >/dev/null 2>&1; then
    fw4 print 2>/dev/null | grep -E \
        'iot_xbox_dns_redirect|Redirect-(IoT|Xbox)-DNS|dnat ip to' || true
fi
if command -v nft >/dev/null 2>&1; then
    echo "nftables DNS redirect chain:"
    nft list chain inet fw4 iot_xbox_dns_redirect 2>/dev/null || true
fi

echo ""

echo "--- VLAN firewall DNS paths ---"
for chain in forward_iot forward_xbox; do
    echo "### $chain"
    nft list chain inet fw4 "$chain" 2>/dev/null | grep -E \
        'dport 53|DNS|dport 853|DNS-over-TLS' || true
done

echo ""
echo "--- DNS redirect test procedure ---"
echo "These tests MUST be executed from a real client in each VLAN."
echo "They validate that a client with a FIXED external DNS still resolves"
echo "through the local Pi-hole instead of receiving a DNS error."
echo ""
echo "IoT client (192.168.50.x):"
echo "  nslookup openwrt.org 8.8.8.8"
echo "  nslookup openwrt.org 1.1.1.1"
echo "  nslookup openwrt.org 9.9.9.9"
echo "  nslookup openwrt.org $DNS1"
echo "  nslookup openwrt.org $DNS2"
echo ""
echo "Xbox VLAN client (192.168.51.x):"
echo "  nslookup xbox.com 8.8.8.8"
echo "  nslookup xbox.com 1.1.1.1"
echo "  nslookup xbox.com 9.9.9.9"
echo "  nslookup xbox.com $DNS1"
echo "  nslookup xbox.com $DNS2"
echo ""
echo "Expected:"
echo "  - External fixed DNS (8.8.8.8 / 1.1.1.1 / 9.9.9.9): SUCCESS"
echo "  - The query must be DNATed to DNS1."
echo "  - DNS1/DNS2: SUCCESS and remain direct (not redirected)."
echo "  - No DNS query should fail merely because the client has a fixed DNS."
echo ""
echo "Packet-level verification from the router while testing:"
echo "  tcpdump -ni br-iot 'udp port 53 or tcp port 53'"
echo "  tcpdump -ni br-lan.21 'udp port 53 or tcp port 53'"
echo ""
echo "nftables counters:"
echo "  nft list chain inet fw4 dstnat"
echo "  nft list chain inet fw4 forward_iot"
echo "  nft list chain inet fw4 forward_xbox"
echo ""
echo ""
echo "--- DNS reachability from router ---"
for dns in "$DNS1" "$DNS2"; do
    if nslookup openwrt.org "$dns" >/dev/null 2>&1; then
        echo "$dns: OK"
    else
        echo "$dns: FAILED (or nslookup unavailable)"
    fi
done

echo ""
echo "--- DSA VLAN state ---"
if command -v bridge >/dev/null 2>&1; then
    bridge vlan show || true
fi

echo ""
echo "============================================================"
echo " CONFIGURATION COMPLETE"
echo "============================================================"
echo ""
echo "HOME:"
echo "  2.4 GHz : $HOME_SSID_2G"
echo "  5 GHz   : $HOME_SSID_5G"
echo "  Network : $HOME_NET"
echo ""
echo "IoT:"
echo "  SSID    : $IOT_SSID"
echo "  Network : $IOT_NET"
echo ""
echo "Xbox:"
echo "  Port    : $XBOX_PORT"
echo "  Network : $XBOX_NET"
echo ""
echo "Pi-hole:"
echo "  $DNS1"
echo "  $DNS2"
echo ""
echo "Backup:"
echo "  $BACKUP_DIR"
echo ""
echo "IMPORTANT:"
echo "  LAN1-LAN3 = HOME"
echo "  LAN4       = Xbox"
echo "  Do not administer the router through LAN4."
echo "============================================================"
