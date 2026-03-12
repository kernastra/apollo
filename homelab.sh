#!/bin/bash

# --- 1. PRE-FLIGHT & SYSTEM INITIALIZATION ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)." 
   exit 1
fi

if ! [ -x "$(command -v docker)" ]; then
    echo "📦 Installing Docker and Docker Compose..."
    curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh
    usermod -aG docker "${SUDO_USER:-$USER}"
fi

read -p "Enter the full path to your Data/Media pool (e.g., /mnt/data): " BASE_POOL

ACTUAL_USER="${SUDO_USER:-$USER}"
USER_ID=$(id -u)
GROUP_ID=$(id -g)
PRIVATE_IP=$(hostname -I | awk '{print $1}')
CIDR_NETWORK="${PRIVATE_IP%.*}.0/24"
TIMEZONE="America/Los_Angeles"

echo "🔧 Optimizing Network for AdGuard..."
systemctl stop systemd-resolved && systemctl disable systemd-resolved
echo "nameserver 1.1.1.1" > /etc/resolv.conf

# --- 2. DIRECTORY STRUCTURE ---
DOCKER_ROOT="/docker"
COMPOSE_DIR="$DOCKER_ROOT/compose"
DATA_DIR="$DOCKER_ROOT/app-data"
MEDIA_DIR="$BASE_POOL/media"

echo "📁 Creating folder structure at $DOCKER_ROOT..."
SERVICES=(caddy adguard vaultwarden vscode makemkv arm plex jellyfin immich portainer prowlarr radarr radarr-elite sonarr qbittorrent recyclarr aura jellyseerr tailscale)

for SVC in "${SERVICES[@]}"; do
    mkdir -p "$COMPOSE_DIR/$SVC" "$DATA_DIR/$SVC"
done

mkdir -p "$MEDIA_DIR"/{movies,movies-remux,tv,downloads,photos,rips}
mkdir -p "$DATA_DIR/qbittorrent/wireguard"

# --- 3. CONFIGURATION FILE GENERATION ---

cat <<EOF > "$COMPOSE_DIR/caddy/Caddyfile"
{
    local_certs
}
adguard.home      { reverse_proxy localhost:8081 }
plex.home         { reverse_proxy localhost:32400 }
jellyfin.home     { reverse_proxy jellyfin:8096 }
requests.home     { reverse_proxy jellyseerr:5055 }
vault.home        { reverse_proxy vaultwarden:80 }
code.home         { reverse_proxy vscode:8443 }
torrent.home      { reverse_proxy qbittorrent:8080 }
radarr.home       { reverse_proxy radarr:7878 }
radarr-elite.home { reverse_proxy radarr-elite:7878 }
sonarr.home       { reverse_proxy sonarr:8989 }
prowlarr.home     { reverse_proxy prowlarr:9696 }
photos.home       { reverse_proxy immich-server:2283 }
aura.home         { reverse_proxy aura:3000 }
EOF

cat <<EOF > "$DATA_DIR/recyclarr/recyclarr.yml"
radarr:
  radarr-normal:
    base_url: http://radarr:7878
    api_key: RADARR_NORMAL_KEY
    include:
      - template: radarr-quality-definition-movie
      - template: radarr-custom-formats-hdr-dv
    custom_formats:
      - names: [x265 (HD)]
        score: 100
      - names: [Remux-UHD]
        score: -1000
  radarr-elite:
    base_url: http://radarr-elite:7878
    api_key: RADARR_ELITE_KEY
    include:
      - template: radarr-quality-definition-movie
      - template: radarr-custom-formats-imax-enhanced
    custom_formats:
      - names: [Remux-UHD]
        score: 10000
sonarr:
  sonarr-main:
    base_url: http://sonarr:8989
    api_key: SONARR_KEY
    include:
      - template: sonarr-quality-definition-series
      - template: sonarr-v3-custom-formats-web-dl
EOF

# --- 4. DOCKER COMPOSE FILES ---

# TAILSCALE
cat <<EOF > "$COMPOSE_DIR/tailscale/compose.yml"
services:
  tailscale:
    image: tailscale/tailscale:latest
    container_name: tailscale
    hostname: apollo-server
    environment:
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_USERSPACE=false
    volumes:
      - $DATA_DIR/tailscale:/var/lib/tailscale
      - /dev/net/tun:/dev/net/tun
    cap_add:
      - NET_ADMIN
      - NET_RAW
    restart: unless-stopped
    networks: [apollo_net]
networks:
  apollo_net:
    external: true
EOF

# JELLYFIN
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

# AURA (MediUX Posters)
cat <<EOF > "$COMPOSE_DIR/aura/compose.yml"
services:
  aura:
    image: ghcr.io/mediux-team/aura:latest
    container_name: aura
    restart: unless-stopped
    ports: ["3002:3000"]
    environment:
      - PUID=$USER_ID
      - PGID=$GROUP_ID
      - TZ=$TIMEZONE
    volumes:
      - $DATA_DIR/aura:/config
      - $MEDIA_DIR:/data/media
      - $DATA_DIR/plex:/plex_config:ro
    networks: [apollo_net]
networks:
  apollo_net:
    external: true
EOF

# MAKEMKV (Manual Backup - stopped after creation to avoid /dev/sr0 conflict with ARM)
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

# RADARR (Normal & Elite)
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

cat <<EOF > "$COMPOSE_DIR/radarr-elite/compose.yml"
services:
  radarr-elite:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr-elite
    ports: ["7879:7878"]
    environment: [PUID=$USER_ID, PGID=$GROUP_ID, TZ=$TIMEZONE]
    volumes: ["$DATA_DIR/radarr-elite:/config", "$MEDIA_DIR:/media"]
    networks: [apollo_net]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# SONARR, PROWLARR, QBITTORRENT, JELLYSEERR
for APP in sonarr prowlarr qbittorrent jellyseerr; do
  PORT_MAP=""; [ "$APP" == "sonarr" ] && PORT_MAP="ports: ['8989:8989']"; [ "$APP" == "prowlarr" ] && PORT_MAP="ports: ['9696:9696']"; [ "$APP" == "qbittorrent" ] && PORT_MAP="ports: ['8080:8080']"; [ "$APP" == "jellyseerr" ] && PORT_MAP="ports: ['5055:5055']"
  cat <<EOF > "$COMPOSE_DIR/$APP/compose.yml"
services:
  $APP:
    image: lscr.io/linuxserver/$APP:latest
    container_name: $APP
    $PORT_MAP
    environment: [PUID=$USER_ID, PGID=$GROUP_ID, TZ=$TIMEZONE]
    volumes: ["$DATA_DIR/$APP:/config", "$MEDIA_DIR:/media"]
    networks: [apollo_net]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF
done

# PLEX, CADDY, ADGUARD, RECYCLARR
cat <<EOF > "$COMPOSE_DIR/plex/compose.yml"
services:
  plex:
    image: lscr.io/linuxserver/plex:latest
    container_name: plex
    network_mode: host
    environment: [PUID=$USER_ID, PGID=$GROUP_ID, TZ=$TIMEZONE, VERSION=docker]
    volumes: ["$DATA_DIR/plex:/config", "$MEDIA_DIR:/data"]
    restart: unless-stopped
EOF

cat <<EOF > "$COMPOSE_DIR/caddy/compose.yml"
services:
  caddy:
    image: caddy:latest
    container_name: caddy
    network_mode: host
    volumes: ["$COMPOSE_DIR/caddy/Caddyfile:/etc/caddy/Caddyfile", "$DATA_DIR/caddy/data:/data"]
    restart: unless-stopped
EOF

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

# VAULTWARDEN
cat <<EOF > "$COMPOSE_DIR/vaultwarden/compose.yml"
services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    environment:
      - PUID=$USER_ID
      - PGID=$GROUP_ID
      - TZ=$TIMEZONE
    volumes:
      - $DATA_DIR/vaultwarden:/data
    networks: [apollo_net]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# VSCODE (code-server)
cat <<EOF > "$COMPOSE_DIR/vscode/compose.yml"
services:
  vscode:
    image: lscr.io/linuxserver/code-server:latest
    container_name: vscode
    ports: ["8443:8443"]
    environment:
      - PUID=$USER_ID
      - PGID=$GROUP_ID
      - TZ=$TIMEZONE
    volumes:
      - $DATA_DIR/vscode:/config
    networks: [apollo_net]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# PORTAINER
cat <<EOF > "$COMPOSE_DIR/portainer/compose.yml"
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    ports: ["9000:9000"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $DATA_DIR/portainer:/data
    networks: [apollo_net]
    restart: unless-stopped
networks:
  apollo_net:
    external: true
EOF

# IMMICH
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
    volumes:
      - $DATA_DIR/immich/upload:/usr/src/app/upload
      - /etc/localtime:/etc/localtime:ro
    depends_on:
      - immich-redis
      - immich-postgres
    networks: [apollo_net]
    restart: unless-stopped
  immich-machine-learning:
    image: ghcr.io/immich-app/immich-machine-learning:release
    container_name: immich-machine-learning
    volumes:
      - $DATA_DIR/immich/model-cache:/cache
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

# --- 5. EXECUTION ---
echo "🌐 Creating shared network..."
docker network create apollo_net || true

echo "🚀 Starting containers..."
find $COMPOSE_DIR -name "compose.yml" -exec docker compose -f {} up -d \;

# Stop MakeMKV after creation — it shares /dev/sr0 with ARM and should only
# be started manually when needed (docker start makemkv).
docker stop makemkv

echo ""
echo "--------------------------------------------------------"
echo "🛠️  STAGE 2: ARR KEYS & FINAL SYNC"
echo "--------------------------------------------------------"
echo "1. Radarr Normal: http://$PRIVATE_IP:7878"
echo "2. Radarr Elite:  http://$PRIVATE_IP:7879"
echo "3. Sonarr:        http://$PRIVATE_IP:8989"
echo ""
read -p "🔑 Radarr Normal API Key: " R_NORM
read -p "🔑 Radarr Elite API Key:  " R_ELITE
read -p "🔑 Sonarr API Key:        " S_KEY

sed -i "s/RADARR_NORMAL_KEY/$R_NORM/g" "$DATA_DIR/recyclarr/recyclarr.yml"
sed -i "s/RADARR_ELITE_KEY/$R_ELITE/g" "$DATA_DIR/recyclarr/recyclarr.yml"
sed -i "s/SONARR_KEY/$S_KEY/g" "$DATA_DIR/recyclarr/recyclarr.yml"

echo "🔄 Running initial Recyclarr sync..."
docker exec recyclarr recyclarr sync

# Final Permissions
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DOCKER_ROOT"
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$BASE_POOL"

echo ""
echo "🎉 APOLLO SERVER v10.0 IS LIVE!"
echo "Tailscale: Run 'docker exec -it tailscale tailscale up' to authenticate."
echo "Plex:      http://$PRIVATE_IP:32400/web"
echo "Jellyfin:  http://jellyfin.home or Port 8096"
echo "Requests:  http://requests.home or Port 5055"