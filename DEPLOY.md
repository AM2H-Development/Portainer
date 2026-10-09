# Deployment & Updates (`deploy.sh`)

`deploy.sh` ist in **allen** Repos identisch (Kern-Version steht im Kopf der Datei).
Dienstspezifisches steht nur in `deploy.conf.sh`. Ein Aufruf entscheidet selbst, was zu tun ist.

```bash
./deploy.sh
```

## Ablauf

| Zustand | Was passiert |
|---|---|
| `.env` fehlt | Wird aus `sample.env` angelegt (Rechte 600), `{{GEN:...}}` werden durch Zufallswerte ersetzt. **Das Skript stoppt**, damit du `.env` pruefen/anpassen kannst. |
| `.env` enthaelt `{{CHANGEME}}` | Offene Variablen werden aufgelistet, Abbruch. |
| `sample.env` hat neue Variablen | Abbruch mit Liste; `./deploy.sh --add-missing` haengt sie an `.env` an. |
| nicht installiert | Erstinstallation: Netzwerke anlegen, Images bauen/ziehen, starten, auf Health warten, Smoke-Test. Laufen bereits Container dieses Projekts (Bestandssystem), fragt das Skript, ob es sie uebernehmen soll, und aktualisiert danach. |
| installiert | **Update:** `git pull --ff-only` -> Images bauen/ziehen -> nur wenn sich etwas aendert: Rueckfrage, Backup, Neustart, Health-Check, Smoke-Test. |

Die Datei `.env` wird nie ueberschrieben und Geheimnisse werden nie neu erzeugt, wenn sie existiert.

## Optionen

| Option | Wirkung |
|---|---|
| `--yes`, `-y` | Rueckfragen automatisch bestaetigen (Cron) |
| `--dry-run` | nur anzeigen, was passieren wuerde |
| `--allow-major` | Major-Upgrade erlauben, falls ein Dienst es per `hook_check_update` sperrt |
| `--no-pull` | kein `git pull` |
| `--check` | Updates pruefen: baut Images, vergleicht mit dem laufenden Stand, aendert nichts. Exit-Code 10 = Update verfuegbar |
| `--status` | eine Statuszeile (Version, Container, Kern-Version und -Hash, letztes Update ...) fuer das Inventar |
| `--compose ...` | `docker compose` fuer diesen Stack (alle Dateien, Projekt und `.env` gesetzt), z. B. `./deploy.sh --compose ps -a` oder `--compose logs --tail 50 zammad-init`. Alles nach `--compose` geht an Compose |
| `--backup` | nur Backup erstellen |
| `--restore backups/<Zeitstempel>` | Wiederherstellung auf einem **neuen/leeren Server** aus einem Backup (z. B. aus dem externen Backup). Muss das erste Argument sein. Holt die `.env` aus dem Backup, legt Container/Volumes an, spielt Dateien und Datenbank ein, startet und prueft |
| `--rollback` | letztes Backup + vorherige Images wiederherstellen (**Daten seit dem Backup gehen verloren**) |
| `--adopt` | bereits laufende Installation nur uebernehmen (Marker setzen), ohne zu aktualisieren; normalerweise nicht noetig, da der normale Aufruf danach fragt |
| `--add-missing` | neue Variablen aus `sample.env` an `.env` anhaengen |

## Versionen

* Die **Haupt-Version** steht im `Dockerfile` (`FROM <image>:<Version>`). Das ist die einzige Stelle.
* Regulaere Updates (Minor/Patch) laufen ueber `./deploy.sh`, ohne dass im Repo etwas geaendert werden muss.
* **Grosse Upgrades:** Release Notes pruefen, `Dockerfile` im Remote aendern, auf dem Server `./deploy.sh`
  (das Skript holt die Aenderung per `git pull`).
* Vor jedem Update wird das bisherige Image als `<name>:previous` markiert; erst danach raeumt `docker image prune` auf.

## Backups

* Liegen in `./backups/<Zeitstempel>/` (lokal, nicht im Git), die letzten `KEEP_BACKUPS` (Standard 7) bleiben.
* Inhalt: `files.tar.gz` (`.env` + `BACKUP_PATHS`), `vol_*.tar.gz` (`BACKUP_VOLUMES`), `images.txt` (Image-Stand fuer den Rollback) und ggf. Dumps aus `hook_backup`.
* **Kein Offsite-Backup.** `./backups` regelmaessig auf ein anderes System kopieren.
* Das Backup braucht kein `sudo`: `tar` laeuft in einem kurzen Hilfscontainer (`alpine:3`, wird bei Bedarf einmalig geladen).
* `docker pull`/`build` zeigen ihre Ausgabe nur bei Fehlern.

## Rollback

`./deploy.sh --rollback` stoppt den Stack, setzt die Images auf den Stand des letzten Backups, spielt die Daten zurueck
und startet neu. Der **Git-Stand bleibt unveraendert**: wurde das Dockerfile geaendert, die Aenderung per `git revert`
zuruecknehmen, sonst baut das naechste Update wieder die neue Version.

## `deploy.conf.sh`

| Variable / Hook | Bedeutung | Standard |
|---|---|---|
| `SERVICE_NAME` | Anzeigename | Verzeichnisname |
| `BACKUP_PATHS` | Pfade (relativ zum Repo), die archiviert werden (`.env` immer) | leer |
| `BACKUP_VOLUMES` | benannte Compose-Volumes (Namen wie in `compose.yaml`), werden als `vol_<name>.tar.gz` gesichert | leer |
| `BACKUP_QUIESCE` | Dienste, die VOR `hook_backup` gestoppt werden (Datenbank bleibt an): Dump ohne Verlustfenster, dafuer Ausfall waehrend des Dumps | leer |
| `BACKUP_STOP` | Dienste fuer Pfad-/Volume-Backup kurz stoppen | `1` |
| `COMPOSE_DIR`, `COMPOSE_REPO_URL`, `COMPOSE_PROJECT`, `COMPOSE_FILES` | den Stack in einem anderen Verzeichnis steuern (z. B. Upstream-Klon): Verzeichnis, Klon-URL falls es fehlt, Projektname (`-p`), Compose-Dateien (`-f`). Die `.env` bleibt in diesem Repo (`--env-file`) | leer |
| `NETWORKS` | externe Docker-Netzwerke, werden bei Bedarf angelegt | `cloudflare-net` |
| `KEEP_BACKUPS`, `HEALTH_TIMEOUT`, `MIN_FREE_MB` | Grenzwerte | `7`, `180`, `2048` |
| `hook_version` | gibt die laufende Version aus (Anzeige) | – |
| `hook_latest_version` | fuer fest gepinnte Dienste: meldet neuere Upstream-Versionen per Netzabfrage. Ausgabe: `compatible=X` (Update in derselben Linie, `--check` endet mit Exit 10), `newer=Y` (neue Linie, nur Hinweis), `pending=Z` (Repo ist schon auf Z angehoben, der Container laeuft noch mit einer aelteren Version; `--check` endet mit Exit 10); keine Ausgabe = aktuell/unbekannt. Fliesst in `--status`/`--check` ein; der Hook muss bei `DEPLOY_OFFLINE=1` selbst auf Netzabfragen verzichten | – |
| `hook_backup DIR` | zusaetzliche Sicherung, z. B. `pg_dump` (Dienste laufen) | – |
| `hook_pre_pull` | vor dem Laden/Bauen der Images, z. B. einen Upstream-Klon aktualisieren | – |
| `hook_restore DIR` | Wiederherstellung dazu; die Dienste sind gestoppt, der Hook startet bei Bedarf selbst Teile (z. B. nur die Datenbank) | – |
| `hook_check_update` | nach dem Bauen, vor der Rueckfrage; Rueckgabewert != 0 bricht das Update ab (z. B. Major-Sperre, siehe `--allow-major`) | – |
| `hook_post_up` | nach Start und Health-Check, z. B. Datenbank-Extensions aktualisieren | – |
| `hook_smoke` | Funktionstest nach dem Start; Rueckgabewert != 0 = Fehler | – |
| `hook_config_check` | Adress-/URL-Einstellungen pruefen (nach Install, Update, Restore); **nur Warnung**, Rueckgabewert wird ignoriert | – |
| `hook_preflight` | zusaetzliche Vorpruefungen | – |

**Hinweis zu Hooks:** `set -e` ist in Hooks teilweise unwirksam (sie laufen u. a. in `if`-Bedingungen). Jeder Schritt in
`hook_backup`, `hook_smoke` usw. muss Fehler selbst mit `|| return 1` weitergeben.

## Konventionen fuer `sample.env`

* `KEY={{GEN:hex32}}` – 32 Zufallsbytes als Hex; `{{GEN:pw24}}` – 24 alphanumerische Zeichen.
* `KEY={{CHANGEME}}` – muss von Hand gesetzt werden.
* Kommentarzeilen werden nicht ausgewertet.

## Hinweis zum Build-Kontext

Services werden ueber ein `Dockerfile` gebaut (`build: .`). Die `.dockerignore` schliesst alles ausser dem Dockerfile aus,
damit Datenverzeichnisse (oft root-eigen, gross) nicht in den Build-Kontext gelangen.

## Verbindungsabbruch und lange Laeufe

* **`tmux` benutzen:** `tmux new -s deploy` (Trennen: `Strg+b`, dann `d`; wieder verbinden: `tmux attach -t deploy`).
  Ein Verbindungsabbruch beendet sonst alle Prozesse der SSH-Sitzung, auch ein laufendes Backup/Update.
  `tools/update-all.sh` startet sich selbst in tmux (Session `ops-update`), wenn es interaktiv und tmux installiert ist.
* **Abbruch-Sicherheit:** Bei Hangup, `Strg+C` oder TERM startet `deploy.sh` Dienste wieder, die es selbst gestoppt hat.
  Ein unterbrochenes Backup bleibt mit `.incomplete` markiert, wird vom Rollback nie verwendet und beim naechsten
  Backup entfernt.
* Lange Schritte (Dumps) melden alle 30 Sekunden die Dateigroesse (`progress_start`/`progress_stop` in Hooks).
