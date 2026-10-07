#!/usr/bin/env bash
# =============================================================================
# deploy.sh - zentrales Deploy-/Update-Skript                  (Kern-Version 5)
#
# Diese Datei ist in ALLEN Repos identisch. Dienstspezifisches (Hooks,
# Backup-Pfade, Smoke-Test) steht ausschliesslich in deploy.conf.sh.
# Dokumentation: DEPLOY.md
#
# Ein Aufruf entscheidet selbst, was zu tun ist:
#   1. .env fehlt            -> aus sample.env anlegen, Geheimnisse erzeugen, STOPP
#   2. .env unvollstaendig   -> offene {{CHANGEME}}-Werte auflisten, STOPP
#   3. noch nicht installiert-> Erstinstallation
#   4. sonst                 -> git pull, Images bauen/ziehen, Backup, Update
# =============================================================================
set -Eeuo pipefail

CORE_VERSION=5
ORIG_ARGS=("$@")
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$ROOT"

# --- Ausgabe -----------------------------------------------------------------
if [[ -t 1 ]]; then
  C_G=$'\033[0;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[0;31m'; C_N=$'\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_N=''
fi
info() { printf '%s\n' "${C_Y}▶ $*${C_N}"; }
ok()   { printf '%s\n' "${C_G}✅ $*${C_N}"; }
warn() { printf '%s\n' "${C_Y}⚠️  $*${C_N}" >&2; }
err()  { printf '%s\n' "${C_R}❌ $*${C_N}" >&2; }
die()  { err "$*"; exit 1; }

# --- Standardwerte (in deploy.conf.sh ueberschreibbar) -----------------------
SERVICE_NAME="$(basename "$ROOT")"
NETWORKS=(cloudflare-net)     # externe Docker-Netzwerke, werden bei Bedarf angelegt
BACKUP_PATHS=()               # Pfade relativ zum Repo, werden archiviert (.env immer)
BACKUP_VOLUMES=()             # benannte Compose-Volumes (Namen wie in compose.yaml)
BACKUP_STOP=1                 # 1 = Dienste fuer das Datei-/Volume-Backup kurz stoppen
BACKUP_IMAGE="alpine:3"       # Hilfs-Image fuer tar (kein sudo noetig)
KEEP_BACKUPS=7                # so viele Backups bleiben in ./backups
HEALTH_TIMEOUT=180            # Sekunden, bis Container gesund sein muessen
STABLE_SECS=10                # Container ohne Healthcheck: so lange muessen sie laufen
MIN_FREE_MB=2048              # Mindestens freier Platz im Repo-Verzeichnis

# Hooks: in deploy.conf.sh ueberschreiben. Rueckgabewert != 0 bricht ab.
hook_preflight() { :; }       # zusaetzliche Pruefungen vor Install/Update
hook_version()   { :; }       # gibt die laufende Dienst-Version aus (nur Anzeige)
hook_backup()    { :; }       # $1 = Backup-Verzeichnis (z. B. pg_dump, laeuft bei laufenden Diensten)
hook_restore()   { :; }       # $1 = Backup-Verzeichnis (Dienste sind gestoppt; Hook startet bei Bedarf selbst Teile)
hook_check_update() { :; }    # nach dem Bauen, vor der Rueckfrage; != 0 bricht das Update ab (z. B. Major-Sperre)
hook_post_up()   { :; }       # nach Start und Health-Check (z. B. Datenbank-Extensions aktualisieren)
hook_smoke()     { :; }       # Funktionstest nach Start

# --- Argumente ---------------------------------------------------------------
MODE=auto; YES=0; DRY=0; NOPULL=0; ADD_MISSING=0
ALLOW_MAJOR=0                 # fuer Hooks (hook_check_update)
export ALLOW_MAJOR

usage() {
  cat <<EOF
Aufruf: ./deploy.sh [Optionen]

  (ohne Option)   Erstinstallation bzw. Update, je nach Zustand
  --check         Updates pruefen (baut Images, aendert nichts; Exit 10 = Update verfuegbar)
  --status        eine Statuszeile ausgeben (fuer das Inventar)
  --backup        nur ein Backup erstellen
  --rollback      letztes Backup + vorherige Images wiederherstellen
  --adopt         bereits laufende Installation uebernehmen (nichts aendern)
  --add-missing   neue Variablen aus sample.env an .env anhaengen
  --allow-major   Major-Upgrade erlauben (sperrt ein Dienst per hook_check_update)
  --no-pull       kein git pull
  --yes, -y       Rueckfragen automatisch bestaetigen (z. B. fuer Cron)
  --dry-run       nur anzeigen, was passieren wuerde
  --help, -h      diese Hilfe
EOF
}

for arg in "$@"; do
  case "$arg" in
    --check)       MODE=check ;;
    --status)      MODE=status ;;
    --backup)      MODE=backup ;;
    --rollback)    MODE=rollback ;;
    --adopt)       MODE=adopt ;;
    --add-missing) ADD_MISSING=1 ;;
    --allow-major) ALLOW_MAJOR=1 ;;
    --no-pull)     NOPULL=1 ;;
    --yes|-y)      YES=1 ;;
    --dry-run)     DRY=1 ;;
    --help|-h)     usage; exit 0 ;;
    *)             usage >&2; die "Unbekannte Option: $arg" ;;
  esac
done

# --- Hilfsfunktionen ---------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
trap '[[ $BASH_COMMAND == return* ]] || err "Unerwarteter Fehler in Zeile $LINENO (Befehl: $BASH_COMMAND)"' ERR

run() {
  if [[ $DRY == 1 ]]; then printf '   [dry-run] %s\n' "$*"; else "$@"; fi
}
# Wie run, aber Ausgabe nur bei Fehler (BuildKit-Fortschritt ist sehr laut)
run_quiet() {
  if [[ $DRY == 1 ]]; then printf '   [dry-run] %s\n' "$*"; return 0; fi
  if ! "$@" >"$TMP/cmd.log" 2>&1; then tail -n 40 "$TMP/cmd.log" >&2; return 1; fi
}
# Wie run_quiet, wiederholt aber bei voruebergehenden Fehlern (z. B. Registry-Rate-Limit 429).
# $1 = Anzahl Versuche; Wartezeit 30 s, 60 s, ...
run_quiet_retry() {
  local n=$1 i=1; shift
  if [[ $DRY == 1 ]]; then printf '   [dry-run] %s\n' "$*"; return 0; fi
  while :; do
    if "$@" >"$TMP/cmd.log" 2>&1; then return 0; fi
    if (( i >= n )); then tail -n 40 "$TMP/cmd.log" >&2; return 1; fi
    warn "Fehlgeschlagen (Versuch $i/$n): $(grep -iE 'error|429|too many|timeout|unavailable' "$TMP/cmd.log" | tail -1 | cut -c1-160)"
    warn "Warte $(( i * 30 ))s und versuche es erneut ..."
    sleep $(( i * 30 )); i=$(( i + 1 ))
  done
}
dc() { docker compose "$@"; }

call_hook() {
  local h=$1; shift
  if [[ $DRY == 1 ]]; then printf '   [dry-run] %s %s\n' "$h" "$*"; else "$h" "$@"; fi
}

confirm() {
  [[ $YES == 1 || $DRY == 1 ]] && return 0
  [[ -t 0 ]] || die "Keine Rueckfrage moeglich (kein Terminal). Mit --yes bestaetigen."
  local a; read -r -p "$1 [j/N] " a
  [[ $a =~ ^[jJyY]$ ]]
}

state_get() { [[ -f .deploy-state ]] || return 0; grep -E "^$1=" .deploy-state | tail -1 | cut -d= -f2- || true; }
state_set() {
  [[ $DRY == 1 ]] && return 0
  touch .deploy-state
  { grep -v "^$1=" .deploy-state || true; printf '%s=%s\n' "$1" "$2"; } > .deploy-state.tmp
  mv .deploy-state.tmp .deploy-state
}

require_cmds() {
  local c
  for c in docker openssl flock sha256sum; do
    command -v "$c" >/dev/null 2>&1 || die "Benoetigtes Programm fehlt: $c"
  done
}

# --- Sperre: nie zwei Laeufe gleichzeitig ------------------------------------
acquire_lock() {
  exec 9>.deploy.lock
  flock -n 9 || die "Es laeuft bereits ein deploy.sh in diesem Verzeichnis."
}

# --- git pull (inkl. Selbst-Neustart, falls deploy.sh sich geaendert hat) ----
GIT_CHANGED="${DEPLOY_GIT_CHANGED:-0}"
git_sync() {
  [[ $NOPULL == 1 || -n ${DEPLOY_REEXEC:-} ]] && return 0
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    warn "Kein Git-Repository - git pull uebersprungen."
    return 0
  fi
  local head_before head_after self_before self_after
  head_before="$(git rev-parse HEAD)"
  self_before="$(sha256sum deploy.sh | cut -d' ' -f1)"
  info "git pull --ff-only"
  if [[ $DRY == 1 ]]; then
    printf '   [dry-run] git pull --ff-only\n'
    return 0
  fi
  git pull --ff-only || die "git pull fehlgeschlagen (lokale Aenderungen oder abweichender Stand?). Bitte manuell klaeren."
  head_after="$(git rev-parse HEAD)"
  [[ $head_before != "$head_after" ]] && GIT_CHANGED=1
  self_after="$(sha256sum deploy.sh | cut -d' ' -f1)"
  if [[ $self_before != "$self_after" ]]; then
    info "deploy.sh wurde aktualisiert - starte neu."
    DEPLOY_REEXEC=1 DEPLOY_GIT_CHANGED="$GIT_CHANGED" exec "$ROOT/deploy.sh" "${ORIG_ARGS[@]}"
  fi
}

load_conf() {
  [[ -f deploy.conf.sh ]] || die "deploy.conf.sh fehlt."
  # shellcheck disable=SC1091
  source ./deploy.conf.sh
}

# --- .env aus sample.env -----------------------------------------------------
gen_value() {
  local x
  case $1 in
    hex[0-9]*) openssl rand -hex "${1#hex}" ;;
    pw[0-9]*)
      x="$(openssl rand -base64 $(( ${1#pw} * 2 + 16 )) | tr -dc 'A-Za-z0-9')"
      printf '%s' "${x:0:${1#pw}}" ;;
    *) echo "Unbekannter Generator: $1" >&2; return 1 ;;
  esac
}

# Ersetzt {{GEN:<typ>}} (hexN = N Bytes als Hex, pwN = N Zeichen alphanumerisch)
render_sample() {
  local line val
  while IFS= read -r line || [[ -n $line ]]; do
    while [[ $line =~ \{\{GEN:([a-z0-9]+)\}\} ]]; do
      val="$(gen_value "${BASH_REMATCH[1]}")" || exit 1
      line="${line/"${BASH_REMATCH[0]}"/$val}"
    done
    printf '%s\n' "$line"
  done < "$1"
}

open_vars() {
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=.*\{\{(CHANGEME|GEN:[a-z0-9]+)\}\}' .env | cut -d= -f1 || true
}

missing_vars() {
  local key
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' sample.env | cut -d= -f1 | while read -r key; do
    grep -qE "^${key}=" .env || printf '%s\n' "$key"
  done
}

prepare_env() {
  [[ -f sample.env ]] || die "sample.env fehlt."

  if [[ ! -f .env ]]; then
    info ".env existiert nicht - lege sie aus sample.env an."
    if [[ $DRY == 1 ]]; then
      printf '   [dry-run] .env aus sample.env erzeugen (Geheimnisse generieren)\n'
      exit 0
    fi
    ( umask 077; render_sample sample.env > .env.tmp && mv .env.tmp .env )
    chmod 600 .env
    ok ".env wurde angelegt (Geheimnisse automatisch erzeugt, Rechte 600)."
    local open; open="$(open_vars)"
    if [[ -n $open ]]; then
      warn "Diese Werte musst du jetzt von Hand setzen ({{CHANGEME}}):"
      printf '%s\n' "$open" | sed 's/^/   - /'
    fi
    echo
    echo "Bitte .env pruefen/anpassen, danach ./deploy.sh erneut aufrufen."
    exit 0
  fi

  local open missing
  open="$(open_vars)"
  if [[ -n $open ]]; then
    err ".env enthaelt noch nicht gesetzte Werte:"
    printf '%s\n' "$open" | sed 's/^/   - /' >&2
    die "Bitte in .env ausfuellen und ./deploy.sh erneut aufrufen."
  fi

  missing="$(missing_vars)"
  if [[ -n $missing ]]; then
    if [[ $ADD_MISSING == 1 ]]; then
      info "Haenge neue Variablen aus sample.env an .env an:"
      printf '%s\n' "$missing" | sed 's/^/   + /'
      if [[ $DRY != 1 ]]; then
        local key
        render_sample sample.env > "$TMP/sample.rendered"
        for key in $missing; do grep -E "^${key}=" "$TMP/sample.rendered" >> .env; done
        open="$(open_vars)"
        if [[ -n $open ]]; then
          err "Neue Werte muessen von Hand gesetzt werden:"; printf '%s\n' "$open" | sed 's/^/   - /' >&2
          die "Bitte in .env ausfuellen und ./deploy.sh erneut aufrufen."
        fi
      fi
    else
      err "sample.env enthaelt Variablen, die in .env fehlen:"
      printf '%s\n' "$missing" | sed 's/^/   - /' >&2
      die "Ergaenze sie in .env oder rufe ./deploy.sh --add-missing auf."
    fi
  fi
}

# --- Docker-Vorpruefungen ----------------------------------------------------
docker_preflight() {
  docker info >/dev/null 2>&1 || die "Docker-Daemon nicht erreichbar (laeuft er? Rechte? docker-Gruppe?)."
  docker compose version >/dev/null 2>&1 || die "Docker Compose Plugin fehlt."

  local free net
  free="$(df -Pm . | awk 'NR==2 {print $4}')"
  (( free >= MIN_FREE_MB )) || die "Zu wenig freier Platz: ${free} MB (Minimum ${MIN_FREE_MB} MB)."

  for net in "${NETWORKS[@]}"; do
    if ! docker network inspect "$net" >/dev/null 2>&1; then
      info "Lege Docker-Netzwerk '$net' an."
      run docker network create "$net" >/dev/null
    fi
  done

  dc config -q || die "compose.yaml/.env fehlerhaft (docker compose config)."
  call_hook hook_preflight
}

# --- Images ------------------------------------------------------------------
# Ausgabe: "<imagename> <image-id|->" je Zeile
snapshot_images() {
  local img id
  while IFS= read -r img; do
    [[ -n $img ]] || continue
    id="$(docker image inspect --format '{{.Id}}' "$img" 2>/dev/null || true)"
    printf '%s %s\n' "$img" "${id:--}"
  done < <(dc config --images | sort -u)
}

# Wie snapshot_images, aber mit den IDs der Images, die gerade WIRKLICH laufen
# ("-" = Dienst laeuft nicht oder noch nie mit diesem Image). So bleibt ein
# abgebrochenes/abgelehntes Update beim naechsten Lauf erkennbar.
snapshot_running() {
  local running name id cid
  running="$(for cid in $(dc ps -a -q); do docker inspect -f '{{.Config.Image}} {{.Image}}' "$cid"; done)"
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    id="$(awk -v n="$name" '$1 == n { print $2; exit }' <<<"$running")"
    printf '%s %s\n' "$name" "${id:--}"
  done < <(dc config --images | sort -u)
}

image_repo() {
  local name=$1
  if [[ ${name##*/} == *:* ]]; then printf '%s' "${name%:*}"; else printf '%s' "$name"; fi
}

show_image_changes() {
  local name old new
  join <(sort "$1") <(sort "$2") | while read -r name old new; do
    [[ $old == "$new" ]] && continue
    [[ $old == "-" ]] && old="sha256:(neu)"
    printf '   %s: %s -> %s\n' "$name" "${old:7:12}" "${new:7:12}"
  done
}

# Vorherige Image-Generation als :previous markieren (Rollback + Schutz vor prune)
tag_previous() {
  local name old new
  join <(sort "$1") <(sort "$2") | while read -r name old new; do
    [[ $old == "$new" || $old == "-" ]] && continue
    run docker tag "$old" "$(image_repo "$name"):previous"
  done
}

# --- Gesundheit --------------------------------------------------------------
show_diag() {
  dc ps -a || true
  dc logs --tail 30 || true
}

wait_healthy() {
  [[ $DRY == 1 ]] && return 0
  local deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  local ids=() id name st hs code started up bad pending
  info "Warte auf Container (max. ${HEALTH_TIMEOUT}s) ..."
  while :; do
    mapfile -t ids < <(dc ps -a -q)
    (( ${#ids[@]} > 0 )) || { err "Keine Container vorhanden."; return 1; }
    bad=""; pending=0
    for id in "${ids[@]}"; do
      read -r name st hs code started < <(docker inspect -f \
        '{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.ExitCode}} {{.State.StartedAt}}' "$id")
      name="${name#/}"
      case "$st/$hs" in
        running/healthy) ;;
        running/none)
          up=$(( $(date +%s) - $(date -d "$started" +%s 2>/dev/null || echo 0) ))
          (( up >= STABLE_SECS )) || pending=1 ;;
        exited/*)
          [[ $code == 0 ]] || bad+=" ${name}(exit ${code})" ;;
        *) pending=1; PENDING_INFO="${name}(${st}/${hs})" ;;
      esac
    done
    if [[ -n $bad ]]; then
      err "Container fehlgeschlagen:${bad}"; show_diag; return 1
    fi
    if (( pending == 0 )); then ok "Alle Container laufen."; return 0; fi
    if (( SECONDS >= deadline )); then
      err "Timeout: Container nicht rechtzeitig gesund (zuletzt: ${PENDING_INFO:-?})."; show_diag; return 1
    fi
    sleep 3
  done
}

# --- Backup ------------------------------------------------------------------
BACKUP_STOPPED=0

ensure_helper_image() {
  docker image inspect "$BACKUP_IMAGE" >/dev/null 2>&1 && return 0
  info "Lade Hilfs-Image $BACKUP_IMAGE ..."
  run_quiet docker pull -q "$BACKUP_IMAGE" || return 1
}

project_name() { dc config 2>/dev/null | sed -n 's/^name: *//p' | head -1; }

# Docker-Name eines Compose-Volumes (leer, wenn es noch nicht existiert)
volume_real_name() {
  docker volume ls -q \
    --filter "label=com.docker.compose.project=$(project_name)" \
    --filter "label=com.docker.compose.volume=$1" | head -1
}

archive_paths() {
  local dir=$1 paths=(".env" "${BACKUP_PATHS[@]}") p
  for p in "${paths[@]}"; do
    [[ $DRY == 1 || -e $p ]] || die "Backup-Pfad existiert nicht: $p"
  done
  ensure_helper_image || return 1
  run docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$ROOT:/src:ro" -v "$ROOT/$dir:/out" "$BACKUP_IMAGE" \
    sh -c 'tar -czpf /out/files.tar.gz --numeric-owner -C /src "$@" && chown "$HOST_UID:$HOST_GID" /out/files.tar.gz' sh "${paths[@]}"
}

restore_paths() {
  local dir=$1
  [[ -f $dir/files.tar.gz ]] || die "$dir/files.tar.gz fehlt."
  ensure_helper_image
  run docker run --rm -v "$ROOT:/dst" -v "$ROOT/$dir:/in:ro" "$BACKUP_IMAGE" \
    sh -c 'cd /dst && { [ $# -eq 0 ] || rm -rf -- "$@"; } && tar -xzpf /in/files.tar.gz --numeric-owner -C /dst' sh "${BACKUP_PATHS[@]}"
}

archive_volumes() {
  local dir=$1 v real
  for v in "${BACKUP_VOLUMES[@]}"; do
    real="$(volume_real_name "$v")"
    if [[ -z $real ]]; then warn "Volume '$v' existiert nicht - uebersprungen."; continue; fi
    ensure_helper_image || return 1
    run docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
      -v "$real:/data:ro" -v "$ROOT/$dir:/out" "$BACKUP_IMAGE" \
      sh -c 'tar -czpf "/out/vol_$0.tar.gz" --numeric-owner -C /data . && chown "$HOST_UID:$HOST_GID" "/out/vol_$0.tar.gz"' "$v" || return 1
  done
}

restore_volumes() {
  local dir=$1 v real
  for v in "${BACKUP_VOLUMES[@]}"; do
    [[ -f $dir/vol_$v.tar.gz ]] || { warn "$dir/vol_$v.tar.gz fehlt - uebersprungen."; continue; }
    real="$(volume_real_name "$v")"
    [[ -n $real ]] || die "Volume '$v' existiert nicht (Rollback nicht moeglich)."
    ensure_helper_image
    run docker run --rm -v "$real:/data" -v "$ROOT/$dir:/in:ro" "$BACKUP_IMAGE" \
      sh -c 'rm -rf /data/..?* /data/.[!.]* /data/* && tar -xzpf "/in/vol_$0.tar.gz" --numeric-owner -C /data' "$v"
  done
}

rotate_backups() {
  local dirs=() n i
  [[ -d backups ]] || return 0
  mapfile -t dirs < <(find backups -mindepth 1 -maxdepth 1 -type d | sort)
  n=$(( ${#dirs[@]} - KEEP_BACKUPS ))
  (( n > 0 )) || return 0
  for (( i = 0; i < n; i++ )); do run rm -rf -- "${dirs[i]}"; done
}

latest_backup() {
  [[ -d backups ]] || return 0
  find backups -mindepth 1 -maxdepth 1 -type d | sort | tail -1
}

# $1 = Datei mit Image-Snapshot (fuer Rollback)
# Hinweis: Wird in 'if !' aufgerufen, dort ist 'set -e' unwirksam -> jeder Schritt prueft selbst.
do_backup() {
  BACKUP_DIR="backups/$(date +%Y%m%d_%H%M%S)"
  info "Backup nach $BACKUP_DIR"
  run mkdir -p "$BACKUP_DIR" || return 1
  run chmod 700 backups "$BACKUP_DIR" || return 1
  if [[ $DRY != 1 ]]; then cp "$1" "$BACKUP_DIR/images.txt" || return 1; fi
  call_hook hook_backup "$BACKUP_DIR" || return 1
  if (( ${#BACKUP_PATHS[@]} + ${#BACKUP_VOLUMES[@]} > 0 )) && [[ $BACKUP_STOP == 1 ]]; then
    info "Stoppe Dienste fuer ein konsistentes Datei-Backup ..."
    BACKUP_STOPPED=1
    run dc stop || return 1
  fi
  archive_paths "$BACKUP_DIR" || return 1
  archive_volumes "$BACKUP_DIR" || return 1
  if [[ $DRY != 1 && ! -s $BACKUP_DIR/files.tar.gz ]]; then
    err "Backup-Archiv fehlt oder ist leer: $BACKUP_DIR/files.tar.gz"
    return 1
  fi
  state_set LAST_BACKUP "$BACKUP_DIR"
  ok "Backup fertig: $BACKUP_DIR"
  rotate_backups
}

# --- Befehle -----------------------------------------------------------------
cmd_install() {
  if [[ -n "$(dc ps -a -q)" ]]; then
    warn "Fuer dieses Projekt laufen bereits Container, aber deploy.sh kennt die Installation noch nicht."
    confirm "Laufende Installation uebernehmen und anschliessend aktualisieren?" || die "Abgebrochen."
    cmd_adopt
    cmd_update
    return 0
  fi
  info "Erstinstallation: $SERVICE_NAME"
  info "Lade/baue Images ..."
  run_quiet_retry 3 dc pull --ignore-buildable || die "Images konnten nicht geladen werden. Es wurde nichts veraendert."
  run_quiet_retry 3 dc build --pull || die "Images konnten nicht gebaut werden (Registry erreichbar? Rate-Limit?). Es wurde nichts veraendert."
  run dc up -d
  wait_healthy || die "Erstinstallation nicht gesund - siehe Ausgabe oben."
  call_hook hook_post_up || die "hook_post_up fehlgeschlagen."
  call_hook hook_smoke || die "Smoke-Test fehlgeschlagen."
  state_set INSTALLED_AT "$(date -Is)"
  state_set LAST_UPDATE "$(date -Is)"
  state_set CORE_VERSION "$CORE_VERSION"
  ok "$SERVICE_NAME ist installiert. Version: $(hook_version 2>/dev/null || echo unbekannt)"
}

cmd_update() {
  info "Update: $SERVICE_NAME"
  local ver_before ver_after
  ver_before="$(hook_version 2>/dev/null || true)"
  snapshot_running > "$TMP/before"

  info "Lade/baue Images ..."
  run_quiet_retry 3 dc pull --ignore-buildable || die "Images konnten nicht geladen werden. Laufende Dienste sind unveraendert."
  run_quiet_retry 3 dc build --pull || die "Images konnten nicht gebaut werden (Registry erreichbar? Rate-Limit?). Laufende Dienste sind unveraendert - spaeter erneut versuchen."
  snapshot_images > "$TMP/after"

  if [[ $DRY != 1 ]] && cmp -s "$TMP/before" "$TMP/after" && [[ $GIT_CHANGED == 0 ]]; then
    ok "Keine neuen Images und keine Konfigurationsaenderung - nichts zu tun."
    wait_healthy || die "Dienste sind nicht gesund (siehe oben)."
    state_set LAST_CHECK "$(date -Is)"
    return 0
  fi

  echo "Version vorher : ${ver_before:-unbekannt}"
  echo "Image-Aenderungen:"
  show_image_changes "$TMP/before" "$TMP/after"
  [[ $GIT_CHANGED == 1 ]] && echo "   (Konfiguration per git pull geaendert)"
  call_hook hook_check_update || die "Update abgebrochen (hook_check_update). Siehe Meldung oben."
  if [[ $MODE == check ]]; then
    warn "UPDATE VERFUEGBAR (nur Pruefung - es wurde nichts veraendert)."
    exit 10
  fi
  confirm "Update durchfuehren? Es wird vorher ein Backup erstellt." || die "Abgebrochen."

  tag_previous "$TMP/before" "$TMP/after"
  if ! do_backup "$TMP/before"; then
    err "Backup fehlgeschlagen - Update abgebrochen."
    [[ $BACKUP_STOPPED == 1 ]] && { warn "Starte die Dienste wieder ..."; dc start || true; }
    exit 1
  fi

  info "Starte Dienste mit neuen Images ..."
  run dc up -d --remove-orphans
  if ! wait_healthy || ! call_hook hook_post_up || ! call_hook hook_smoke; then
    err "Update fehlgeschlagen. Backup: $BACKUP_DIR"
    err "Zurueck zum alten Stand: ./deploy.sh --rollback"
    exit 1
  fi

  ver_after="$(hook_version 2>/dev/null || true)"
  state_set LAST_UPDATE "$(date -Is)"
  run docker image prune -f >/dev/null
  ok "Update abgeschlossen. Version: ${ver_before:-?} -> ${ver_after:-?}"
}

cmd_backup() {
  [[ -f .deploy-state ]] || warn "Noch nicht installiert/uebernommen (.deploy-state fehlt)."
  snapshot_running > "$TMP/before"
  if (( ${#BACKUP_PATHS[@]} + ${#BACKUP_VOLUMES[@]} > 0 )) && [[ $BACKUP_STOP == 1 ]]; then
    confirm "Dienste werden fuer das Backup kurz gestoppt. Fortfahren?" || die "Abgebrochen."
  fi
  do_backup "$TMP/before"
  if [[ $BACKUP_STOPPED == 1 ]]; then
    run dc start
    wait_healthy || die "Dienste nach dem Backup nicht gesund."
  fi
}

cmd_rollback() {
  local dir name id
  dir="$(latest_backup)"
  [[ -n $dir ]] || die "Kein Backup in ./backups gefunden."
  warn "Rollback auf Backup: $dir"
  warn "Alle Daten seit diesem Backup gehen verloren. Container-Images werden auf den Stand davor gesetzt."
  confirm "Wirklich zuruecksetzen?" || die "Abgebrochen."

  run dc down
  if [[ -f $dir/images.txt ]]; then
    while read -r name id; do
      [[ $id == "-" ]] && continue
      if docker image inspect "$id" >/dev/null 2>&1; then
        run docker tag "$id" "$name"
      else
        warn "Image $name ($id) existiert nicht mehr lokal - wird neu gebaut/gezogen."
      fi
    done < "$dir/images.txt"
  fi
  restore_paths "$dir"
  restore_volumes "$dir"
  call_hook hook_restore "$dir" || die "hook_restore fehlgeschlagen."
  run dc up -d --no-build
  wait_healthy || die "Dienste nach Rollback nicht gesund."
  call_hook hook_smoke || die "Smoke-Test nach Rollback fehlgeschlagen."
  ok "Rollback abgeschlossen."
  warn "Der Git-Stand ist unveraendert. Aenderung am Dockerfile ggf. per git revert zuruecknehmen, sonst baut das naechste Update wieder die neue Version."
}

cmd_status() {
  local ver total running
  ver="$(hook_version 2>/dev/null | head -1 | tr -d '\t' || true)"
  total="$(dc ps -a -q 2>/dev/null | wc -l | tr -d ' ')"
  running="$(dc ps -q --status running 2>/dev/null | wc -l | tr -d ' ')"
  printf 'app=%s\tversion=%s\tcontainers=%s/%s\tcore=%s\tinstalled=%s\tlast_update=%s\tlast_backup=%s\tcommit=%s\n' \
    "$SERVICE_NAME" "${ver:--}" "$running" "$total" "$CORE_VERSION" \
    "$(state_get INSTALLED_AT)" "$(state_get LAST_UPDATE)" "$(state_get LAST_BACKUP)" \
    "$(git rev-parse --short HEAD 2>/dev/null || echo -)"
}

cmd_adopt() {
  [[ -n "$(dc ps -a -q)" ]] || die "Keine Container dieses Projekts gefunden - es gibt nichts zu uebernehmen."
  state_set INSTALLED_AT "$(date -Is)"
  state_set ADOPTED "1"
  state_set CORE_VERSION "$CORE_VERSION"
  ok "Bestehende Installation uebernommen."
}

# --- Ablauf ------------------------------------------------------------------
main() {
  require_cmds
  if [[ $MODE == status ]]; then
    load_conf
    cmd_status
    return 0
  fi
  acquire_lock
  git_sync
  load_conf

  info "$SERVICE_NAME - deploy.sh (Kern-Version $CORE_VERSION)"
  [[ $DRY == 1 ]] && warn "DRY-RUN: es wird nichts veraendert."
  prepare_env
  docker_preflight

  case $MODE in
    adopt)    cmd_adopt ;;
    backup)   cmd_backup ;;
    rollback) cmd_rollback ;;
    check)    [[ -f .deploy-state ]] || die "Noch nicht installiert - nichts zu pruefen."; cmd_update ;;
    auto)     if [[ -f .deploy-state ]]; then cmd_update; else cmd_install; fi ;;
  esac
  dc ps || true
}

main
