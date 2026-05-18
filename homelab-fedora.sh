#!/bin/bash

# APOLLO SERVER — Fedora Optimized
# Based on homelab.sh, tuned for Fedora Server 39/40/41+
# Removes: Plex, Radarr-Elite, Tailscale, Portainer, Immich ML
# Optimized for 1080p media files, low CPU/GPU overhead

# --- 1. PRE-FLIGHT ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)."
   exit 1
fi

if ! [ -x "$(command -v docker)" ]; then
    echo "📦 Installing Docker..."
    dnf install -y docker-compose
    systemctl enable --now docker
fi

read -p "Enter the full path to your Data/Media pool (e.g., /mnt/data): " BASE_POOL

ACTUAL_USER="${SUDO_USER:-$USER}"
USER_ID=$(id -u "$ACTUAL_USER")
GROUP_ID=$(id -g "$ACTUAL_USER")
PRIVATE_IP=$(hostname -I | awk '{print $1}')
TIMEZONE="America/Los_Angeles"

# Fedora: use firewall-cmd instead of disabling systemd-resolved
echo "🔧 Opening firewall ports for services..."
for PORT in 53 8096 7878 8989 9696 8080 5055 3000 8443 2283; do
    firewall-cmd --add-port=$PORT/tcp --permanent 2>/dev/null || true
done
firewall-cmd --reload 2>/dev/null || true

# --- 2. DIRECTORY STRUCTURE ---
DOCKER_ROOT="/docker"
COMPOSE_DIR="$DOCKER_ROOT/compose"
DATA_DIR="$DOCKER_ROOT/app-data"
MEDIA_DIR="$BASE_POOL/media"

echo "📁 Creating folder structure at $DOCKER_ROOT..."
SERVICES=(caddy adguard vscode makemkv arm jellyfin immich prowlarr radarr sonarr qbittorrent recyclarr jellyseerr)

for SVC in "${SERVICES[@]}"; do
    mkdir -p "$COMPOSE_DIR/$SVC" "$DATA_DIR/$SVC"
done

mkdir -p "$MEDIA_DIR"/{movies,tv,downloads,photos,rips}
mkdir -p "$DATA_DIR/qbittorrent/wireguard"

# --- 3. CADDY CONFIG ---
cat <<EOF > "$COMPOSE_DIR/caddy/Caddyfile"
{
    local_certs
}
adguard.home      { reverse_proxy localhost:8081 }
jellyfin.home     { reverse_proxy jellyfin:8096 }
requests.home     { reverse_proxy jellyseerr:5055 }
code.home         { reverse_proxy vscode:8443 }
torrent.home      { reverse_proxy qbittorrent:8080 }
radarr.home       { reverse_proxy radarr:7878 }
sonarr.home       { reverse_proxy sonarr:8989 }
prowlarr.home     { reverse_proxy prowlarr:9696 }
photos.home       { reverse_proxy immich-server:2283 }
EOF

# --- 4. RECYCLARR CONFIG (1080p optimized, single Radarr) ---
cat <<EOF > "$DATA_DIR/recyclarr/recyclarr.yml"
radarr:
  radarr-main:
    base_url: http://radarr:7878
    api_key: RADARR_KEY
    include:
      - template: radarr-quality-definition-movie
      - template: radarr-custom-formats-hdr-dv
    custom_formats:
      # Score 1080p encodes, penalize 4K/Remux to reduce CPU/GPU stress
      - names: [x265 (1080p)]
        score: 100
      - names: [x264 (1080p)]
        score: 100
      - names: [Remux-UHD]
        score: -1000
      - names: [Remux-1080p]
        score: 50
      - names: [4K]
        score: -500
      - names: [HDR10+]
        score: 0
      - names: [DoVi]
        score: 0
sonarr:
  sonarr-main:
    base_url: http://sonarr:8989
    api_key: SONARR_KEY
    include:
      - template: sonarr-quality-definition-series
      - template: sonarr-v3-custom-formats-web-dl
EOF

# --- 5. DOCKER COMPOSE FILES ---

# JELLYFIN (CPU-friendly, no GPU passthrough)
cat <<EOF > "$COMPOSE_DIR/jellyfin/compose.yml"
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    user: $USER_ID:$GROUP_ID
    networks: [apollo_net]
    ports: ["8096:8096"]
    volumes:
      - $DATA_DIR/jellyfin:/config
      - $DATA_DIR/jellyfin/cache:/cache
      - $MEDIA_DIR:/data
    environment:
      - JELLYFIN_PublishedServerUrl=http://$PRIVATE_IP:8096
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# IMMICH (ML disabled)
cat <<EOF > "$COMPOSE_DIR/immich/compose.yml"
services:
  immich-server:
    image: ghcr.io/immich-app/immich-server:release
    container_name: immich-server
    ports: ["2283:2283"]
    environment:
      - DB_HOSTNAME=immich-postgres
      - DB_USERNAME=postgres
      - DB_PASSWORD=postgres
      - DB_DATABASE_NAME=immich
      - REDIS_HOSTNAME=immich-redis
      - TZ=$TIMEZONE
      - IMMICH_MACHINE_LEARNING_ENABLED=false
    volumes:
      - $DATA_DIR/immich/upload:/usr/src/app/upload
      - /etc/localtime:/etc/localtime:ro
    depends_on:
      - immich-redis
      - immich-postgres
    networks: [apollo_net]
    restart: unless-stopped
  immich-redis:
    image: redis:6.2-alpine
    container_name: immich-redis
    networks: [apollo_net]
    restart: unless-stopped
  immich-postgres:
    image: tensorchord/pgvecto-rs:pg14-v0.2.0
    container_name: immich-postgres
    environment:
      - POSTGRES_PASSWORD=postgres
      - POSTGRES_USER=postgres
      - POSTGRES_DB=immich
    volumes:
      - $DATA_DIR/immich/postgres:/var/lib/postgresql/data
    networks: [apollo_net]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# ARM (Automatic Ripping Machine)
cat <<EOF > "$COMPOSE_DIR/arm/compose.yml"
services:
  arm:
    image: automaticrippingmachine/automatic-ripping-machine:latest
    container_name: arm
    restart: unless-stopped
    ports: ["8082:8080"]
    devices:
      - /dev/sr0:/dev/sr0
      - /dev/sg2:/dev/sg2
    environment:
      - PUID=$USER_ID
      - PGID=$GROUP_ID
      - TZ=$TIMEZONE
    volumes:
      - $DATA_DIR/arm:/home/arm
      - $MEDIA_DIR/rips:/home/arm/media
      - $DATA_DIR/makemkv:/home/arm/.MakeMKV
    networks: [apollo_net]
networks:
  apollo_net:
    external: true
EOF

# MAKEMKV (stopped after creation — shares /dev/sr0 with ARM)
cat <<EOF > "$COMPOSE_DIR/makemkv/compose.yml"
services:
  makemkv:
    image: jlesage/makemkv
    container_name: makemkv
    ports: ["5800:5800"]
    devices:
      - /dev/sr0:/dev/sr0
      - /dev/sg2:/dev/sg2
    environment:
      - PUID=$USER_ID
      - PGID=$GROUP_ID
      - TZ=$TIMEZONE
    volumes:
      - $DATA_DIR/makemkv:/config
      - $MEDIA_DIR/rips:/output
    networks: [apollo_net]
networks:
  apollo_net:
    external: true
EOF

# RADARR (single instance, 1080p focused)
cat <<EOF > "$COMPOSE_DIR/radarr/compose.yml"
services:
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    ports: ["7878:7878"]
    environment: [PUID=$USER_ID, PGID=$GROUP_ID, TZ=$TIMEZONE]
    volumes: ["$DATA_DIR/radarr:/config", "$MEDIA_DIR:/media"]
    networks: [apollo_net]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# SONARR
cat <<EOF > "$COMPOSE_DIR/sonarr/compose.yml"
services:
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    ports: ["8989:8989"]
    environment: [PUID=$USER_ID, PGID=$GROUP_ID, TZ=$TIMEZONE]
    volumes: ["$DATA_DIR/sonarr:/config", "$MEDIA_DIR:/media"]
    networks: [apollo_net]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# PROWLARR
cat <<EOF > "$COMPOSE_DIR/prowlarr/compose.yml"
services:
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    ports: ["9696:9696"]
    environment: [PUID=$USER_ID, PGID=$GROUP_ID, TZ=$TIMEZONE]
    volumes: ["$DATA_DIR/prowlarr:/config", "$MEDIA_DIR:/media"]
    networks: [apollo_net]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# QBITTORRENT
cat <<EOF > "$COMPOSE_DIR/qbittorrent/compose.yml"
services:
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    ports: ["8080:8080"]
    environment: [PUID=$USER_ID, PGID=$GROUP_ID, TZ=$TIMEZONE]
    volumes: ["$DATA_DIR/qbittorrent:/config", "$MEDIA_DIR:/media"]
    networks: [apollo_net]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# JELLYSEERR
cat <<EOF > "$COMPOSE_DIR/jellyseerr/compose.yml"
services:
  jellyseerr:
    image: ghcr.io/fallenbagel/jellyseerr:latest
    container_name: jellyseerr
    ports: ["5055:5055"]
    environment: [PUID=$USER_ID, PGID=$GROUP_ID, TZ=$TIMEZONE]
    volumes: ["$DATA_DIR/jellyseerr:/config"]
    networks: [apollo_net]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# CADDY
cat <<EOF > "$COMPOSE_DIR/caddy/compose.yml"
services:
  caddy:
    image: caddy:latest
    container_name: caddy
    network_mode: host
    volumes: ["$COMPOSE_DIR/caddy/Caddyfile:/etc/caddy/Caddyfile", "$DATA_DIR/caddy/data:/data"]
    restart: unless-stopped
EOF

# ADGUARD
cat <<EOF > "$COMPOSE_DIR/adguard/compose.yml"
services:
  adguard:
    image: adguard/adguardhome
    container_name: adguard
    ports: ["53:53/tcp", "53:53/udp", "3000:3000", "8081:80"]
    networks: [apollo_net]
    volumes: ["$DATA_DIR/adguard/work:/opt/adguardhome/work", "$DATA_DIR/adguard/conf:/opt/adguardhome/conf"]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# RECYCLARR
cat <<EOF > "$COMPOSE_DIR/recyclarr/compose.yml"
services:
  recyclarr:
    image: ghcr.io/recyclarr/recyclarr:latest
    container_name: recyclarr
    environment: [TZ=$TIMEZONE]
    volumes: ["$DATA_DIR/recyclarr:/config"]
    networks: [apollo_net]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# VSCODE
cat <<EOF > "$COMPOSE_DIR/vscode/compose.yml"
services:
  vscode:
    image: lscr.io/linuxserver/code-server:latest
    container_name: vscode
    ports: ["8443:8443"]
    environment: [PUID=$USER_ID, PGID=$GROUP_ID, TZ=$TIMEZONE]
    volumes: ["$DATA_DIR/vscode:/config"]
    networks: [apollo_net]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# --- 6. EXECUTION ---
echo "🌐 Creating shared network..."
docker network create apollo_net 2>/dev/null || true

echo "🚀 Starting containers..."
find "$COMPOSE_DIR" -name "compose.yml" -exec docker compose -f {} up -d \;

# Stop MakeMKV after creation — shares /dev/sr0 with ARM
docker stop makemkv 2>/dev/null || true

# Final permissions
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DOCKER_ROOT"
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$BASE_POOL"

echo ""
echo "🎉 APOLLO SERVER (Fedora) IS LIVE!"
echo ""
echo "Service URLs:"
echo "  Jellyfin:    http://$PRIVATE_IP:8096"
echo "  Radarr:      http://$PRIVATE_IP:7878"
echo "  Sonarr:      http://$PRIVATE_IP:8989"
echo "  Prowlarr:    http://$PRIVATE_IP:9696"
echo "  qBittorrent: http://$PRIVATE_IP:8080"
echo "  Jellyseerr:  http://$PRIVATE_IP:5055"
echo "  Immich:      http://$PRIVATE_IP:2283"
echo "  Vaultwarden: http://$PRIVATE_IP:8888"
echo "  AdGuard:     http://$PRIVATE_IP:3000"
echo "  VSCode:      http://$PRIVATE_IP:8443"
