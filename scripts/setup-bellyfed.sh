#!/usr/bin/env bash
# =============================================================================
# setup-bellyfed.sh — Provision BellyFed AI Company in Paperclip (mission-squad)
#
# Architecture (2026-04-29 redesign — Q2=A, B+C shape):
#   1 CEO (bf-lead)
# + 5 squads (launch / core / dogfood / growth / platform)
# +   each squad has 1 lead + 1-4 members
# = 19 mission agents total
#
# Each agent has: dated outcome, accountability metric, retirement trigger.
# Workflow + standup format + paperclip bridge live in
# .claude/agents/_squad-operating-manual.md (read by every agent at startup).
#
# Idempotent: finds existing company/agents and updates them, creates only
# what's missing, deactivates the 23 old domain agents (heartbeat off,
# instructions repointed to the archive dir).
#
# Usage: bash scripts/setup-bellyfed.sh [--adapter=claude|codex]
# =============================================================================
set -eo pipefail

export API="http://localhost:3100/api"
export CWD="/Volumes/SSD/GitHub/bellyfed"
export SKILLS="$CWD/.claude/skills"
AGENTS="$CWD/.claude/agents"
ARCHIVE="$CWD/.claude/agents/_archive-pre-mission-2026-04-29"

# --- Adapter selection ---
ADAPTER="claude"
for arg in "$@"; do
  case "$arg" in
    --adapter=claude) ADAPTER="claude" ;;
    --adapter=codex)  ADAPTER="codex" ;;
    --adapter=*)      echo "Error: unknown adapter '${arg#--adapter=}' (use claude or codex)"; exit 1 ;;
  esac
done

if [ "$ADAPTER" = "codex" ]; then
  export ADAPTER_TYPE="codex_local"
  export ADAPTER_MODEL="${PAPERCLIP_SECONDARY_MODEL:-gpt-5}"
  export ADAPTER_BYPASS="true"
  export ADAPTER_SKILLS_ARG=""
else
  export ADAPTER_TYPE="claude_local"
  # Default per CLAUDE.md (-10 if downgraded). Override via PAPERCLIP_PRIMARY_MODEL.
  export ADAPTER_MODEL="${PAPERCLIP_PRIMARY_MODEL:-claude-opus-4-6}"
  export ADAPTER_BYPASS="true"
  export ADAPTER_SKILLS_ARG="--add-dir"
fi

# Cross-model adapter (codex) used for platform-codex-review + platform-codex-security
export CODEX_ADAPTER="codex_local"
export CODEX_MODEL="gpt-5"

G='\033[0;32m'; C='\033[0;36m'; Y='\033[0;33m'; N='\033[0m'
log()  { echo -e "${G}[+]${N} $1"; }
info() { echo -e "${C}[i]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }

command -v jq &>/dev/null || { echo "Error: jq required"; exit 1; }
curl -sf "$API/health" >/dev/null || { echo "Error: Paperclip not running at $API"; exit 1; }
log "Paperclip server healthy"
log "Primary adapter: $ADAPTER_TYPE ($ADAPTER_MODEL); codex review: $CODEX_ADAPTER ($CODEX_MODEL)"

# ADMIN_API_KEY no longer needed (bf-redesigner retired). Kept for future agents.
ADMIN_API_KEY=""

# Build agent JSON via jq (same shape as before — adapter override args 12+13).
agent_json() {
  local max_turns="${9:-300}"
  local env_json="${11}"
  [ -z "$env_json" ] && env_json='{}'
  local eff_adapter="${12:-$ADAPTER_TYPE}"
  local eff_model="${13:-$ADAPTER_MODEL}"
  local eff_skills="$ADAPTER_SKILLS_ARG"
  if [ "$eff_adapter" = "codex_local" ]; then
    eff_skills=""
  fi
  jq -n \
    --arg name "$1" --arg role "$2" --arg title "$3" --arg icon "$4" \
    --arg reports "${5:-}" --arg instr "$6" \
    --argjson hb "$7" --arg ws "${8:-none}" \
    --argjson maxTurns "$max_turns" --arg caps "${10:-}" \
    --argjson envJson "$env_json" \
    --arg adapterType "$eff_adapter" --arg adapterModel "$eff_model" \
    --argjson adapterBypass "$ADAPTER_BYPASS" --arg adapterSkillsArg "$eff_skills" \
    --arg cwd "$CWD" --arg skills "$SKILLS" \
    '{
      name: $name, role: $role, title: $title, icon: $icon,
      adapterType: $adapterType,
      adapterConfig: ({
        cwd: $cwd, model: $adapterModel,
        instructionsFilePath: $instr,
        dangerouslySkipPermissions: $adapterBypass,
        dangerouslyBypassApprovalsAndSandbox: $adapterBypass,
        maxTurnsPerRun: $maxTurns
      }
      + if $adapterSkillsArg != "" then { extraArgs: [$adapterSkillsArg, $skills] } else {} end
      + if $ws == "worktree" then {
        workspaceStrategy: { type: "git_worktree", baseRef: "main",
          branchTemplate: ("paperclip/" + $name + "/{{issueIdentifier}}") }
      } else {} end
      + if $envJson != {} then { env: $envJson } else {} end),
      runtimeConfig: { heartbeat: { enabled: ($hb > 0), intervalSec: $hb } },
      budgetMonthlyCents: 50000,
      permissions: { canCreateAgents: false }
    } + if $reports != "" then { reportsTo: $reports } else {} end
      + if $caps != "" then { capabilities: $caps } else {} end'
}

# Upsert agent: find by name -> PATCH if exists, POST if not. Returns agent ID.
upsert_agent() {
  local json="$1" label="$2"
  local name resp id existing_id
  name=$(echo "$json" | jq -r '.name')
  existing_id=$(echo "$AGENT_LIST" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -1)
  if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
    resp=$(curl -sf "$API/agents/$existing_id" -X PATCH -H "Content-Type: application/json" \
      -d "$(echo "$json" | jq 'del(.name, .permissions)')")
    id="$existing_id"
    log "Updated $label -> ${id:0:8}..." >&2
  else
    resp=$(curl -sf "$API/companies/$CID/agents" -H "Content-Type: application/json" -d "$json")
    id=$(echo "$resp" | jq -r '.id')
    log "Created $label -> ${id:0:8}..." >&2
    AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")
  fi
  echo "$id"
}

# Deactivate a deprecated agent: heartbeat off, instructions repointed to archive.
# Doesn't delete the agent (preserves issue history). Idempotent.
deactivate_agent() {
  local name="$1"
  local existing_id
  existing_id=$(echo "$AGENT_LIST" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id' | head -1)
  if [ -z "$existing_id" ] || [ "$existing_id" = "null" ]; then
    return 0  # nothing to do
  fi
  curl -sf "$API/agents/$existing_id" -X PATCH -H "Content-Type: application/json" -d "$(jq -n \
    --arg instr "$ARCHIVE/${name}.md" \
    '{
      adapterConfig: { instructionsFilePath: $instr },
      runtimeConfig: { heartbeat: { enabled: false, intervalSec: 0 } },
      capabilities: "ARCHIVED 2026-04-29 — replaced by mission-squad agents. See _archive-pre-mission-2026-04-29/README.md"
    }')" >/dev/null
  warn "Deactivated $name -> ${existing_id:0:8}... (archived)" >&2
}

# === Company (find-or-create) ===
log "Looking up BellyFed company..."
ALL_COMPANIES=$(curl -sf "$API/companies")
CID=$(echo "$ALL_COMPANIES" | jq -r '.[] | select(.name == "BellyFed") | .id' | head -1)

if [ -n "$CID" ] && [ "$CID" != "null" ]; then
  log "Found existing BellyFed company -> ${CID:0:8}..."
  curl -sf "$API/companies/$CID" -X PATCH -H "Content-Type: application/json" -d '{
    "description": "AI-powered food discovery and travel platform. Mission-squad operating model (2026-04-29).",
    "budgetMonthlyCents": 700000
  }' >/dev/null
  PFX=$(echo "$ALL_COMPANIES" | jq -r --arg id "$CID" '.[] | select(.id == $id) | .issuePrefix')
else
  log "Creating BellyFed company..."
  CRESP=$(curl -sf "$API/companies" -H "Content-Type: application/json" -d '{
    "name": "BellyFed",
    "description": "AI-powered food discovery and travel platform. Mission-squad operating model (2026-04-29).",
    "budgetMonthlyCents": 700000
  }')
  CID=$(echo "$CRESP" | jq -r '.id')
  PFX=$(echo "$CRESP" | jq -r '.issuePrefix')
  log "Company: BellyFed ($PFX) -> ${CID:0:8}..."
fi

AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")
EXISTING_COUNT=$(echo "$AGENT_LIST" | jq 'length')
log "Existing agents: $EXISTING_COUNT (will be reconciled to 19 active + N deactivated)"

# Disable approval gate during batch operation
curl -sf "$API/companies/$CID" -X PATCH -H "Content-Type: application/json" \
  -d '{"requireBoardApprovalForNewAgents": false}' >/dev/null

# === Deactivate old domain agents (replaced by mission-squad) ===
info "Deactivating pre-mission domain agents..."
DEPRECATED=(
  bf-cto bf-cpo bf-cmo bf-cqo
  bf-trip bf-map bf-book bf-discovery bf-redesigner
  bf-researcher bf-content bf-social bf-gamification bf-monetization
  bf-auth bf-platform bf-infra bf-monitor bf-mobile
  bf-qa bf-standards
  bf-codex-reviewer bf-codex-security
)
for old in "${DEPRECATED[@]}"; do
  deactivate_agent "$old"
done
AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")  # refresh

# === CEO (bf-lead) ===
info "Registering CEO..."
CEO=$(upsert_agent "$(agent_json bf-lead ceo "BellyFed CEO — Squad Coordinator" brain "" \
  "$AGENTS/bf-lead.md" 0 none 300 \
  "ceo — coordinates 5 squads to 4 launch milestones (Wave 1 / core hardening / Europe trip / FOMO launch)")" "bf-lead (CEO)")

curl -s "$API/agents/$CEO" -X PATCH -H "Content-Type: application/json" \
  -d '{"permissions": {"canCreateAgents": true}}' >/dev/null 2>&1 || \
  info "Skipped canCreateAgents PATCH (API schema may differ)"

# Refresh agent list before squad registration
AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")

# =============================================================================
# squad-launch — Wave 1 creator-invite send (ship 2026-05-15)
# =============================================================================
info "Registering squad-launch (5 agents)..."

LAUNCH_LEAD=$(upsert_agent "$(agent_json launch-creator-tier engineer "squad-launch lead" rocket "$CEO" \
  "$AGENTS/launch-creator-tier.md" 0 worktree 300 \
  "squad:launch lead — FoundingCreator tier + vote-to-vouch + anti-fraud (ships 2026-05-13)")" "launch-creator-tier")
AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")

upsert_agent "$(agent_json launch-email-infra engineer "squad-launch member" mail "$LAUNCH_LEAD" \
  "$AGENTS/launch-email-infra.md" 0 worktree 300 \
  "squad:launch — Resend Pro + invites.bellyfed.com sending domain")" "launch-email-infra" >/dev/null

upsert_agent "$(agent_json launch-invite-crm engineer "squad-launch member" database "$LAUNCH_LEAD" \
  "$AGENTS/launch-invite-crm.md" 0 worktree 300 \
  "squad:launch — creatorInvites Firestore CRM + admin UI")" "launch-invite-crm" >/dev/null

upsert_agent "$(agent_json launch-outreach-content engineer "squad-launch member" file-code "$LAUNCH_LEAD" \
  "$AGENTS/launch-outreach-content.md" 0 none 300 \
  "squad:launch — 50 personalized creator-invite drafts (PDPA + citation-rule cleared)")" "launch-outreach-content" >/dev/null

upsert_agent "$(agent_json launch-outreach-send engineer "squad-launch member" target "$LAUNCH_LEAD" \
  "$AGENTS/launch-outreach-send.md" 0 worktree 300 \
  "squad:launch — Wave 1 send orchestration + delivery tracking")" "launch-outreach-send" >/dev/null

# =============================================================================
# squad-core — vouch + trip + discovery + onboarding loops (ship 2026-05-13)
# =============================================================================
info "Registering squad-core (4 agents)..."
AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")

CORE_LEAD=$(upsert_agent "$(agent_json core-vouch-loop engineer "squad-core lead" zap "$CEO" \
  "$AGENTS/core-vouch-loop.md" 0 worktree 300 \
  "squad:core lead — vouch loop end-to-end (count + profile + feed-post in <2s p95)")" "core-vouch-loop")
AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")

upsert_agent "$(agent_json core-trip-quality engineer "squad-core member" globe "$CORE_LEAD" \
  "$AGENTS/core-trip-quality.md" 0 worktree 300 \
  "squad:core — trip parse + generate + quality score (≥8/10 on audit set)")" "core-trip-quality" >/dev/null

upsert_agent "$(agent_json core-discovery engineer "squad-core member" search "$CORE_LEAD" \
  "$AGENTS/core-discovery.md" 0 worktree 300 \
  "squad:core — dish discovery cold-start (≥5 vouches/citations per top-city dish)")" "core-discovery" >/dev/null

upsert_agent "$(agent_json core-onboarding engineer "squad-core member" sparkles "$CORE_LEAD" \
  "$AGENTS/core-onboarding.md" 0 worktree 300 \
  "squad:core — signup → first-vouch funnel (≥60% completion)")" "core-onboarding" >/dev/null

# =============================================================================
# squad-dogfood — Sherman's Europe trip works E2E (ship 2026-06-04)
# =============================================================================
info "Registering squad-dogfood (2 agents)..."
AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")

DOGFOOD_LEAD=$(upsert_agent "$(agent_json trip-import-real engineer "squad-dogfood lead" package "$CEO" \
  "$AGENTS/trip-import-real.md" 0 worktree 300 \
  "squad:dogfood lead — Sherman's Paris→Florence→Venice→Milan import (paste-text + paste-URL)")" "trip-import-real")
AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")

upsert_agent "$(agent_json trip-render-real engineer "squad-dogfood member" globe "$DOGFOOD_LEAD" \
  "$AGENTS/trip-render-real.md" 0 worktree 300 \
  "squad:dogfood — BfMap render of Europe trip (p95 paint <1.5s, 0 console errors)")" "trip-render-real" >/dev/null

# =============================================================================
# squad-growth — Public FOMO launch surfaces (ship ~2026-05-25)
# =============================================================================
info "Registering squad-growth (3 agents)..."
AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")

GROWTH_LEAD=$(upsert_agent "$(agent_json growth-pages engineer "squad-growth lead" star "$CEO" \
  "$AGENTS/growth-pages.md" 0 worktree 300 \
  "squad:growth lead — homepage v8 + 6 city pages + 20 dish pages (Lighthouse perf ≥90)")" "growth-pages")
AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")

upsert_agent "$(agent_json growth-aeo-seo engineer "squad-growth member" search "$GROWTH_LEAD" \
  "$AGENTS/growth-aeo-seo.md" 0 worktree 300 \
  "squad:growth — llms.txt + sitemap + schema.org + GSC indexing (≥50 pages indexed)")" "growth-aeo-seo" >/dev/null

upsert_agent "$(agent_json growth-social engineer "squad-growth member" bot "$GROWTH_LEAD" \
  "$AGENTS/growth-social.md" 0 none 300 \
  "squad:growth — IG content pipeline (5 posts/week through 2026-05-31)")" "growth-social" >/dev/null

# =============================================================================
# squad-platform — Always-on guardrails (continuous)
# =============================================================================
info "Registering squad-platform (4 agents — codex adapter for review + security)..."
AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")

PLATFORM_LEAD=$(upsert_agent "$(agent_json platform-ci devops "squad-platform lead" cpu "$CEO" \
  "$AGENTS/platform-ci.md" 0 worktree 300 \
  "squad:platform lead — CI/CD + deploy gates + canary rollback (green-rate ≥95%)")" "platform-ci")
AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")

# platform-qa: heartbeat 86400 = daily QA sweep
upsert_agent "$(agent_json platform-qa qa "squad-platform member" terminal "$PLATFORM_LEAD" \
  "$AGENTS/platform-qa.md" 86400 none 300 \
  "squad:platform — daily browser QA + regression (0 P0/P1 reach Sherman first)")" "platform-qa" >/dev/null

# platform-codex-review: Codex/GPT-5.4 adapter — cross-model PR review
upsert_agent "$(agent_json platform-codex-review qa "squad-platform member (codex)" eye "$PLATFORM_LEAD" \
  "$AGENTS/platform-codex-review.md" 0 none 200 \
  "squad:platform — cross-model PR review (Codex/gpt-5) — 4h SLA, ≥60% first-pass" \
  "{}" "$CODEX_ADAPTER" "$CODEX_MODEL")" "platform-codex-review" >/dev/null

# platform-codex-security: Codex/GPT-5.4 adapter — security audit, daily
upsert_agent "$(agent_json platform-codex-security qa "squad-platform member (codex)" lock "$PLATFORM_LEAD" \
  "$AGENTS/platform-codex-security.md" 86400 none 200 \
  "squad:platform — security audit (Codex/gpt-5) — 0 OWASP P0 + creator-citation gate" \
  "{}" "$CODEX_ADAPTER" "$CODEX_MODEL")" "platform-codex-security" >/dev/null

# === Re-enable approval gate ===
curl -sf "$API/companies/$CID" -X PATCH -H "Content-Type: application/json" \
  -d '{"requireBoardApprovalForNewAgents": true}' >/dev/null
log "Board approval re-enabled"

# === Summary ===
AGENT_LIST=$(curl -sf "$API/companies/$CID/agents")
TOTAL=$(echo "$AGENT_LIST" | jq 'length')
ACTIVE=$(echo "$AGENT_LIST" | jq '[.[] | select(.runtimeConfig.heartbeat.enabled == true or .capabilities // "" | startswith("ARCHIVED") | not)] | length' 2>/dev/null || echo "n/a")

echo ""
info "===== BellyFed Mission-Squad Setup Complete ====="
info "Company:   BellyFed ($PFX) -> ${CID:0:8}..."
info "Total:     $TOTAL agents in DB ($EXISTING_COUNT before; deactivated 23 old; created/updated 19 active)"
info "Adapter:   primary=$ADAPTER_TYPE ($ADAPTER_MODEL); review/security=$CODEX_ADAPTER ($CODEX_MODEL)"
info "Dashboard: http://localhost:3100"
echo ""
info "Org Chart (mission-squad — 4 launch milestones):"
info "  bf-lead (CEO)"
info "    squad-launch (lead: launch-creator-tier) — Wave 1 send 2026-05-15"
info "      launch-email-infra · launch-invite-crm · launch-outreach-content · launch-outreach-send"
info "    squad-core (lead: core-vouch-loop) — loops hardened 2026-05-13"
info "      core-trip-quality · core-discovery · core-onboarding"
info "    squad-dogfood (lead: trip-import-real) — Europe trip 2026-06-04"
info "      trip-render-real"
info "    squad-growth (lead: growth-pages) — FOMO launch ~2026-05-25"
info "      growth-aeo-seo · growth-social"
info "    squad-platform (lead: platform-ci) — continuous"
info "      platform-qa · platform-codex-review (codex) · platform-codex-security (codex)"
echo ""
info "Heartbeats: platform-qa(daily) · platform-codex-security(daily)"
info "All other agents: issue-driven via pc_wake_agent (no heartbeat)"
echo ""
info "Pre-mission domain agents: deactivated (heartbeat off, instructions in $ARCHIVE)"
info "Their issue history is preserved in paperclip — they just won't auto-run anymore."
