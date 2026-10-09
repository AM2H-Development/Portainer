# shellcheck shell=bash disable=SC2034
# Dienstspezifische Konfiguration fuer deploy.sh (Kern: siehe DEPLOY.md)

SERVICE_NAME="Portainer"

# Portainer-Daten (BoltDB) liegen im benannten Volume; fuer ein konsistentes
# Backup wird Portainer kurz gestoppt.
BACKUP_VOLUMES=(portainer_data)
BACKUP_STOP=1

hook_version() {
  dc exec -T portainer /portainer --version 2>&1 | head -1
}

# Das Image ist minimal (kein curl/wget garantiert): vom Host aus die
# oeffentliche Status-Route der Container-IP abfragen.
hook_smoke() {
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl fehlt auf dem Host - Smoke-Test uebersprungen."
    return 0
  fi
  local id ip deadline=$(( SECONDS + 60 ))
  id="$(dc ps -q portainer)"
  while (( SECONDS < deadline )); do
    for ip in $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$id"); do
      curl -ksf --max-time 5 "https://$ip:9443/api/system/status" >/dev/null && return 0
      curl -sf  --max-time 5 "http://$ip:9000/api/system/status" >/dev/null && return 0
    done
    sleep 3
  done
  err "Portainer antwortet nicht auf /api/system/status (9443/9000)."
  return 1
}

# Das Image ist exakt gepinnt (Dockerfile): neuere Versionen meldet dieser Hook, ohne etwas zu aendern.
#   compatible=X  neuere Patch-Version derselben Linie (z. B. 2.45.1 -> 2.45.2)
#   pending=Z     Dockerfile steht schon auf Z, der Container laeuft noch mit aelterer Version
#   newer=Y       neuere Linie (z. B. 2.46.0) - nur Hinweis, LTS/STS und Release Notes beachten
hook_latest_version() {
  command -v curl >/dev/null 2>&1 || return 0
  local cur running tags latest_compat latest_newer
  cur="$(sed -n 's|^FROM portainer/portainer-ce:\([0-9][0-9.]*\).*|\1|p' "$ROOT/Dockerfile" | head -1)"
  [[ -n $cur ]] || return 0
  # pending: Dockerfile ist schon angehoben (z. B. per git pull), der Container laeuft aber noch mit einer aelteren Version
  running="$(hook_version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [[ -n $running && $running != "$cur" && $(printf '%s\n%s\n' "$running" "$cur" | sort -V | tail -1) == "$cur" ]]; then
    echo "pending=$cur"
  fi
  [[ ${DEPLOY_OFFLINE:-0} == 1 ]] && return 0
  tags="$(curl -sf --max-time 15 \
    'https://hub.docker.com/v2/repositories/portainer/portainer-ce/tags?page_size=100&ordering=last_updated&name=-alpine' \
    | grep -oE '"name":"[0-9]+\.[0-9]+\.[0-9]+-alpine"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -uV)" || return 0
  [[ -n $tags ]] || return 0
  latest_compat="$(grep -E "^${cur%.*}\\." <<<"$tags" | tail -1)"
  latest_newer="$(tail -1 <<<"$tags")"
  if [[ -n $latest_compat && $(printf '%s\n%s\n' "$cur" "$latest_compat" | sort -V | tail -1) != "$cur" ]]; then
    echo "compatible=$latest_compat"
  fi
  if [[ -n $latest_newer && ${latest_newer%.*} != "${cur%.*}" && $(printf '%s\n%s\n' "$cur" "$latest_newer" | sort -V | tail -1) != "$cur" ]]; then
    echo "newer=$latest_newer"
  fi
  return 0
}
