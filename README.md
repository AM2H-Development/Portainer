# Portainer CE

## install:
* git clone https://github.com/AM2H-Development/Portainer.git
* cd Portainer
* cp sample.env .env
* nano .env
* docker compose up -d

## data:
Login data is stored in volume "portainer_data"

## use:
make sure that Treafik (https://github.com/AM2H-Development/Traefik) is running in a container and the network traefik_net is available
