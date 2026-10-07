# Haupt-Version hier festlegen. Fuer Portainer gibt es keine beweglichen
# Minor-Tags (nur exakte Versionen sowie die Kanaele "alpine"/"alpine-sts"),
# daher exakt pinnen. Ein Versionswechsel ist eine Aenderung an dieser Zeile:
# Release Notes pruefen, Dockerfile im Remote aendern, danach ./deploy.sh.
# Portainer migriert seine Datenbank beim Start; Downgrades gehen nur per Rollback.
FROM portainer/portainer-ce:2.45.1-alpine
