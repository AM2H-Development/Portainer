#!/bin/sh
docker stop portainer
docker rm portainer
docker volume create portainer_data
docker run -d -p 8000:8000 -p 9091:9000 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data -v /var/certs:/certs --restart=unless-stopped --name=portainer portainer/portainer-ce:2.11.1-alpine --ssl --sslcert /certs/cert.pem --sslkey /certs/privkey.pem
