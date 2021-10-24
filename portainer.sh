#!/bin/sh
# Install by typing:
# wget -q -O - https://raw.githubusercontent.com/AM2H-Development/Portainer/master/portainer.sh | bash
docker stop portainer
docker rm portainer
docker volume create portainer_data
# docker pull portainer/portainer-ce:2.5.1-alpine

docker run -d -p 8000:8000 -p 9091:9000\
  -v /var/run/docker.sock:/var/run/docker.sock\
  -v portainer_data:/data\
  -v /var/certs:/certs\
  --restart=unless-stopped --name=portainer\
  portainer/portainer-ce::2.5.1-alpine\
  --ssl --sslcert /certs/cert.pem --sslkey /certs/privkey.pem
