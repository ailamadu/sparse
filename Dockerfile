FROM node:20-alpine

# Install packages only — no app files baked into the image
RUN apk add --no-cache \
      nginx \
      openssl \
      bash \
      python3 \
      openssh-client \
      tini

# Create dirs nginx needs at build time
RUN mkdir -p /var/log/nginx /run/nginx

EXPOSE 80 443

# /app is bind-mounted from the host at runtime — nothing is copied here.
# All files (code, certs, nginx.conf, data, logs) live on the host.
#
# docker run -v /host/path/sparseclone:/app ...
#
# Expected host directory layout:
#   /host/path/sparseclone/
#     ├── exadata_sparseclone_gui.html
#     ├── sparseclone_manager.js
#     ├── sparseclone_scheduler.py
#     ├── exadata_sparseclone_create_v6.sh
#     ├── nginx.conf
#     ├── certs/
#     │   ├── cert.pem
#     │   └── key.pem
#     ├── sparseclone_profiles.json     ← written at runtime
#     ├── sparseclone_schedules.json    ← written at runtime
#     ├── sparseclone_ssh.json          ← written at runtime
#     └── logs/                         ← written at runtime

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/bin/bash", "-c", "\
  cp /app/nginx.conf /etc/nginx/nginx.conf && \
  mkdir -p /etc/nginx/certs && \
  cp /app/certs/cert.pem /etc/nginx/certs/cert.pem && \
  cp /app/certs/key.pem  /etc/nginx/certs/key.pem  && \
  chmod +x /app/exadata_sparseclone_create_v6.sh && \
  mkdir -p /app/logs && \
  nginx && \
  python3 /app/sparseclone_scheduler.py --port 7891 --host 127.0.0.1 --data-dir /app & \
  exec node /app/sparseclone_manager.js --host 127.0.0.1 --port 7890 --no-browser \
"]
