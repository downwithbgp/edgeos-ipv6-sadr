#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Shared, framed identity acquisition and parsing for the production ER-X.
#
# The remote response is a versioned frame:
#   __SADR_ID_BEGIN__ 1
#   version=...
#   kernel=...
#   model=...
#   mac=...
#   __SADR_ID_END__ 1
#
# Output outside the frame (EdgeOS login banner, motd, warnings) is ignored.
# Exactly one complete frame with exactly the four fields is required.
# The caller must check the SSH exit status independently; acquire does.

# shellcheck disable=SC2016 # the remote command must expand on the target
SADR_IDENTITY_REMOTE='printf "__SADR_ID_BEGIN__ 1\n"; printf "version=%s\n" "$(cat /etc/version)"; printf "kernel=%s\n" "$(uname -r)"; printf "model=%s\n" "$(cat /proc/device-tree/model)"; printf "mac=%s\n" "$(cat /sys/class/net/eth0/address)"; printf "__SADR_ID_END__ 1\n"'

sadr_identity_trim() { # stdout/var helper: trim leading and trailing whitespace
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

sadr_identity_parse() { # stdin -> SADR_ID_*; nonzero on any malformed response
    local line key val in_frame=0 begin=0 end=0 v=0 k=0 m=0 c=0
    SADR_ID_VERSION=""; SADR_ID_KERNEL=""; SADR_ID_MODEL=""; SADR_ID_MAC=""
    SADR_ID_FINGERPRINT=""
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        line=$(sadr_identity_trim "$line")
        case "$line" in
            "__SADR_ID_BEGIN__ 1")
                if [ "$begin" -ne 0 ] || [ "$end" -ne 0 ]; then return 4; fi
                begin=1; in_frame=1; continue
                ;;
            "__SADR_ID_END__ 1")
                if [ "$begin" -ne 1 ] || [ "$end" -ne 0 ]; then return 4; fi
                end=1; in_frame=0; continue
                ;;
        esac
        if [ "$in_frame" -ne 1 ] || [ -z "$line" ]; then continue; fi
        case "$line" in
            *=*) ;;
            *) return 3 ;;
        esac
        key=${line%%=*}
        val=${line#*=}
        case "$key" in
            version) [ "$v" -eq 0 ] || return 2; SADR_ID_VERSION=$val; v=1 ;;
            kernel) [ "$k" -eq 0 ] || return 2; SADR_ID_KERNEL=$val; k=1 ;;
            model) [ "$m" -eq 0 ] || return 2; SADR_ID_MODEL=$val; m=1 ;;
            mac) [ "$c" -eq 0 ] || return 2; SADR_ID_MAC=$val; c=1 ;;
            *) return 3 ;;
        esac
    done
    [ "$begin" -eq 1 ] && [ "$end" -eq 1 ] || return 4
    [ "$v" -eq 1 ] && [ "$k" -eq 1 ] && [ "$m" -eq 1 ] && [ "$c" -eq 1 ] || return 5
    [ -n "$SADR_ID_VERSION" ] && [ -n "$SADR_ID_KERNEL" ] && [ -n "$SADR_ID_MODEL" ] && [ -n "$SADR_ID_MAC" ] || return 5
    printf '%s' "$SADR_ID_MAC" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || return 6
    SADR_ID_FINGERPRINT=$(printf '%s\n%s\n' "$SADR_ID_MODEL" "$SADR_ID_MAC" | sha256sum | awk '{print $1}')
    return 0
}

sadr_identity_acquire() { # router; uses SADR_SSH_OPTS array and optional SADR_SSH_KEY
    local router=$1 out rc=0 key_args=()
    if [ -n "${SADR_SSH_KEY:-}" ]; then key_args=(-i "$SADR_SSH_KEY"); fi
    # shellcheck disable=SC2029 # the framed command is intentionally one remote command
    out=$(ssh "${SADR_SSH_OPTS[@]}" "${key_args[@]}" "$router" "$SADR_IDENTITY_REMOTE" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || return 1
    sadr_identity_parse <<<"$out"
}

sadr_identity_validate() { # exact_firmware kernel fingerprint device_id
    local firmware=$1 kernel=$2 fingerprint=$3 device_id=$4
    printf '%s' "$SADR_ID_VERSION" | grep -Eq '^EdgeRouter\.ER-e50\.v3\.0\.1\.5862409\.' || return 1
    if [ -n "$firmware" ] && [ "$SADR_ID_VERSION" != "$firmware" ]; then return 1; fi
    [ "$SADR_ID_KERNEL" = "$kernel" ] || return 1
    if [ -n "$fingerprint" ] && [ "$SADR_ID_FINGERPRINT" != "$fingerprint" ]; then return 1; fi
    if [ -n "$device_id" ]; then
        printf '%s\n%s\n%s\n%s\n' "$SADR_ID_VERSION" "$SADR_ID_KERNEL" "$SADR_ID_MODEL" "$SADR_ID_MAC" |
            grep -Fq -- "$device_id" || return 1
    fi
    return 0
}
