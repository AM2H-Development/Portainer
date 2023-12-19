# Portainer CE
Install / upgrade Portainer Docker image on local server

git clone https://github.com/AM2H-Development/Portainer.git

touch .env (fill with your personal data, see .env in git)

cd Portainer

docker-compose --env-file ../.env up -d

