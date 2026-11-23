#!/usr/bin/env bash
# fix-agent-workspace-skills.sh — make the UI agent see the seeded skills.
#
# THE BUG. `agents.list` in openclaw.json declares only the `default` agent,
# with workspace `~/.openclaw/workspace`. The gateway UI runs as agent **main**,
# which is NOT declared, so it never resolves the workspace skills directory
# and sees only the bundled skills. `agents.defaults.workspace` is already set
# to the right path but does not apply to undeclared agents.
#
# Measured on rosa-wv5l4 2026-11-23:
#   skills check --agent default  -> Visible to model: 17  (platform, quote_builder)
#   skills check --agent main     -> Visible to model: 15  (neither)
#
# The symptom reaches the user as a HALLUCINATION, which is what makes this so
# hard to diagnose. Asked for /quote_builder the model replies:
#   "I don't have access to the quote_builder skill as the required file
#    (/app/skills/quote-builder/SKILL.md) is not available"
# That path does not exist and never did — /app/skills holds the image's
# bundled skills, workspace skills live in ~/.openclaw/workspace/skills. The
# model invented a plausible path for a skill it could not see.
#
# WHY NEITHER EXISTING CHECK CATCHES IT:
#   - demo-preflight.sh tests the FILE, which is present and correct.
#   - HANDOFF.md suggests asking the agent to list its skills. That also
#     returns 15 and omits the workspace ones, so it produces a false negative
#     even on a healthy seat.
# The only reliable test is `skills check --agent <id>`, PER AGENT.
#
# Usage:
#   ./fix-agent-workspace-skills.sh 1 105     # fix a range
#   ./fix-agent-workspace-skills.sh --check 1 105

set -uo pipefail
MODE=fix; START=1; END=105
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE=check; shift ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) START="$1"; END="${2:?need an end seat}"; shift 2 ;;
  esac
done
oc whoami >/dev/null || exit 1
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; RST=$'\033[0m'

visible_for() {  # <ns> <agent> -> count
  oc exec deployment/instance -n "$1" -c gateway -- \
    node /app/dist/index.js --no-color skills check --agent "$2" 2>/dev/null \
    | sed -n 's/.*Visible to model: \([0-9]*\).*/\1/p' | head -1
}

if [[ "$MODE" == check ]]; then
  echo "── workspace skills visible to the UI agent (main) ──"
  bad=0
  for i in $(seq "$START" "$END"); do
    ns="agentic-user$i"
    oc get ns "$ns" >/dev/null 2>&1 || continue
    m=$(visible_for "$ns" main)
    d=$(visible_for "$ns" default)
    if [[ -n "$m" && -n "$d" && "$m" == "$d" ]]; then
      printf "  %-18s main=%s default=%s ${GREEN}ok${RST}\n" "$ns" "$m" "$d"
    else
      printf "  %-18s main=%s default=%s ${RED}MISMATCH${RST}\n" "$ns" "${m:-?}" "${d:-?}"
      bad=$((bad+1))
    fi
  done
  echo "  seats needing the fix: $bad"
  exit 0
fi

echo "── declaring the 'main' agent on seats $START..$END ──"
fixed=0; already=0; failed=0
for i in $(seq "$START" "$END"); do
  ns="agentic-user$i"
  oc get ns "$ns" >/dev/null 2>&1 || continue
  out=$(oc exec deployment/instance -n "$ns" -c gateway -- python3 -c "
import json
p='/home/node/.openclaw/openclaw.json'
d=json.load(open(p))
lst=d.setdefault('agents',{}).setdefault('list',[])
ws=(d.get('agents',{}).get('defaults',{}) or {}).get('workspace','~/.openclaw/workspace')
if any(a.get('id')=='main' for a in lst):
    print('ALREADY')
else:
    lst.append({'id':'main','name':'OpenClaw Assistant','workspace':ws})
    json.dump(d,open(p,'w'),indent=2)
    print('ADDED')" 2>/dev/null)
  case "$out" in
    ADDED)   fixed=$((fixed+1)) ;;
    ALREADY) already=$((already+1)) ;;
    *)       failed=$((failed+1)); echo "  ${RED}✗${RST} $ns" ;;
  esac
  printf "  [%3d/%3d]\r" "$((fixed+already+failed))" "$((END-START+1))"
done
echo
echo "  added: $fixed   already present: $already   failed: $failed"

# Agent config is read at BOOT. Without the restart the edit is inert.
echo "── restarting gateways ─────────────────────────────"
for i in $(seq "$START" "$END"); do
  oc rollout restart deployment/instance -n "agentic-user$i" >/dev/null 2>&1
done
settled=0
for i in $(seq "$START" "$END"); do
  oc rollout status deployment/instance -n "agentic-user$i" --timeout=240s >/dev/null 2>&1 \
    && settled=$((settled+1))
done
echo "  gateways settled: $settled/$((END-START+1))"
echo
echo "Verify: $0 --check $START $END"
