#!/usr/bin/env bash
#
#  common.sh — shared library for pzctl and pz-modupdate.
#  Installed at __LIBDIR__/common.sh; sourced, never executed.
#
#  Everything resolves from the env file written by install.sh (default
#  /etc/zomboid-b42.env, overridable with PZCTL_ENV=<path>), so the same code
#  drives any number of side-by-side installs (production, test, ...).

# DepotDownloader is a .NET app; without this it needs libicu, which minimal
# server images don't ship. Exported once here so every call site inherits it.
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

# ------------------------------------------------------------ env / paths
pz_load_env() {
  local envfile="${PZCTL_ENV:-/etc/zomboid-b42.env}"
  [ -f "$envfile" ] && . "$envfile"
  PZ_SERVICE="${PZ_SERVICE:-zomboid-b42}"
  PZ_USER="${PZ_USER:-ubuntu}"
  PZ_HOME="$(getent passwd "$PZ_USER" | cut -d: -f6)"
  PZ_INSTALL="${PZ_INSTALL:-/opt/zomboid-server}"
  PZ_CACHEDIR="${PZ_CACHEDIR:-$PZ_HOME/Zomboid}"
  PZ_INI="${PZ_INI:-$PZ_CACHEDIR/Server/servertest.ini}"
  PZ_CONSOLE="${PZ_CONSOLE:-$PZ_CACHEDIR/server-console.txt}"
  PZ_MODS="${PZ_MODS:-$PZ_CACHEDIR/mods}"
  PZ_DD="${PZ_DD:-/opt/depotdownloader/DepotDownloader}"
  PZ_PORT="${PZ_PORT:-16261}"
  PZ_RCONPORT="${PZ_RCONPORT:-27015}"
  PZ_BRANCH="${PZ_BRANCH:-public}"
  PZ_SERVERNAME="${PZ_SERVERNAME:-servertest}"
  PZ_JSON="$PZ_INSTALL/ProjectZomboid64.json"
  PZ_WS="$PZ_INSTALL/steamapps/workshop/content/108600"
  PZ_CONF="${PZ_CONF:-$PZ_CACHEDIR/pzctl.conf}"
  PZ_MANIFEST="$PZ_MODS/.workshop-manifest.tsv"
  PZ_DISABLED="$PZ_MODS/.disabled-mods"
  PZ_UPDATELOG="${PZ_UPDATELOG:-$PZ_CACHEDIR/mod-updates.log}"
  PZ_DDLOG="${PZ_DDLOG:-$PZ_CACHEDIR/depotdownloader.log}"
  PZ_BACKUPS="${PZ_BACKUPS:-$PZ_HOME/pz_backups}"
  PZ_RCON="${PZ_RCON:-/usr/local/lib/zomboid-arm/pz-rcon.py}"
  PZ_BOOTRETRY="${PZ_BOOTRETRY:-/usr/local/sbin/pz-boot-retry}"
  PZ_BASEMAP="${PZ_BASEMAP:-Muldraugh, KY}"
  # install_workshop_item usually runs inside $( ), where a plain variable would
  # not survive the subshell, so failure reasons travel through a file
  PZ_ERRFILE="${PZ_ERRFILE:-${TMPDIR:-/tmp}/.pzctl-err.$$}"
  # keys that identify THIS host/world; import must never take these from a foreign ini
  PZ_INI_PRESERVE=" DefaultPort UDPPort RCONPort RCONPassword Password PublicName SteamPort1 SteamPort2 WorkshopItems Mods Map ServerPlayerID ResetID Seed SteamVAC server_browser_announced_ip "
  export PZ_SERVICE PZ_CONSOLE PZ_PORT
}

# ------------------------------------------------------------ small utils
bold() { printf '\033[1m%s\033[0m' "$*"; }
grn()  { printf '\033[1;32m%s\033[0m' "$*"; }
red()  { printf '\033[1;31m%s\033[0m' "$*"; }
ylw()  { printf '\033[1;33m%s\033[0m' "$*"; }

as_user() {
  if [ "$(id -u)" -eq 0 ]; then
    sudo -u "$PZ_USER" env HOME="$PZ_HOME" DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 "$@"
  else
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 "$@"
  fi
}
fix_owner()    { [ "$(id -u)" -eq 0 ] && chown -R "$PZ_USER":"$PZ_USER" "$@" 2>/dev/null || true; }
is_listening() { sudo ss -uln 2>/dev/null | grep -qE ":$PZ_PORT\b"; }
svc_active()   { [ "$(sudo systemctl is-active "$PZ_SERVICE" 2>/dev/null)" = active ]; }

pz_err()       { PZ_LAST_ERR="$1"; printf '%s\n' "$1" > "${PZ_ERRFILE:-/dev/null}" 2>/dev/null; return 0; }
pz_err_clear() { PZ_LAST_ERR=""; : > "${PZ_ERRFILE:-/dev/null}" 2>/dev/null; return 0; }
pz_err_get()   { local e; e="$(cat "${PZ_ERRFILE:-/dev/null}" 2>/dev/null)"; printf '%s' "${e:-${PZ_LAST_ERR:-}}"; }

# Hand a path back to the game user. The mod-update timer runs as root, so
# anything it copied is root-owned; a later pzctl run as the normal user then
# cannot delete or overwrite those files. Cheap check first (stops at the first
# foreign file), recursive chown only when something is actually wrong.
ensure_owned() {
  local p="$1"
  [ -e "$p" ] || return 0
  [ -z "$(find "$p" -maxdepth 4 ! -user "$PZ_USER" -print -quit 2>/dev/null)" ] && return 0
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "$PZ_USER":"$PZ_USER" "$p" 2>/dev/null && return 0
  fi
  sudo -n chown -R "$PZ_USER":"$PZ_USER" "$p" 2>/dev/null && return 0
  return 1
}

# Is the configured DepotDownloader actually runnable? PZ_DD may be a binary or
# "dotnet /path/DepotDownloader.dll"; a broken value makes every download fail
# with no explanation, which is worth catching up front.
dd_ready() {
  [ -n "${PZ_DD:-}" ] || return 1
  case "$PZ_DD" in
    "dotnet "*) command -v dotnet >/dev/null 2>&1 && [ -f "${PZ_DD#dotnet }" ] ;;
    *)          [ -x "${PZ_DD%% *}" ] ;;
  esac
}

# ------------------------------------------------------------ ini / conf editing
# awk with values passed through the environment: immune to sed/awk escaping issues
# no matter what characters a password or server name contains.
ini_get() { grep -m1 "^$1=" "${2:-$PZ_INI}" 2>/dev/null | cut -d= -f2- | tr -d '\r'; }
ini_set() {  # ini_set KEY VALUE [FILE]
  local f="${3:-$PZ_INI}"
  [ -f "$f" ] || touch "$f"
  K="$1" V="$2" awk '
    BEGIN { k=ENVIRON["K"]; v=ENVIRON["V"]; done=0 }
    index($0, k"=")==1 { print k"="v; done=1; next }
    { print }
    END { if (!done) print k"="v }
  ' "$f" > "$f.pztmp" || { rm -f "$f.pztmp"; return 1; }
  # keep the original owner/mode: rewriting as root would otherwise hand the
  # file to root and lock the game user out of its own config
  chmod --reference="$f" "$f.pztmp" 2>/dev/null || true
  chown --reference="$f" "$f.pztmp" 2>/dev/null || true
  mv "$f.pztmp" "$f"
}
conf_get() {  # conf_get KEY DEFAULT
  local v; v="$(ini_get "$1" "$PZ_CONF")"
  printf '%s' "${v:-$2}"
}
conf_set() { ini_set "$1" "$2" "$PZ_CONF"; fix_owner "$PZ_CONF"; }

# Mods= helpers -------------------------------------------------------------
mods_get() { ini_get Mods; }
mods_set() { ini_set Mods "$1"; fix_owner "$PZ_INI"; }
mods_has() { printf ';%s;' "$(mods_get)" | grep -qF ";$1;"; }
mods_append() { local cur; cur="$(mods_get)"; mods_has "$1" || mods_set "${cur:+$cur;}$1"; }
mod_disabled() { [ -f "$PZ_DISABLED" ] && grep -qxF "$1" "$PZ_DISABLED"; }
# every mod id present on disk (one line each), regardless of active/disabled
disk_mod_ids() {
  find "$PZ_MODS" -maxdepth 3 -name mod.info -exec grep -h '^id=' {} + 2>/dev/null \
    | cut -d= -f2- | tr -d '\r' | sort -u
}

# Map= helpers ---------------------------------------------------------------
# B42 map mods ship their cells under <Mod>/media/maps/<Name>, <Mod>/42/media/maps/<Name>
# or <Mod>/common/media/maps/<Name>. A map only loads when <Name> is listed in Map=,
# custom maps first and the base map last. pzctl keeps Map= in sync automatically.
map_get() { ini_get Map; }
map_set() { ini_set Map "$1"; fix_owner "$PZ_INI"; }

# "<modid>\t<mapname>" for every map folder shipped by installed mods
mods_map_table() {
  local top info id d
  for top in "$PZ_MODS"/*/; do
    [ -d "$top" ] || continue
    info="$(find "${top%/}" -maxdepth 2 -name mod.info 2>/dev/null | head -1)"
    id="$(grep -m1 '^id=' "$info" 2>/dev/null | cut -d= -f2- | tr -d '\r')"
    [ -z "$id" ] && continue
    while IFS= read -r d; do
      printf '%s\t%s\n' "$id" "$(basename "$d")"
    done < <(find "${top%/}" -maxdepth 4 -type d -path '*media/maps/*' -prune 2>/dev/null)
  done
}

# map folders provided by ACTIVE mods, in Mods= load order (deduped)
maps_available_for_active() {
  local tbl mid
  tbl="$(mods_map_table)"
  [ -z "$tbl" ] && return 0
  local IFS=';'
  for mid in $(mods_get); do
    unset IFS
    [ -n "$mid" ] && printf '%s\n' "$tbl" | awk -F'\t' -v id="$mid" '$1==id{print $2}'
    IFS=';'
  done | awk 'NF && !s[$0]++'
}

# append any active-mod maps missing from Map= (kept before the base map);
# echoes how many were added
maps_append_missing() {
  local cur added=0 m
  cur="$(map_get)"; [ -z "$cur" ] && cur="$PZ_BASEMAP"
  printf ';%s;' "$cur" | grep -qF ";$PZ_BASEMAP;" || cur="$cur;$PZ_BASEMAP"
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    [ "$m" = "$PZ_BASEMAP" ] && continue
    printf ';%s;' "$cur" | grep -qF ";$m;" && continue
    if [ "$cur" = "$PZ_BASEMAP" ]; then cur="$m;$PZ_BASEMAP"
    else cur="${cur%;$PZ_BASEMAP};$m;$PZ_BASEMAP"; fi
    added=$((added+1))
  done < <(maps_available_for_active)
  [ "$added" -gt 0 ] && map_set "$cur"
  echo "$added"
}

# rebuild Map= purely from active mods (load order), base map last; echoes the line
maps_rebuild() {
  local line="" m
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    [ "$m" = "$PZ_BASEMAP" ] && continue
    line="${line:+$line;}$m"
  done < <(maps_available_for_active)
  line="${line:+$line;}$PZ_BASEMAP"
  map_set "$line"
  printf '%s\n' "$line"
}

# ------------------------------------------------------------ workshop helpers
extract_ws_id() { printf '%s' "$1" | grep -oE '[0-9]{6,}' | head -1; }

# If the id is a Workshop COLLECTION, echo its child mod ids; otherwise echo the id.
# Scrapes the page (works for public AND unlisted collections; the API 404s on unlisted).
resolve_ws_ids() {
  local id="$1" tmp; tmp="$(mktemp)"
  curl -s --max-time 25 -A 'Mozilla/5.0' "https://steamcommunity.com/sharedfiles/filedetails/?id=$id" -o "$tmp" 2>/dev/null
  if grep -q 'class="collectionItem"' "$tmp" 2>/dev/null; then
    grep -oE 'sharedfile_[0-9]+' "$tmp" | grep -oE '[0-9]+' | sort -u | grep -v "^${id}$"
  else
    printf '%s\n' "$id"
  fi
  rm -f "$tmp"
}

# ws_details ID [ID...] — one batched call to Steam's public API.
# Echoes one line per item: <id>\t<time_updated>\t<title>   (0 + "?" when unknown)
# Returns non-zero when the API is unreachable, so callers can tell "everything
# is current" apart from "could not check".
ws_details() {
  [ $# -eq 0 ] && return 0
  local data="itemcount=$#" i=0 id out
  for id in "$@"; do data="$data&publishedfileids%5B$i%5D=$id"; i=$((i+1)); done
  out="$(curl -fs --max-time 25 -X POST -d "$data" \
    'https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/?format=json' 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | jq -r '
    (.response.publishedfiledetails // [])[] |
    [(.publishedfileid // "?"), (.time_updated // 0), ((.title // "?") | gsub("[\\t\\n\\r]"; " "))] | @tsv
  ' 2>/dev/null
}

# manifest: <workshop_id>\t<time_updated>\t<mod_id,mod_id>\t<title> ---------------
manifest_set() {  # manifest_set WID TIME MODIDS TITLE
  mkdir -p "$PZ_MODS"; [ -f "$PZ_MANIFEST" ] || touch "$PZ_MANIFEST"
  W="$1" T="$2" M="$3" N="$4" awk -F'\t' '
    BEGIN { OFS="\t"; done=0 }
    $1==ENVIRON["W"] { print ENVIRON["W"], ENVIRON["T"], ENVIRON["M"], ENVIRON["N"]; done=1; next }
    NF { print }
    END { if (!done) print ENVIRON["W"], ENVIRON["T"], ENVIRON["M"], ENVIRON["N"] }
  ' "$PZ_MANIFEST" > "$PZ_MANIFEST.pztmp" && mv "$PZ_MANIFEST.pztmp" "$PZ_MANIFEST"
  fix_owner "$PZ_MANIFEST"
}
manifest_del()  { [ -f "$PZ_MANIFEST" ] || return 0; W="$1" awk -F'\t' 'NF && $1!=ENVIRON["W"]' "$PZ_MANIFEST" > "$PZ_MANIFEST.pztmp" && mv "$PZ_MANIFEST.pztmp" "$PZ_MANIFEST"; }
# drop manifest rows whose mods are neither active (Mods=) nor parked in .disabled-mods,
# so update checks stop re-downloading items the user removed
manifest_prune() {
  [ -f "$PZ_MANIFEST" ] || return 0
  local act=";$(mods_get);"
  [ -f "$PZ_DISABLED" ] && act="$act;$(tr '\n' ';' < "$PZ_DISABLED")"
  ACT="$act" awk -F'\t' 'NF {
    n = split($3, ids, ","); keep = 0
    for (i = 1; i <= n; i++) if (ids[i] != "" && index(ENVIRON["ACT"], ";" ids[i] ";")) keep = 1
    if (keep) print
  }' "$PZ_MANIFEST" > "$PZ_MANIFEST.pztmp" && mv "$PZ_MANIFEST.pztmp" "$PZ_MANIFEST"
  fix_owner "$PZ_MANIFEST"
}
manifest_ids()  { [ -f "$PZ_MANIFEST" ] && cut -f1 "$PZ_MANIFEST" | grep -E '^[0-9]+$' || true; }
manifest_row()  { [ -f "$PZ_MANIFEST" ] && grep -m1 "^$1	" "$PZ_MANIFEST" || true; }

# Download ONE workshop item and install every mod inside it as a LOCAL mod.
# Echoes one installed mod id per line; returns non-zero if the download failed.
# Also records/updates the item in the workshop manifest (for update checking).
# Optional $2/$3 = time_updated/title already fetched by the caller (saves an API
# call per item when installing collections).
# Mods the user has disabled keep their files refreshed but are NOT re-added to
# Mods= — re-adding a collection must not undo disable choices (or duplicate the
# entry across the active and disabled lists).
install_workshop_item() {
  local wid="$1" ltime="${2:-}" ltitle="${3:-}"
  local tmp modsdir root info mid dest failed=0; local -a roots=() mids=()
  dd_ready || { pz_err "DepotDownloader is missing or misconfigured (PZ_DD='${PZ_DD:-}'). Re-run the installer."; return 1; }
  # the temp dir must belong to the game user: DepotDownloader runs as that user
  # even when this code runs as root (systemd timer), and root's mktemp -d would
  # hand it an unwritable 700 directory
  tmp="$(as_user mktemp -d)"
  [ -d "$tmp" ] || { pz_err "could not create a temp dir for the download"; return 1; }
  # keep the downloader's own words: "failed" with no reason is impossible to support
  mkdir -p "$(dirname "$PZ_DDLOG")" 2>/dev/null
  printf '\n=== %s  item %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$wid" >> "$PZ_DDLOG" 2>/dev/null
  if ! as_user $PZ_DD -app 108600 -pubfile "$wid" -dir "$tmp" >>"$PZ_DDLOG" 2>&1; then
    pz_err "$(grep -aiE 'error|exception|denied|refused|not found|invalid' "$PZ_DDLOG" 2>/dev/null | tail -2 | tr '\n' ' ')"
    pz_err "${PZ_LAST_ERR:-download failed; see $PZ_DDLOG}"
    rm -rf "$tmp"; ddlog_trim; return 1
  fi
  ddlog_trim
  # Each mod is an immediate subdirectory of the item's mods/ folder. Ignore nested version
  # subfolders like 42/ (B42 mods carry a mod.info there too -> would look like a separate mod).
  modsdir="$(find "$tmp" -type d -name mods | head -1)"
  if [ -n "$modsdir" ]; then
    for root in "$modsdir"/*/; do [ -d "$root" ] && roots+=("${root%/}"); done
  else
    while IFS= read -r info; do roots+=("$(dirname "$info")"); done < <(find "$tmp" -name mod.info)
  fi
  mkdir -p "$PZ_MODS"
  for root in "${roots[@]}"; do
    info="$root/mod.info"; [ -f "$info" ] || info="$(find "$root" -maxdepth 2 -name mod.info | head -1)"
    mid="$(grep -m1 '^id=' "$info" 2>/dev/null | cut -d= -f2- | tr -d '\r')"
    [ -z "$mid" ] && continue
    dest="${PZ_MODS:?}/$(basename "$root")"
    # An existing copy may be root-owned (installed by the root-run update timer)
    # while we run as the game user. Take ownership back first, and never claim
    # success when the replace actually failed.
    if [ -e "$dest" ] && ! ensure_owned "$dest"; then
      pz_err "'$dest' belongs to another user and could not be reclaimed (needs: sudo chown -R $PZ_USER: '$PZ_MODS')"
      failed=1; continue
    fi
    as_user rm -rf "$dest" 2>/dev/null || rm -rf "$dest" 2>/dev/null
    if [ -e "$dest" ]; then
      pz_err "could not remove the old copy at '$dest'"
      failed=1; continue
    fi
    if ! { as_user cp -r "$root" "$PZ_MODS/" 2>/dev/null || cp -r "$root" "$PZ_MODS/" 2>/dev/null; }; then
      pz_err "could not copy '$mid' into '$PZ_MODS' (permissions or disk space)"
      failed=1; continue
    fi
    fix_owner "$dest"
    mod_disabled "$mid" || mods_append "$mid"
    mids+=("$mid")
    printf '%s\n' "$mid"
  done
  rm -rf "$tmp"
  [ ${#mids[@]} -eq 0 ] && { pz_err "${PZ_LAST_ERR:-no mod.info found in the downloaded item}"; return 1; }
  # a partial install must not be recorded as up to date, or the broken half
  # would never be retried
  [ "$failed" = 1 ] && return 1
  # record in the manifest so pz-modupdate can watch this item for updates
  if [ -z "$ltime" ]; then
    local det
    det="$(ws_details "$wid" | head -1)"
    ltime="$(printf '%s' "$det" | cut -f2)"; ltitle="$(printf '%s' "$det" | cut -f3)"
  fi
  manifest_set "$wid" "${ltime:-0}" "$(IFS=,; echo "${mids[*]}")" "${ltitle:-?}"
  return 0
}

# ------------------------------------------------------------ RCON
rcon_ready() { [ -n "$(ini_get RCONPassword)" ]; }
rcon_cmd() {  # rcon_cmd "command with args"  -> stdout; rc!=0 on failure
  local port pw rc
  port="$(ini_get RCONPort)"; port="${port:-$PZ_RCONPORT}"
  pw="$(ini_get RCONPassword)"
  [ -z "$pw" ] && return 3
  RCON_PASSWORD="$pw" python3 "$PZ_RCON" --host 127.0.0.1 --port "$port" -- "$1" 2>/dev/null && return 0
  rc=$?
  # right after a boot the game port is up a few seconds before the RCON socket; retry once
  sleep 3
  RCON_PASSWORD="$pw" python3 "$PZ_RCON" --host 127.0.0.1 --port "$port" -- "$1" 2>/dev/null || return $rc
}
# player_count: echoes a number, or -1 when it cannot tell (RCON off/unreachable)
player_count() {
  local out n
  out="$(rcon_cmd players)" || { echo -1; return; }
  n="$(printf '%s\n' "$out" | grep -oE 'Players connected \(([0-9]+)\)' | grep -oE '[0-9]+' | head -1)"
  [ -n "$n" ] && echo "$n" || echo -1
}

# ------------------------------------------------------------ backups + update log
backup_world() {  # backup_world DESTDIR PREFIX  -> echoes archive path
  local dir="$1" prefix="$2" ts out srv="${PZ_INI%/*}" sav="$PZ_CACHEDIR/Saves" dbd="$PZ_CACHEDIR/db"
  local -a paths=()
  ts="$(date +%Y%m%d_%H%M%S)"; mkdir -p "$dir"
  out="$dir/${prefix}_$ts.tar.gz"
  # tar from / so this works no matter where the cachedir lives; each part is
  # only listed when it exists (a fresh server has no Saves/ or db/ yet).
  # db/ holds the player accounts — a restore without it loses every character.
  [ -d "$srv" ] && paths+=("${srv#/}")
  [ -d "$sav" ] && paths+=("${sav#/}")
  [ -d "$dbd" ] && paths+=("${dbd#/}")
  [ ${#paths[@]} -eq 0 ] && { echo ""; return 1; }
  as_user tar czf "$out" -C / "${paths[@]}" 2>/dev/null
  fix_owner "$dir"
  echo "$out"
}
rotate_backups() {  # rotate_backups DIR PREFIX KEEP
  local n=0 f
  while IFS= read -r f; do
    n=$((n+1)); [ "$n" -gt "$3" ] && rm -f "$f"
  done < <(ls -1t "$1/$2"_*.tar.gz 2>/dev/null)
}
# every archive we know about, newest first: <path>\t<kind>
backup_list() {
  { ls -1t "$PZ_BACKUPS"/pzbackup_*.tar.gz 2>/dev/null | sed 's/$/\tmanual/'
    ls -1t "$PZ_BACKUPS"/prereset_*.tar.gz 2>/dev/null | sed 's/$/\tpre-reset/'
    ls -1t "$PZ_BACKUPS"/prerestore_*.tar.gz 2>/dev/null | sed 's/$/\tpre-restore/'
    ls -1t "$PZ_BACKUPS"/mod-update/modup_*.tar.gz 2>/dev/null | sed 's/$/\tmod-update/'
  } 2>/dev/null | grep . || true
}
# Restore an archive over the live data dir. Handles both layouts we have shipped:
# paths rooted at / (current) and paths relative to the home dir (first release).
backup_restore() {  # backup_restore ARCHIVE  -> 0 on success
  local f="$1" first rel_root rel_home
  [ -f "$f" ] || return 1
  first="$(as_user tar tzf "$f" 2>/dev/null | head -1)"
  [ -n "$first" ] || return 1
  first="${first#./}"; first="${first#/}"
  # Compare against this install's own paths instead of guessing from the first
  # path component: the data dir does not have to live under /home.
  rel_root="${PZ_CACHEDIR#/}"            # e.g. home/ubuntu/Zomboid
  rel_home="${PZ_CACHEDIR#"$PZ_HOME"/}"  # e.g. Zomboid  (first release layout)
  case "$first" in
    "$rel_root"/*) as_user tar xzf "$f" -C / 2>/dev/null || return 1 ;;
    "$rel_home"/*) as_user tar xzf "$f" -C "$PZ_HOME" 2>/dev/null || return 1 ;;
    *) return 1 ;;                       # archive from a different install
  esac
  fix_owner "$PZ_CACHEDIR"
  return 0
}
ddlog_trim() {  # keep the downloader log from growing forever
  [ -f "$PZ_DDLOG" ] || return 0
  if [ "$(wc -l < "$PZ_DDLOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -n 1000 "$PZ_DDLOG" > "$PZ_DDLOG.pztmp" 2>/dev/null && mv "$PZ_DDLOG.pztmp" "$PZ_DDLOG"
  fi
  fix_owner "$PZ_DDLOG"
}
log_modupdate() {  # log_modupdate "message"  (capped at 1000 entries)
  printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M')" "$1" >> "$PZ_UPDATELOG"
  if [ "$(wc -l < "$PZ_UPDATELOG" 2>/dev/null || echo 0)" -gt 1000 ]; then
    tail -n 1000 "$PZ_UPDATELOG" > "$PZ_UPDATELOG.pztmp" && mv "$PZ_UPDATELOG.pztmp" "$PZ_UPDATELOG"
  fi
  fix_owner "$PZ_UPDATELOG"
}
