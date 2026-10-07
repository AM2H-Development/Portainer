# Portainer CE

## Install and update

```bash
git clone https://github.com/AM2H-Development/Portainer.git
cd Portainer
./deploy.sh   # 1st run: creates .env from sample.env, then stops so you can review it
./deploy.sh   # 2nd run: installs; every later run: git pull, backup, update, health check
```

Details (options, backups, rollback, conventions): [DEPLOY.md](DEPLOY.md).

## Version

The Portainer version is set in the `Dockerfile` (`FROM portainer/portainer-ce:<version>-alpine`).
Portainer has no floating minor tags, so every version change is an edit of that line
(check the release notes first, then run `./deploy.sh`).

## Data

Login data and settings are stored in the volume `portainer_data`; `./deploy.sh` backs it up
to `./backups/` before each update.

## Network

The container joins the external network `cloudflare-net` (created by `deploy.sh` if missing),
so the Cloudflare tunnel can reach it.
