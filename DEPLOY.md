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
| `--status` | eine Statuszeile (Version, Container, letztes Update ...) fuer das Inventar |
| `--backup` | nur Backup erstellen |
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
| `BACKUP_STOP` | Dienste fuer Pfad-/Volume-Backup kurz stoppen | `1` |
| `NETWORKS` | externe Docker-Netzwerke, werden bei Bedarf angelegt | `cloudflare-net` |
| `KEEP_BACKUPS`, `HEALTH_TIMEOUT`, `MIN_FREE_MB` | Grenzwerte | `7`, `180`, `2048` |
| `hook_version` | gibt die laufende Version aus (Anzeige) | – |
| `hook_backup DIR` | zusaetzliche Sicherung, z. B. `pg_dump` (Dienste laufen) | – |
| `hook_restore DIR` | Wiederherstellung dazu; die Dienste sind gestoppt, der Hook startet bei Bedarf selbst Teile (z. B. nur die Datenbank) | – |
| `hook_check_update` | nach dem Bauen, vor der Rueckfrage; Rueckgabewert != 0 bricht das Update ab (z. B. Major-Sperre, siehe `--allow-major`) | – |
| `hook_post_up` | nach Start und Health-Check, z. B. Datenbank-Extensions aktualisieren | – |
| `hook_smoke` | Funktionstest nach dem Start; Rueckgabewert != 0 = Fehler | – |
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
