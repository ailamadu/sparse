docker container stop sparseclone-manager
docker container rm sparseclone-manager
docker run -d \
  --name sparseclone-manager \
  --restart unless-stopped \
  -p 80:80 \
  -p 443:443 \
  -v /u01/app/docker/sparse:/app \
  localhost/sparseclone-manager

 docker container ls sparseclone-manager
