#!/bin/bash
# mqtt-avail-test.sh - check that Home Assistant availability is owned by
# something that stays up, not by the oneshot copy service.
#
# The bug this exists for: xpg-camera-copy@.service marked the MQTT entities
# offline from its ExecStopPost. It stops at the same instant it publishes
# "safe", so Home Assistant showed "unavailable" instead of "safe" and there was
# no way to tell that a copy had finished. No broker, no root and no card needed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$HERE/deploy/xpg-mqtt-availd"
AVAIL_UNIT="$HERE/deploy/xpg-mqtt-avail.service"
COPY_UNIT="$HERE/deploy/xpg-camera-copy@.service"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$(( pass + 1 )); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$(( fail + 1 )); }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$3], got [$2])"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# The scripts guard every publish with timeout(1), which is coreutils on the
# board but absent on macOS. Shim it so this test runs anywhere.
cat > "$TMP/bin/timeout" <<'TIMEOUT'
#!/bin/bash
shift          # drop the duration; the fakes below never hang
exec "$@"
TIMEOUT

# Fake clients that record how they were called instead of talking to a broker.
cat > "$TMP/bin/mosquitto_pub" <<'PUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CALLS"
PUB
cat > "$TMP/bin/mosquitto_sub" <<'SUB'
#!/bin/bash
printf 'sub %s\n' "$*" >> "$CALLS"
# Stay alive long enough to look like a connection, then exit non-zero so the
# daemon's restart path is not what is being tested here.
sleep 3
exit 1
SUB
chmod 755 "$TMP/bin/timeout" "$TMP/bin/mosquitto_pub" "$TMP/bin/mosquitto_sub"

echo "1. MQTT turned off is a clean no-op, not a restart loop"
CONF_OFF="$TMP/off.conf"; printf 'MQTT_ENABLED="0"\n' > "$CONF_OFF"
CALLS="$TMP/calls.off"; : > "$CALLS"
PATH="$TMP/bin:$PATH" XPG_CONF="$CONF_OFF" CALLS="$CALLS" "$DAEMON" >/dev/null 2>&1
check "exits 0 so Restart=on-failure leaves it alone" "$?" "0"
check "publishes nothing" "$(wc -l < "$CALLS" | tr -d ' ')" "0"

echo "2. It announces online, and registers a will for when it cannot"
CONF_ON="$TMP/on.conf"
cat > "$CONF_ON" <<EOF
MQTT_ENABLED="1"
MQTT_HOST="broker.invalid"
MQTT_PORT="1883"
MQTT_USER="u"
MQTT_PASS="p"
MQTT_PREFIX="testprefix"
MQTT_TIMEOUT="2"
EOF
CALLS="$TMP/calls.on"; : > "$CALLS"
PATH="$TMP/bin:$PATH" XPG_CONF="$CONF_ON" CALLS="$CALLS" MQTT_HEARTBEAT=1 \
    "$DAEMON" >/dev/null 2>&1 &
DPID=$!
# Wait for the daemon to say something rather than sleeping a fixed time: a
# loaded machine (or a slow network share) made the fixed sleep flaky.
for _ in $(seq 1 50); do
    grep -q "availability" "$CALLS" 2>/dev/null && break
    sleep 0.1
done
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
grep -q -- '-t testprefix/availability -m online' "$CALLS" \
    && ok "publishes online to <prefix>/availability" \
    || bad "did not publish online: $(tr '\n' '|' < "$CALLS")"
grep -q -- '-r' "$CALLS" && ok "retains it" || bad "online was not retained"
grep -q -- 'sub .*--will-topic testprefix/availability' "$CALLS" \
    && ok "subscribes with a will on the availability topic" \
    || bad "no will topic: $(tr '\n' '|' < "$CALLS")"
grep -q -- '--will-payload offline' "$CALLS" \
    && ok "the will says offline" || bad "will payload is not offline"
grep -q -- '--will-retain' "$CALLS" \
    && ok "the will is retained" || bad "will is not retained"

echo "3. The copy service must not touch availability"
if grep -qE '^[[:space:]]*ExecStopPost=.*xpg-mqtt-avail' "$COPY_UNIT"; then
    bad "the copy unit marks the entities offline again when it stops"
else
    ok "the copy unit leaves availability alone"
fi
grep -qE '^[[:space:]]*ExecStopPost=-/usr/local/bin/xpg-mqtt-avail offline' "$AVAIL_UNIT" \
    && ok "the availability unit announces a clean stop" \
    || bad "nothing announces a clean stop"
grep -qE '^[[:space:]]*Restart=on-failure' "$AVAIL_UNIT" \
    && ok "restarts on failure but not on the deliberate exit 0" \
    || bad "Restart is not on-failure"
if grep -qE '^[[:space:]]*RemainAfterExit' "$COPY_UNIT"; then
    bad "RemainAfterExit is back on the copy unit - one copy per boot again"
else
    ok "the copy unit still returns to inactive"
fi

echo
if (( fail == 0 )); then
    echo "  RESULT: all checks passed"
else
    echo "  RESULT: $fail check(s) failed, $pass passed"
fi
exit $(( fail > 0 ))
