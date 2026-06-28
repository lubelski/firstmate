#!/usr/bin/env bash
# fm-sitrep.sh - deterministic, one-shot, captain-facing fleet status roll-up.
#
# A pure READER: it never infers and never changes state. It reads the canonical
# fleet state - state/*.meta (the live worker set), bin/fm-crew-state.sh (each
# worker's current state, reused not reimplemented), data/backlog.md (In flight /
# Queued / Done), and state/.landed-log (recent landings) - and formats it into a
# single attention-first report:
#
#   FLAGGED      - needs the captain (waiting on a decision, blocked, trouble,
#                  or ready for review/merge).
#   IN FLIGHT    - workers actively running, with what each is doing.
#   ON APPROACH  - queued / blocked backlog items, with their blocker noted.
#   LANDED       - one summary line: N changes shipped in the last hour.
#
# Every FLAGGED / IN FLIGHT / ON APPROACH item gets a continuous [n] handle; the
# index map is written to state/.sitrep-index as `n<TAB>bucket<TAB>task-id` so a
# drill-in is deterministic:
#
#   fm-sitrep.sh        full roll-up (and rewrites the index)
#   fm-sitrep.sh <n>    expand item n from the last roll-up's index
#
# Output is CAPTAIN-FACING: AGENTS.md section 9 vocabulary, plain outcomes only,
# never firstmate internals (crewmate, worktree, run-step, harness names). The
# translation is baked in here, not left to the caller. The one exception is the
# raw state/<id>.status lines shown on drill-in, which are surfaced verbatim.
#
# Read-only and side-effect free apart from rewriting state/.sitrep-index on a
# full roll-up. Always exits 0 on a successful read.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

CREW_STATE="$SCRIPT_DIR/fm-crew-state.sh"
BACKLOG="$DATA/backlog.md"
INDEX="$STATE/.sitrep-index"
LANDED_LOG="$STATE/.landed-log"
LANDED_WINDOW=${FM_SITREP_LANDED_WINDOW:-3600}
case "$LANDED_WINDOW" in ''|*[!0-9]*) LANDED_WINDOW=3600 ;; esac

# --- small readers ----------------------------------------------------------

meta_value() {  # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Project display name = basename of the recorded clone path.
proj_name() {  # <meta-file>
  local p; p=$(meta_value "$1" project)
  [ -n "$p" ] || { printf 'fleet'; return; }
  printf '%s' "${p##*/}"
}

# Canonical current state of a worker, from fm-crew-state.sh (reused verbatim).
# Echoes "<state>\t<detail>".
crew_state() {  # <id>
  local line st detail rest
  line=$("$CREW_STATE" "$1" 2>/dev/null || true)
  st=${line#state: }
  st=${st%% *}
  [ -n "$st" ] || st=unknown
  # detail is whatever follows "source: <src>"; empty when there is none.
  rest=${line#*source: }
  case "$rest" in
    *" · "*) detail=${rest#* · } ;;
    *)       detail="" ;;
  esac
  printf '%s\t%s' "$st" "$detail"
}

# --- captain-facing translation (deterministic, no internals leak) ----------

# Plain outcome headline for a FLAGGED worker.
flagged_outcome() {  # <state> <has-pr> <kind> <mode>
  case "$1" in
    parked)  printf 'waiting on your decision' ;;
    blocked) printf 'blocked - needs your help' ;;
    failed)  printf 'ran into trouble' ;;
    done)
      if [ "$3" = scout ]; then printf 'findings ready for your review'
      elif [ "$4" = local-only ]; then printf 'ready for your review'
      elif [ "$2" = yes ]; then printf 'ready for your review'
      else printf 'ready for your review'
      fi
      ;;
    *)       printf 'needs your attention' ;;
  esac
}

# Plain phrase for what an IN FLIGHT worker is doing. Never echoes the raw
# crew-state detail (it carries internal vocabulary); maps it to an outcome.
inflight_doing() {  # <state> <detail> <kind>
  case "$1" in
    working)
      case "$2" in
        *ci*|*checks*) printf 'running final checks' ;;
        *)            printf 'building the change' ;;
      esac
      ;;
    *) printf 'checking in' ;;
  esac
}

# One-line next-action hint for drill-in.
next_action() {  # <state> <has-pr> <kind> <mode>
  case "$1" in
    done)
      if [ "$3" = scout ]; then printf 'findings ready - review them'
      elif [ "$4" = local-only ]; then printf 'ready to merge locally on your OK'
      elif [ "$2" = yes ]; then printf 'ready to merge on your OK'
      else printf 'ready for your review'
      fi
      ;;
    parked)  printf 'waiting on your decision to proceed' ;;
    blocked) printf 'needs your help to get unblocked' ;;
    failed)  printf 'review what went wrong' ;;
    working) printf 'in progress - no action needed' ;;
    *)       printf 'check in on it' ;;
  esac
}

# --- backlog parsing --------------------------------------------------------

# Emit queued backlog items as "id\toneliner\trepo\tblockedby_id\tblockedby_reason".
# Reads only the `## Queued` section; tolerant of the `- [ ]` and bold forms.
queued_items() {
  [ -f "$BACKLOG" ] || return 0
  awk '
    /^##[[:space:]]+Queued/      { insec=1; next }
    /^##[[:space:]]/             { insec=0 }
    insec && /^[[:space:]]*-/ {
      line=$0
      # strip leading "- [ ] " / "- [x] " / "- "
      sub(/^[[:space:]]*-[[:space:]]*(\[[ xX]\][[:space:]]*)?/, "", line)
      # strip surrounding ** from a bold id form
      gsub(/\*\*/, "", line)
      id=line
      sub(/[[:space:]].*$/, "", id)
      rest=line
      sub(/^[^[:space:]]+[[:space:]]*/, "", rest)
      sub(/^-[[:space:]]*/, "", rest)            # the " - " before the one-liner
      # repo
      repo=""
      if (match(rest, /\(repo:[[:space:]]*[^)]*\)/)) {
        repo=substr(rest, RSTART, RLENGTH)
        sub(/^\(repo:[[:space:]]*/, "", repo); sub(/\).*$/, "", repo)
        sub(/[[:space:]]*,.*$/, "", repo)
      }
      # blocked-by
      bid=""; breason=""
      if (match(rest, /blocked-by:[[:space:]]*[^[:space:]]+/)) {
        bid=substr(rest, RSTART, RLENGTH); sub(/^blocked-by:[[:space:]]*/, "", bid)
        tail=substr(rest, RSTART+RLENGTH)
        sub(/^[[:space:]]*-[[:space:]]*/, "", tail)
        breason=tail
      }
      # one-liner = rest up to the first " (repo:" or " blocked-by:"
      oneliner=rest
      sub(/[[:space:]]*\(repo:.*$/, "", oneliner)
      sub(/[[:space:]]*blocked-by:.*$/, "", oneliner)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", oneliner)
      if (id != "")
        printf "%s\t%s\t%s\t%s\t%s\n", id, oneliner, repo, bid, breason
    }
  ' "$BACKLOG"
}

# --- landed count -----------------------------------------------------------

landed_count() {
  local now cut ts rest n=0
  [ -f "$LANDED_LOG" ] || { printf '0'; return; }
  now=$(date +%s)
  cut=$((now - LANDED_WINDOW))
  while IFS=$'\t' read -r ts rest; do
    case "$ts" in ''|*[!0-9]*) continue ;; esac
    [ "$ts" -ge "$cut" ] && n=$((n + 1))
  done < "$LANDED_LOG"
  printf '%s' "$n"
}

# --- drill-in ---------------------------------------------------------------

drill_in() {  # <n>
  local n=$1 bucket id meta st detail kind mode pr haspr
  [ -f "$INDEX" ] || { echo "No roll-up index yet. Run: bin/fm-sitrep.sh"; exit 0; }
  IFS=$'\t' read -r _ bucket id < <(awk -F'\t' -v n="$n" '$1==n {print; exit}' "$INDEX")
  if [ -z "${id:-}" ]; then
    echo "No item [$n] in the current roll-up. Run bin/fm-sitrep.sh to refresh."
    exit 0
  fi

  meta="$STATE/$id.meta"
  if [ "$bucket" = approach ]; then
    # A queued backlog item has no worker yet; render from the backlog.
    local row oneliner repo bid breason
    row=$(queued_items | awk -F'\t' -v id="$id" '$1==id {print; exit}')
    IFS=$'\t' read -r _ oneliner repo bid breason <<EOF
$row
EOF
    printf 'ITEM [%s]  %s\n\n' "$n" "${repo:-fleet}"
    printf '  In the queue: %s\n' "${oneliner:-(no description)}"
    if [ -n "${bid:-}" ]; then
      printf '  Waiting on:   %s%s\n' "$bid" "${breason:+ - $breason}"
      printf '  Next:         starts once the work it depends on lands\n'
    else
      printf '  Next:         ready to start\n'
    fi
    exit 0
  fi

  # FLAGGED / IN FLIGHT item - backed by a live worker meta.
  IFS=$'\t' read -r st detail < <(crew_state "$id")
  kind=$(meta_value "$meta" kind); [ -n "$kind" ] || kind=ship
  mode=$(meta_value "$meta" mode); [ -n "$mode" ] || mode=no-mistakes
  pr=$(meta_value "$meta" pr)
  haspr=no; [ -n "$pr" ] && haspr=yes

  printf 'ITEM [%s]  %s\n\n' "$n" "$(proj_name "$meta")"
  if [ "$bucket" = flagged ]; then
    printf '  Status:  %s\n' "$(flagged_outcome "$st" "$haspr" "$kind" "$mode")"
  else
    printf '  Status:  %s\n' "$(inflight_doing "$st" "$detail" "$kind")"
  fi
  if [ -f "$BACKLOG" ]; then
    local bl
    # Match the line whose OWN leading item id equals $id (not any line that
    # merely mentions it, e.g. inside another item's blocked-by:).
    bl=$(awk -v id="$id" '
      /^[[:space:]]*-/ {
        line=$0
        sub(/^[[:space:]]*-[[:space:]]*(\[[ xX]\][[:space:]]*)?/, "", line)
        gsub(/\*\*/, "", line)
        tok=line; sub(/[[:space:]].*$/, "", tok)
        if (tok == id) { print line; exit }
      }' "$BACKLOG")
    [ -n "$bl" ] && printf '  Task:    %s\n' "$bl"
  fi
  if [ -n "$pr" ]; then
    printf '  Review:  %s\n' "$pr"
  fi
  printf '  Next:    %s\n' "$(next_action "$st" "$haspr" "$kind" "$mode")"

  # Raw recent status lines (the documented exception to the no-internals rule).
  if [ -f "$STATE/$id.status" ]; then
    local recent
    recent=$(grep -v '^[[:space:]]*$' "$STATE/$id.status" 2>/dev/null | tail -5)
    if [ -n "$recent" ]; then
      printf '\n  Recent updates:\n'
      printf '%s\n' "$recent" | while IFS= read -r l; do printf '    %s\n' "$l"; done
    fi
  fi
  exit 0
}

# --- argument handling ------------------------------------------------------

if [ "$#" -ge 1 ]; then
  case "$1" in
    ''|*[!0-9]*) echo "usage: fm-sitrep.sh [<n>]" >&2; exit 2 ;;
    *) drill_in "$1" ;;
  esac
fi

# --- full roll-up -----------------------------------------------------------

# Classify every live worker into FLAGGED or IN FLIGHT.
flagged=()   # "id\toutcome\tdetail"
inflight=()  # "id\tdoing"
if [ -d "$STATE" ]; then
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    IFS=$'\t' read -r st detail < <(crew_state "$id")
    kind=$(meta_value "$meta" kind); [ -n "$kind" ] || kind=ship
    mode=$(meta_value "$meta" mode); [ -n "$mode" ] || mode=no-mistakes
    pr=$(meta_value "$meta" pr); haspr=no; [ -n "$pr" ] && haspr=yes
    name=$(proj_name "$meta")
    case "$st" in
      parked|blocked|failed|done)
        flagged+=("$id"$'\t'"$name"$'\t'"$(flagged_outcome "$st" "$haspr" "$kind" "$mode")"$'\t'"$st")
        ;;
      *)
        inflight+=("$id"$'\t'"$name"$'\t'"$(inflight_doing "$st" "$detail" "$kind")")
        ;;
    esac
  done
fi

# Collect queued backlog items for ON APPROACH.
approach=()  # "id\trepo\toneliner\tblockedby_id\tblockedby_reason"
while IFS=$'\t' read -r qid qone qrepo qbid qreason; do
  [ -n "$qid" ] || continue
  approach+=("$qid"$'\t'"${qrepo:-fleet}"$'\t'"$qone"$'\t'"$qbid"$'\t'"$qreason")
done < <(queued_items)

# Assign continuous [n] handles and (re)write the index. The handle order is
# FLAGGED, then IN FLIGHT, then ON APPROACH, matching the printed order, so a
# blocker reference [j] can point back to an already-numbered worker.
# bash 3.2 (the repo's floor) has no associative arrays, so the id->handle map
# is a newline list of "id\tn" looked up with handle_of().
handles=""
handle_of() {  # <id>  -> echoes the handle number, or empty
  printf '%s\n' "$handles" | awk -F'\t' -v id="$1" '$1==id {print $2; exit}'
}
n=0
idx_lines=""
for row in "${flagged[@]:-}"; do
  [ -n "$row" ] || continue
  id=${row%%$'\t'*}; n=$((n + 1)); handles+="$id"$'\t'"$n"$'\n'
  idx_lines+="$n"$'\t'"flagged"$'\t'"$id"$'\n'
done
for row in "${inflight[@]:-}"; do
  [ -n "$row" ] || continue
  id=${row%%$'\t'*}; n=$((n + 1)); handles+="$id"$'\t'"$n"$'\n'
  idx_lines+="$n"$'\t'"inflight"$'\t'"$id"$'\n'
done
for row in "${approach[@]:-}"; do
  [ -n "$row" ] || continue
  id=${row%%$'\t'*}; n=$((n + 1)); handles+="$id"$'\t'"$n"$'\n'
  idx_lines+="$n"$'\t'"approach"$'\t'"$id"$'\n'
done
mkdir -p "$STATE" 2>/dev/null || true
printf '%s' "$idx_lines" > "$INDEX" 2>/dev/null || true

# --- render -----------------------------------------------------------------

n_flagged=0;  for r in "${flagged[@]:-}";  do [ -n "$r" ] && n_flagged=$((n_flagged + 1));  done
n_inflight=0; for r in "${inflight[@]:-}"; do [ -n "$r" ] && n_inflight=$((n_inflight + 1)); done
n_approach=0; for r in "${approach[@]:-}"; do [ -n "$r" ] && n_approach=$((n_approach + 1)); done
landed=$(landed_count)

printf 'SITREP · %s\n' "$(date '+%Y-%m-%d %H:%M')"

if [ "$n_flagged" -eq 0 ] && [ "$n_inflight" -eq 0 ] && [ "$n_approach" -eq 0 ]; then
  printf '\nAll quiet - nothing in flight.\n'
  printf '\nLANDED - %s change%s shipped in the last hour\n' "$landed" "$([ "$landed" = 1 ] && printf '' || printf 's')"
  exit 0
fi

# Reset the handle counter for the printed [n], walking the same order as the index.
hn=0

printf '\nFLAGGED (%s)\n' "$n_flagged"
if [ "$n_flagged" -eq 0 ]; then
  printf '  none\n'
else
  for row in "${flagged[@]:-}"; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r id name outcome st <<EOF
$row
EOF
    hn=$((hn + 1))
    printf '  [%s] %s — %s\n' "$hn" "$name" "$outcome"
  done
fi

printf '\nIN FLIGHT (%s)\n' "$n_inflight"
if [ "$n_inflight" -eq 0 ]; then
  printf '  none\n'
else
  for row in "${inflight[@]:-}"; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r id name doing <<EOF
$row
EOF
    hn=$((hn + 1))
    printf '  [%s] %s — %s\n' "$hn" "$name" "$doing"
  done
fi

printf '\nON APPROACH (%s)\n' "$n_approach"
if [ "$n_approach" -eq 0 ]; then
  printf '  none\n'
else
  for row in "${approach[@]:-}"; do
    [ -n "$row" ] || continue
    IFS=$'\t' read -r id repo oneliner bid breason <<EOF
$row
EOF
    hn=$((hn + 1))
    wait_note=""
    if [ -n "$bid" ]; then
      bhandle=$(handle_of "$bid")
      if [ -n "$bhandle" ]; then
        wait_note=" · waiting on [$bhandle]"
      else
        wait_note=" · waiting on ${breason:-$bid}"
      fi
    fi
    printf '  [%s] %s — %s%s\n' "$hn" "$repo" "${oneliner:-queued}" "$wait_note"
  done
fi

printf '\nLANDED - %s change%s shipped in the last hour\n' "$landed" "$([ "$landed" = 1 ] && printf '' || printf 's')"
printf '\nDrill in: bin/fm-sitrep.sh <n>\n'
