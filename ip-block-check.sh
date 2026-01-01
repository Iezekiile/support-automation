#!/bin/bash

read -rp "Enter IP address: " IP

echo "========================================"
echo "IP check started for: $IP"
echo "========================================"
echo

#################################
# CSF
#################################
echo "== CSF =="

CSF_OUTPUT=$(csf -g "$IP" 2>/dev/null)

if echo "$CSF_OUTPUT" | grep -qi "No matches found"; then
    echo "CSF: no records found"
else
    echo "$CSF_OUTPUT"
    echo

    if echo "$CSF_OUTPUT" | grep -qi "TEMP"; then
        echo "CSF: temporary block detected"
        echo "Temporary unblock command:"
        echo "csf -tr $IP"
    fi

    if echo "$CSF_OUTPUT" | grep -qi "DENY"; then
        echo
        echo "CSF: permanent DENY detected"
        echo "Unblock command:"
        echo "csf -dr $IP"
    fi

    if echo "$CSF_OUTPUT" | grep -qi "ALLOW"; then
        echo
        echo "CSF: ALLOW record exists"
        echo "Remove ALLOW command:"
        echo "csf -ar $IP"
    fi
fi

echo
#################################
# LFD
#################################
echo "== LFD =="

LFD_LOG="/var/log/lfd.log"

if [[ -f "$LFD_LOG" ]]; then
    LFD_MATCHES=$(grep "$IP" "$LFD_LOG")
    if [[ -n "$LFD_MATCHES" ]]; then
        echo "LFD entries found:"
        echo
        echo "$LFD_MATCHES"
    else
        echo "LFD: no entries found for this IP"
    fi
else
    echo "LFD log not found: $LFD_LOG"
fi

echo
#################################
# ModSecurity
#################################
echo "== ModSecurity =="

MODSEC_LOG="/usr/local/apache/logs/modsec_audit.log"

if [[ -f "$MODSEC_LOG" ]]; then
    MODSEC_MATCHES=$(grep "$IP" "$MODSEC_LOG")
    if [[ -n "$MODSEC_MATCHES" ]]; then
        echo "ModSecurity block detected. Log entries:"
        echo
        echo "$MODSEC_MATCHES"
        echo
        echo "Whitelist configuration file:"
        echo "/etc/apache2/conf.d/modsec/modsec2.wordpress.conf"
        echo
        echo "Configuration check:"
        echo "httpd -t"
        echo
        echo "Reload commands:"
        echo "Apache:"
        echo "systemctl reload httpd"
        echo
        echo "LiteSpeed:"
        echo "/usr/local/lsws/bin/lswsctrl restart"
    else
        echo "ModSecurity: no blocking entries found"
    fi
else
    echo "ModSecurity log not found: $MODSEC_LOG"
fi

echo
#################################
# CrowdSec
#################################
echo "== CrowdSec =="

if command -v cscli >/dev/null 2>&1; then
    CROWD_DECISION=$(cscli decisions list --all | grep "$IP")

    if [[ -n "$CROWD_DECISION" ]]; then
        echo "CrowdSec decision found:"
        echo
        echo "$CROWD_DECISION"
        echo
        ALERT_ID=$(echo "$CROWD_DECISION" | awk '{print $1}')
        if [[ -n "$ALERT_ID" ]]; then
            echo
            echo "Alert details:"
            cscli alerts inspect -d "$ALERT_ID"
        fi
        echo
        echo "CrowdSec helper commands:"
        echo "Unblock IP:"
        echo "cscli decisions delete -i $IP"
        echo
        echo "Add IP to allowlist:"
        echo "cscli allowlists add clients $IP"
    else
        echo "CrowdSec: no blocks found for this IP"
    fi
else
    echo "CrowdSec is not installed"
fi

echo
#################################
# cPHulk
#################################
echo "== cPHulk =="

CPHULK_LOG="/usr/local/cpanel/logs/cphulkd.log"

if [[ -f "$CPHULK_LOG" ]]; then
    CPHULK_MATCHES=$(grep "$IP" "$CPHULK_LOG")
    if [[ -n "$CPHULK_MATCHES" ]]; then
        echo "cPHulk block detected. Log entries:"
        echo
        echo "$CPHULK_MATCHES"
        echo
        echo "Unblock command:"
        echo "/scripts/hulk-unban-ip $IP"
    else
        echo "cPHulk: no blocking entries found"
    fi
else
    echo "cPHulk log not found: $CPHULK_LOG"
fi

echo
echo "========================================"
echo "IP check finished"
echo "========================================"
