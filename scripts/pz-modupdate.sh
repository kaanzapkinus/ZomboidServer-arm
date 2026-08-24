#!/usr/bin/env bash
#
#  pz-modupdate — workshop mod update checker/applier for the PZ ARM server.
#
#    pz-modupdate check          human-readable report; exit 10 if updates exist
#    pz-modupdate check --ids    print outdated workshop ids only
#    pz-modupdate apply [--no-restart]
#                                backup world, re-download outdated items as local
#                                mods, log to the update log, restart the server
#    pz-modupdate auto           systemd-timer entrypoint; honors pzctl.conf:
#                                  MODUPDATE_AUTO=0|1        master switch
#                                  MODUPDATE_SCHED=daily|weekly
#                                  MODUPDATE_EMPTY_MIN=60    server empty this long
#                                  MODUPDATE_BACKUP_KEEP=2   backups kept (0-3, 0=off)
#
#  Runs fine as root (systemd timer) or as the game user (via pzctl).
#  Point PZCTL_ENV at an alternate env file to drive a non-default install.
#
set -uo pipefail
ENVF="${PZCTL_ENV:-/etc/zomboid-b42.env}"; [ -f "$ENVF" ] && . "$ENVF"
. "${PZ_COMMON:-/usr/local/lib/zomboid-arm/common.sh}"
pz_load_env

STATE="$PZ_CACHEDIR/.modupdate-state"
state_get() { ini_get "$1" "$STATE"; }
state_set() { ini_set "$1" "$2" "$STATE"; fix_owner "$STATE"; }

# one line per outdated item: <wid>\t<stored>\t<live>\t<title>
# returns 75 when the Steam API could not be reached (unknown state, not "all current")
outdated_rows() {
  local -a ids=(); local wid live title row stored det
  mapfile -t ids < <(manifest_ids)
  [ ${#ids[@]} -eq 0 ] && return 0
  det="$(ws_details "${ids[@]}")" || return 75
  while IFS=$'\t' read -r wid live title; do
    [ -z "$wid" ] && continue
    row="$(manifest_row "$wid")"; [ -z "$row" ] && continue
    stored="$(printf '%s' "$row" | cut -f2)"
    if [ "$live" -gt "${stored:-0}" ] 2>/dev/null; then
      printf '%s\t%s\t%s\t%s\n' "$wid" "${stored:-0}" "$live" "$title"
    fi
  done <<< "$det"
}

fmt_t() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$1"; }

do_check() {
  local ids_only="${1:-}"
  if [ -z "$(manifest_ids)" ]; then
    [ "$ids_only" = --ids ] || echo "No tracked mods yet. Mods added through pzctl are tracked automatically; re-add an existing mod/collection URL to start tracking it."
    return 0
  fi
  local raw
  if ! raw="$(outdated_rows)"; then
    [ "$ids_only" = --ids ] || echo "Steam API unreachable — could not check for updates. Try again later."
    return 75
  fi
  local -a rows=()
  [ -n "$raw" ] && mapfile -t rows <<< "$raw"
  if [ "$ids_only" = --ids ]; then
    printf '%s\n' "${rows[@]}" 2>/dev/null | cut -f1 | grep . || true
    [ ${#rows[@]} -gt 0 ] && return 10 || return 0
  fi
  if [ ${#rows[@]} -eq 0 ]; then
    echo "All $(manifest_ids | wc -l) tracked workshop item(s) are up to date."
    return 0
  fi
  echo "Updates available for ${#rows[@]} item(s):"
  local wid stored live title
  while IFS=$'\t' read -r wid stored live title; do
    printf '  %-12s %s   (%s -> %s)\n' "$wid" "$title" "$(fmt_t "$stored")" "$(fmt_t "$live")"
  done < <(printf '%s\n' "${rows[@]}")
  return 10
}

do_apply() {
  local no_restart="${1:-}"
  # lock lives in the cachedir, NOT /tmp: Ubuntu's fs.protected_regular blocks root
  # from opening another user's files in sticky world-writable dirs, and pz-modupdate
  # legitimately runs both as root (timer) and as the game user (pzctl).
  if ! { exec 9>"$PZ_CACHEDIR/.modupdate.lock"; } 2>/dev/null; then
    echo "cannot open the update lock ($PZ_CACHEDIR/.modupdate.lock)"; return 75
  fi
  flock -n 9 || { echo "another update run is in progress; skipping."; return 75; }
  fix_owner "$PZ_CACHEDIR/.modupdate.lock"

  local raw
  if ! raw="$(outdated_rows)"; then echo "Steam API unreachable — cannot verify what needs updating."; return 75; fi
  local -a rows=()
  [ -n "$raw" ] && mapfile -t rows <<< "$raw"
  if [ ${#rows[@]} -eq 0 ]; then echo "Nothing to update."; return 0; fi

  local keep; keep="$(conf_get MODUPDATE_BACKUP_KEEP 2)"
  [[ "$keep" =~ ^[0-3]$ ]] || keep=2
  if [ "$keep" = 0 ]; then
    echo "Pre-update world backup disabled (backups kept = 0)."
  else
    echo "Backing up world before updating (${#rows[@]} item(s))..."
    backup_world "$PZ_BACKUPS/mod-update" modup >/dev/null
    rotate_backups "$PZ_BACKUPS/mod-update" modup "$keep"
  fi

  local wid stored live title err ok=0 fail=0
  while IFS=$'\t' read -r wid stored live title; do
    printf '  updating %s (%s) ... ' "$title" "$wid"
    pz_err_clear
    if install_workshop_item "$wid" >/dev/null; then
      ok=$((ok+1)); echo "ok"
      log_modupdate "updated | $wid | $title | $(fmt_t "$stored") -> $(fmt_t "$live")"
    else
      err="$(pz_err_get)"
      fail=$((fail+1)); echo "FAILED — ${err:-unknown error}"
      log_modupdate "FAILED  | $wid | $title | ${err:-download error}"
    fi
  done < <(printf '%s\n' "${rows[@]}")
  # the timer runs as root: hand everything it touched back to the game user, or
  # the next pzctl run (as that user) cannot manage those mods
  fix_owner "$PZ_MODS" "$PZ_INI" "$PZ_UPDATELOG"
  echo "Done: $ok updated, $fail failed. Log: $PZ_UPDATELOG"

  if [ "$no_restart" = --no-restart ]; then
    echo "Restart skipped (caller handles it)."
  elif ! svc_active; then
    echo "Server is stopped; updated files will load on the next start."
  else
    echo "Restarting the server to load updated mods..."
    "$PZ_BOOTRETRY"
  fi
  [ "$fail" -eq 0 ]
}

do_auto() {
  [ "$(conf_get MODUPDATE_AUTO 0)" = 1 ] || exit 0
  local now interval last pending empty_since count empty_min
  now="$(date +%s)"
  case "$(conf_get MODUPDATE_SCHED daily)" in
    weekly) interval=604800 ;;
    *)      interval=86400  ;;
  esac
  last="$(state_get LAST_CHECK)"; last="${last:-0}"

  if [ $((now - last)) -ge "$interval" ]; then
    pending="$(do_check --ids)"; rc=$?
    if [ "$rc" = 75 ]; then
      # API unreachable: do NOT burn the daily slot — retry on the next tick
      logger -t pz-modupdate "steam api unreachable during scheduled check; retrying next tick"
    else
      pending="$(printf '%s' "$pending" | tr '\n' ' ')"
      state_set LAST_CHECK "$now"
      state_set PENDING "${pending% }"
      if [ -n "${pending% }" ]; then
        logger -t pz-modupdate "check: updates pending for: ${pending% }"
        log_modupdate "check   | updates detected, waiting for an empty server"
      fi
    fi
  fi

  pending="$(state_get PENDING)"
  [ -z "$pending" ] && exit 0

  if ! svc_active; then
    logger -t pz-modupdate "server stopped; applying mod updates now"
    if do_apply --no-restart; then
      state_set PENDING ""; state_set EMPTY_SINCE ""
    fi                       # busy/failed -> keep PENDING, retry next tick
    exit 0
  fi

  count="$(player_count)"
  if [ "$count" = -1 ]; then
    logger -t pz-modupdate "cannot read player count (RCON off/unreachable); postponing mod updates"
    exit 0
  elif [ "$count" -gt 0 ]; then
    state_set EMPTY_SINCE ""
    exit 0
  fi

  empty_since="$(state_get EMPTY_SINCE)"
  if [ -z "$empty_since" ]; then
    state_set EMPTY_SINCE "$now"
    exit 0
  fi
  empty_min="$(conf_get MODUPDATE_EMPTY_MIN 60)"
  [[ "$empty_min" =~ ^[0-9]+$ ]] || empty_min=60
  if [ $((now - empty_since)) -ge $((empty_min * 60)) ]; then
    logger -t pz-modupdate "server empty for ${empty_min}m; applying mod updates"
    if do_apply; then
      state_set PENDING ""; state_set EMPTY_SINCE ""
    fi                       # busy/failed -> keep PENDING, retry next tick
  fi
}

case "${1:-}" in
  check) do_check "${2:-}" ;;
  apply) do_apply "${2:-}" ;;
  auto)  do_auto ;;
  *) sed -n '2,18p' "$0" | sed 's/^#//;s/^ //'; exit 1 ;;
esac
