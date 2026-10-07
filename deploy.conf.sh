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
