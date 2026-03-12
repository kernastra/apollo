![homelab-starter](img.png)

A single-script homelab bootstrap for a self-hosted media and productivity server ("Apollo Server"). Running `homelab.sh` installs Docker, creates a consistent directory layout, writes all Docker Compose files, and brings every service up in one shot.

## What it sets up

| Category | Services |
|----------|----------|
| **Proxy / DNS** | Caddy (reverse proxy), AdGuard Home (DNS ad-blocking) |
| **Media** | Plex, Jellyfin, Jellyseerr (requests), Aura (MediUX posters) |
| **Ripping** | ARM – Automatic Ripping Machine, MakeMKV |
| **Arr stack** | Radarr (normal), Radarr Elite, Sonarr, Prowlarr, qBittorrent, Recyclarr |
| **Photos** | Immich (server, machine-learning, Redis, Postgres) |
| **Productivity** | Vaultwarden (passwords), VS Code Server, Portainer |
| **Networking** | Tailscale |

All containers share a Docker bridge network (`apollo_net`). Caddy terminates local HTTPS (`*.home` domains) and proxies to each service by container name.

## Prerequisites

- Ubuntu / Debian-based Linux
- Run as root or via `sudo`
- A dedicated data/media disk or pool mounted (e.g. `/mnt/data`)

## Usage

### 1. Clone the repo

```bash
git clone https://github.com/your-user/homelab-starter.git
cd homelab-starter
```

### 2. Make the script executable

```bash
chmod +x homelab.sh
```

### 3. Run as root

```bash
sudo ./homelab.sh
```

The script will prompt for two pieces of input:

| Prompt | Example | Description |
|--------|---------|-------------|
| Data/Media pool path | `/mnt/data` | Root of your storage pool. Media and app-data subdirectories are created here automatically. |
| API keys (Stage 2) | — | After the *arr services start, you are prompted for Radarr (normal), Radarr Elite, and Sonarr API keys so Recyclarr can be synced immediately. |

### 4. Authenticate Tailscale

After the script finishes, run:

```bash
docker exec -it tailscale tailscale up
```

Follow the URL it prints to authenticate your node.

## What the script does (step by step)

1. **Pre-flight** — Checks for root, installs Docker if missing, adds your user to the `docker` group.
2. **Network prep** — Disables `systemd-resolved` and sets `1.1.1.1` as the system resolver so AdGuard can bind to port 53.
3. **Directory structure** — Creates `/docker/compose/<service>` and `/docker/app-data/<service>` for every service, plus media subdirectories (`movies`, `tv`, `downloads`, `photos`, `rips`, etc.).
4. **Config generation** — Writes the Caddy `Caddyfile` (local HTTPS + reverse proxy rules) and a templated `recyclarr.yml`.
5. **Compose file generation** — Writes a `compose.yml` for every service into its compose directory.
6. **Network + startup** — Creates the `apollo_net` Docker network and runs `docker compose up -d` on every generated compose file. MakeMKV is stopped immediately after creation (it shares `/dev/sr0` with ARM and must be started manually).
7. **Recyclarr sync** — Substitutes the API keys you provided into `recyclarr.yml` and runs an initial sync.
8. **Permissions** — Recursively sets ownership of `/docker` and your media pool to your user.

## Directory layout (after running)

```
/docker/
  compose/
    caddy/        ← Caddyfile + compose.yml
    adguard/
    plex/
    jellyfin/
    immich/       ← multi-container (server, ML, Redis, Postgres)
    ...
  app-data/
    plex/
    jellyfin/
    immich/
    ...

<BASE_POOL>/
  media/
    movies/
    movies-remux/
    tv/
    downloads/
    photos/
    rips/
```

## Service ports (direct access)

| Service | URL |
|---------|-----|
| Plex | `http://<server-ip>:32400/web` |
| Jellyfin | `http://<server-ip>:8096` or `http://jellyfin.home` |
| Jellyseerr | `http://<server-ip>:5055` or `http://requests.home` |
| AdGuard | `http://<server-ip>:8081` or `http://adguard.home` |
| Radarr | `http://<server-ip>:7878` |
| Radarr Elite | `http://<server-ip>:7879` |
| Sonarr | `http://<server-ip>:8989` |
| Prowlarr | `http://<server-ip>:9696` |
| qBittorrent | `http://<server-ip>:8080` |
| Immich | `http://<server-ip>:2283` or `http://photos.home` |
| Vaultwarden | `http://vault.home` |
| VS Code | `http://<server-ip>:8443` or `http://code.home` |
| Portainer | `http://<server-ip>:9000` |
| ARM | `http://<server-ip>:8082` |
| MakeMKV | `http://<server-ip>:5800` (start manually: `docker start makemkv`) |
| Aura | `http://aura.home` |

## Notes

- **MakeMKV** is created but immediately stopped. It shares the optical drive (`/dev/sr0`) with ARM. Start it manually when you need it and stop it before ARM resumes.
- **Immich** requires changing the default Postgres password before exposing the service externally. Edit `$DATA_DIR/immich/postgres` after first boot.
- **Recyclarr** keys: if you skip the Stage 2 prompts, manually edit `/docker/app-data/recyclarr/recyclarr.yml` and replace the `RADARR_NORMAL_KEY`, `RADARR_ELITE_KEY`, and `SONARR_KEY` placeholders, then run `docker exec recyclarr recyclarr sync`.
