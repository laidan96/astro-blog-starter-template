#!/usr/bin/env bash
# probe.sh — LAF-2249. Off-host liveness probe for lafco-global.com.
#
# Runs on GitHub Actions (off-host compute we can already push to over SSH),
# NOT on anchi. The whole point of this ticket: the on-host guard
# (lafco-site-uptime-guard.sh) dies with the box it watches, so a total power
# loss at Lao Cai reads exactly like health — last log line is a healthy tick
# and then silence. This probe survives the box.
#
# Deliberately holds NO secret. That is what keeps it viable in a public repo
# (public repos have unmetered Actions minutes) and it means we need nothing
# from the board: the dead GITHUB_PAT cannot set a repo secret anyway.
# Alerting is GitHub's native failed-workflow notification to the account owner
# — a path that does not traverse anchi.
#
# Three assertions, the same shape the on-host guard runs. A plain HTTP-200
# monitor (UptimeRobot et al) cannot do 2 and 3:
#   1. GET $BASE/vi/  -> 200            (site answering at all)
#   2. body >= MIN_BYTES                (catches a half-rsynced webroot, which
#                                        still 200s with a stub page)
#   3. GET $BASE/vi/blog/<nonexistent>/ -> 404
#                                       (identity: OUR nginx 404s. A parked
#                                        page, a wrong origin on the apex or a
#                                        catch-all answers 200 for everything,
#                                        so a 200 here means we are green on
#                                        somebody else's bytes.)
#
# State lives in a JSON file committed back to the repo. Two jobs:
#   - debounce: one flaky tick on a domestic VNPT line must not page. Alert only
#     after DOWN_THRESHOLD consecutive failed ticks.
#   - the 60-day rule: GitHub disables scheduled workflows after 60 days of
#     repository inactivity, and scheduled runs are not activity. A watchdog
#     that silently switches itself off in 60 days is the exact failure class
#     this ticket exists to fix, so every run commits.
#
# Exit codes:  0 = ok / quiet (down but already paged, inside re-page window)
#              1 = ALERT — fail the workflow run so GitHub mails the owner
#              2 = probe misconfigured (also fails the run, on purpose)
set -uo pipefail

BASE="${PROBE_BASE:-https://lafco-global.com}"
LIVE_PATH="${PROBE_LIVE_PATH:-/vi/}"
MISS_PATH="${PROBE_MISS_PATH:-/vi/blog/khong-ton-tai-abc123/}"
MIN_BYTES="${PROBE_MIN_BYTES:-20000}"
STATE="${PROBE_STATE:-state/uptime.json}"
TIMEOUT="${PROBE_TIMEOUT:-25}"
DOWN_THRESHOLD="${PROBE_DOWN_THRESHOLD:-2}"   # ticks before the first page
RE_ALERT_TICKS="${PROBE_RE_ALERT_TICKS:-8}"   # re-page cadence while still down
UA="lafco-offhost-probe/1 (+LAF-2249; github-actions)"

now_epoch="${PROBE_FAKE_NOW:-$(date -u +%s)}"
now_iso="$(date -u -d "@$now_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"

say() { printf '%s\n' "$*"; }

# --- one check, with a single retry so a lone dropped packet is not a fault ---
# echoes: "<http_code> <bytes>"
fetch() {
  local url="$1" out
  for _ in 1 2; do
    out="$(curl -sS -o /tmp/probe-body.$$ -w '%{http_code} %{size_download}' \
             --max-time "$TIMEOUT" -A "$UA" "$url" 2>/dev/null)" && {
      case "${out%% *}" in
        000) : ;;            # connection failure — retry once
        *)   printf '%s\n' "$out"; rm -f /tmp/probe-body.$$; return 0 ;;
      esac
    }
    sleep 3
  done
  rm -f /tmp/probe-body.$$
  printf '000 0\n'
}

# --- run the three assertions; sets fault= and detail= -------------------------
fault=""; detail=""
read -r live_code live_bytes <<<"$(fetch "$BASE$LIVE_PATH")"
case "$live_code" in
  200) : ;;
  000)        fault="origin_unreachable"; detail="$LIVE_PATH no response (dns/tcp/tls)" ;;
  52*|5*)     fault="origin_unreachable"; detail="$LIVE_PATH http=$live_code (Cloudflare 52x = origin down)" ;;
  *)          fault="bad_status";         detail="$LIVE_PATH http=$live_code, want 200" ;;
esac

if [ -z "$fault" ] && [ "$live_bytes" -lt "$MIN_BYTES" ]; then
  fault="body_too_small"; detail="$LIVE_PATH 200 but ${live_bytes}B < ${MIN_BYTES}B (half-deployed webroot?)"
fi

if [ -z "$fault" ]; then
  read -r miss_code _ <<<"$(fetch "$BASE$MISS_PATH")"
  case "$miss_code" in
    404) : ;;
    000|5*) fault="origin_unreachable"; detail="$MISS_PATH http=$miss_code" ;;
    *)      fault="identity_404_broken"; detail="$MISS_PATH http=$miss_code, want 404 — wrong origin or catch-all is serving the apex" ;;
  esac
fi

# --- read prior state ----------------------------------------------------------
prev_state="ok"; prev_fails=0; prev_alert_tick=0; last_ok="$now_iso"; ticks=0
if [ -r "$STATE" ]; then
  eval "$(python3 - "$STATE" <<'PY'
import json,sys,shlex
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    d={}
def g(k,dflt):
    v=d.get(k,dflt)
    return v if v is not None else dflt
print("prev_state=%s"      % shlex.quote(str(g("state","ok"))))
print("prev_fails=%s"      % int(g("consecutive_failures",0)))
print("prev_alert_tick=%s" % int(g("last_alert_tick",0)))
print("last_ok=%s"         % shlex.quote(str(g("last_ok",""))))
print("ticks=%s"           % int(g("ticks",0)))
PY
)"
fi
[ -n "$last_ok" ] || last_ok="$now_iso"
ticks=$((ticks + 1))

# --- state machine -------------------------------------------------------------
exit_code=0; verdict=""; state="ok"; fails=0; alert_tick="$prev_alert_tick"

if [ -z "$fault" ]; then
  fails=0; state="ok"; last_ok="$now_iso"; alert_tick=0
  if [ "$prev_state" = "down" ]; then
    verdict="RECOVERED — ${BASE}${LIVE_PATH} back to 200 after $prev_fails failed tick(s)"
  else
    verdict="OK — 200, ${live_bytes}B, 404-identity intact"
  fi
else
  fails=$((prev_fails + 1))
  if [ "$fails" -ge "$DOWN_THRESHOLD" ]; then
    state="down"
    if [ "$prev_state" != "down" ]; then
      verdict="DOWN — $fault: $detail (confirmed over $fails consecutive ticks)"
      alert_tick="$ticks"; exit_code=1
    elif [ $((ticks - prev_alert_tick)) -ge "$RE_ALERT_TICKS" ]; then
      verdict="STILL DOWN — $fault: $detail (last ok $last_ok)"
      alert_tick="$ticks"; exit_code=1
    else
      verdict="still down, inside re-page window — $fault: $detail"
    fi
  else
    state="ok"   # not yet confirmed; do not page on a single tick
    verdict="soft fail $fails/$DOWN_THRESHOLD — $fault: $detail (debouncing, no page)"
  fi
fi

# --- write state (always — this commit is what keeps the 60-day timer at bay) ---
# Values go through the environment, never through shell interpolation into the
# heredoc: a backtick or a $ in a fault detail would otherwise be EXECUTED.
mkdir -p "$(dirname "$STATE")"
P_TARGET="$BASE$LIVE_PATH" P_AT="$now_iso" P_TICKS="$ticks" P_STATE="$state" \
P_FAULT="${fault:-none}" P_DETAIL="$detail" P_CODE="$live_code" P_BYTES="$live_bytes" \
P_FAILS="$fails" P_ALERT="$alert_tick" P_LASTOK="$last_ok" P_VERDICT="$verdict" \
python3 - "$STATE" <<'PY'
import json,os,sys
e=os.environ
json.dump({
  "schema": 1,
  "issue": "LAF-2249",
  "target": e["P_TARGET"],
  "checked_at": e["P_AT"],
  "ticks": int(e["P_TICKS"]),
  "state": e["P_STATE"],
  "fault": e["P_FAULT"],
  "detail": e["P_DETAIL"],
  "http": {"live": e["P_CODE"], "bytes": int(e["P_BYTES"])},
  "consecutive_failures": int(e["P_FAILS"]),
  "last_alert_tick": int(e["P_ALERT"]),
  "last_ok": e["P_LASTOK"],
  "verdict": e["P_VERDICT"],
}, open(sys.argv[1],"w"), indent=2, ensure_ascii=False)
open(sys.argv[1],"a").write("\n")
PY

say "$now_iso  $verdict"
[ "$exit_code" -eq 0 ] || {
  say ""
  say "::error::lafco-global.com is DOWN — $fault"
  say "  target : $BASE$LIVE_PATH"
  say "  detail : $detail"
  say "  last ok: $last_ok"
  say ""
  say "This probe runs OFF anchi on purpose. If the site is down because the box"
  say "is off, crm./app./paperclip. are down with it and every on-host alert"
  say "channel is silent. Check power/line at Lao Cai first."
}
exit "$exit_code"
