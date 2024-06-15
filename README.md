# Portainer CE

## install:
* git clone https://github.com/AM2H-Development/Portainer.git
* cd Portainer
* cp sample.env .env
* nano .env # adopt Hostname
* docker compose up -d

## data:
all Traefik Letsencrypt Certs are stored in volume "traefik_data", config files are read in ./

## use:
* config files in ./
* or Docker labels




touch .env (fill with your personal data, see .env in git)

cd Portainer

docker-compose --env-file ../.env up -d

