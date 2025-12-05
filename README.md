# WordPress + MariaDB + Redis + Traefik on Docker Swarm

This guide is a batteries-included recipe for running multiple WordPress sites on Docker Swarm: Swarm gives you multi-node scheduling and self-healing, Traefik handles HTTPS + routing automatically via labels, and the Dockerized MariaDB/Redis/WordPress services keep your app portable and reproducible. You’ll prep the host, wire up env vars, networks, and permissions, then deploy the `database`, `traefik`, and `wordpress` stacks (prefix `wpstack__`).

Quick flow (clickable steps):
1) [Prepare server & clone repo](#1-prepare-the-server-and-clone-this-repo)  
2) [Configure `/etc/environment`](#2-configure-etcenvironment)  
3) [Init Swarm](#3-initialize-the-swarm-and-save-tokens)  
4) [Create overlay networks](#4-create-overlay-networks-external)  
5) [Prep data dirs & init script](#5-prepare-data-directories-and-permissions)  
6) [Database stack](#6-database-stack-edit--deploy--verify)  
7) [Traefik stack](#7-traefik-stack-edit--deploy--verify)  
8) [phpMyAdmin (optional)](#8-phpmyadmin-optional-ui--create-databases)  
9) [WordPress site 1](#9-wordpress-site-1-edit--deploy--verify)  
10) [WordPress site 2](#10-wordpress-site-2-edit--deploy--verify)  
11) [After deployment checks](#11-after-deployment-quick-health-checks-next-logins)  
12) [Stack file highlights](#12-stack-file-highlights)  
13) [Ops notes](#13-ops-notes)  
14) [Config observations](#14-config-observations)

## Swarm roles: managers vs workers
- Managers run the control plane (Raft state, scheduling, cluster changes). Keep an odd number (3 or 5) for quorum and store the manager join token securely. Port 2377/tcp must be reachable from joining nodes.
- Workers only run tasks; they don’t vote in Raft. Add more workers to scale services horizontally using the worker join token.
- Managers can run workloads too; if you want them control-plane-only, drain them: `docker node update --availability drain <manager-name>` and deploy your stacks to workers.

## Prerequisites
- Ubuntu 24.x or newer with `sudo` access (other Linux distros are fine—use equivalent package/ufw commands).
- Docker & Docker Swarm installed. If not installed, see: https://www.docker.com/get-started/
- Domain pointing to your server IP (for Traefik/WordPress hosts and ACME).
- Swarm ports opened on all nodes (per [Bret Fisher’s Swarm port guide](https://gist.github.com/BretFisher/7233b7ecf14bc49eb47715bbeb2a2769)):
  - Managers: TCP 2377 (cluster mgmt), TCP/UDP 7946 (gossip), UDP 4789 (VXLAN data), plus IP protocol 50 if you encrypt overlay.
  - Workers: TCP/UDP 7946, UDP 4789, plus IP protocol 50 if you encrypt overlay.
  - UFW example manager: `sudo ufw allow 2377/tcp && sudo ufw allow 7946 && sudo ufw allow 4789/udp`
  - UFW example worker: `sudo ufw allow 7946 && sudo ufw allow 4789/udp`
  - Mirror these in cloud Security Groups/VPC firewalls (source = your Swarm node SG to keep it internal).
- Edit files with `nano <file>` (install if needed: `sudo apt-get install -y nano`); save with `Ctrl+O`, `Enter`, exit with `Ctrl+X`.

## 1) Prepare the server and clone this repo
- Tested on Ubuntu 24.x or newer; use equivalent commands on your Linux distro.
- Create a deployment user (example) and allow sudo/Docker (you will be prompted for a password—save it securely):  
  ```bash
  sudo adduser deployer
  sudo usermod -aG sudo,docker deployer
  ```
- Install Git if missing: `sudo apt-get update && sudo apt-get install -y git`
- Switch to the deployer user and clone the stack repo (rename folder as you like, e.g. `wordpress-stack`):  
  ```bash
  sudo -iu deployer
  git clone https://github.com/tanngoc93/wordpress-stack.git wordpress-stack
  cd wordpress-stack
  ```
- DNS & firewall prerequisites:  
  - Point your domains to the server’s public IP (A/AAAA records) before running Traefik/ACME.  
    - Example (Cloudflare): add an `A` record for `domain.com` and another `A` for `www` pointing to your server IP. Turn off proxy (orange cloud) if you want ACME HTTP challenge to reach Traefik directly.  
  - Allow inbound ports 80/443 (and 22 for SSH). Example on Ubuntu UFW:  
    ```bash
    sudo ufw allow 22
    sudo ufw allow 80
    sudo ufw allow 443
    sudo ufw enable
    ```
  - If your cloud/server provider also has a dashboard firewall (Security Group/VPC rules), open 80 and 443 there too. If unsure, check their docs or contact support to confirm HTTP/HTTPS are allowed to this server.

## 2) Configure `/etc/environment`
Use nano (or your editor) so the variables are loaded for every shell login.
```bash
sudo nano /etc/environment
```
Add/keep these lines:
```
# Container image tags
WORDPRESS_IMAGE_TAG="6.8.3-php8.1-fpm"       # WordPress image tag; use wordpress:<tag> (e.g., 6.8.3-php8.1-apache)
TRAEFIK_IMAGE_TAG="v3.6.2"                   # Traefik image tag; use traefik:<tag>
MARIADB_IMAGE_TAG="12.1.2-noble"             # MariaDB image tag; use mariadb:<tag> (stack defaults to latest if unset)
REDIS_IMAGE_TAG="7.4.1"                      # Redis image tag; use redis:<tag> (stack defaults to latest if unset)
TRAEFIK_IMAGE_TAG="v3.6.2"                   # Traefik image tag; use traefik:<tag>

# Database (shared)
MARIADB_ROOT_USER="root"
MARIADB_ROOT_PASSWORD="sample-userpass"       # change to a strong unique password
MARIADB_USER="wordpress"                      # required (used by WordPress)
MARIADB_PASSWORD="sample-userpass"            # change to a strong unique password
WORDPRESS_DB_HOST="mariadb-svc"               # shared DB host (service name in database-stack.yml)

# Redis (shared host/port)
WORDPRESS_REDIS_HOST="redis-svc"              # shared Redis host (service name in database-stack.yml)
WORDPRESS_REDIS_PORT=6379

# WordPress site 1
WORDPRESS_APP1_DB_NAME="wordpress_db_site1"   # change per site
WORDPRESS_APP1_TABLE_PREFIX="wp_1_"           # change if you want a custom prefix
WORDPRESS_APP1_REDIS_DATABASE=0

# WordPress site 2
WORDPRESS_APP2_DB_NAME="wordpress_db_site2"   # change per site
WORDPRESS_APP2_TABLE_PREFIX="wp_2_"           # change if you want a custom prefix
WORDPRESS_APP2_REDIS_DATABASE=1               # use different DB index to avoid collisions
```
Reload for the current shell if needed:
```bash
set -a && source /etc/environment && set +a
```

## 3) Initialize the Swarm and save tokens
```bash
docker swarm init
# Save join tokens for later:
docker swarm join-token manager
docker swarm join-token worker
```
Keep the join commands and manager IP/port somewhere safe.

Quick checks (run these if unsure):
- See Docker is installed: `docker --version`
- See Swarm is active (look for “Swarm: active”): `docker info | grep -i swarm`
- See what stacks exist: `docker stack ls`
- See services inside one stack: `docker stack services <stack_name>`

## 4) Create overlay networks (external)
These are marked `external: true` in the stack files, so create them first:
```bash
docker network create --driver=overlay public-network
docker network create --driver=overlay private-network
```

## 5) Prepare data directories and permissions
- MariaDB data at `/www/data/mysql-data` (owner stays mysql inside container; group = your current user so you can access it):
```bash
sudo install -d -m 770 /www/data/mysql-data
sudo chown 999:$(id -gn) /www/data/mysql-data   # 999 = mysql in the image; group set to your login group
```
- Traefik ACME storage at `./traefik/letsencrypt/acme.json`:
```bash
cd /path/to/wordpress-stack
sudo install -d -m 700 traefik/letsencrypt
echo "{}" | sudo tee traefik/letsencrypt/acme.json >/dev/null
sudo chmod 600 traefik/letsencrypt/acme.json
```
- MariaDB init scripts: ensure `db-init/00-create-wp-user.sh` is executable (creates the non-root user on first start):
```bash
cd /path/to/wordpress-stack
sudo chmod +x db-init/00-create-wp-user.sh
```

## 6) Database stack (edit → deploy → verify)
- What to set: `/etc/environment` already holds DB root user/password. Ensure data dir `/www/data/mysql-data` exists with correct perms (step 5).
- Deploy (choose your prefix, `wpstack__` used here):
  ```bash
  cd /path/to/wordpress-stack
  set -a && source /etc/environment && set +a
  docker stack deploy -c database-stack.yml wpstack__db
  ```
- Verify:
  ```bash
  docker stack ps wpstack__db
  docker service logs -f wpstack__db_mariadb-svc
  docker service logs -f wpstack__db_redis-svc
  ```
  *Notes:* the init script in `db-init/` runs only on first start; it creates/grants the `MARIADB_USER` with full privileges. Create the WordPress databases manually (phpMyAdmin/MySQL).

## 7) Traefik stack (edit → deploy → verify)
- Edit `traefik/traefik.toml`: set `certificatesResolvers.myhttpchallenge.acme.email` to a real email.
- Edit `traefik-stack.yml`: replace `traefik.domain.com` in labels with your dashboard domain.  
  Optional basic auth: generate a hash `echo $(htpasswd -nB myuser) | sed -e s/\\$/\\$\\$/g`, then add:
  ```
  - "traefik.http.middlewares.traefik-svc-auth.basicauth.users=myuser:...hash..."
  - "traefik.http.routers.traefik-svc-https.middlewares=traefik-svc-auth"
  ```
- Deploy:
  ```bash
  cd /path/to/wordpress-stack
  set -a && source /etc/environment && set +a
  docker stack deploy -c traefik-stack.yml wpstack__traefik   # change prefix if you prefer
  ```
- Verify:
  ```bash
  docker stack ps wpstack__traefik
  docker service logs -f wpstack__traefik_traefik-svc
  ```
- Why Traefik? Reverse proxy/load balancer with automatic Let's Encrypt, per-service routing via labels, and a dashboard—ideal for Swarm/label-driven routing. Learn more:  
  - Image tags/docs: https://hub.docker.com/_/traefik  
  - Product/docs: https://traefik.io/traefik
  - Image tag set via `TRAEFIK_IMAGE_TAG` (default `v3.6.2`).

## 8) phpMyAdmin (optional UI) → create databases
- Use only after the database stack is running and before deploying WordPress.
- Edit `phpmyadmin-stack.yml`: replace `pma.example.com` with your domain.  
  Optional basic auth:
  ```
  - "traefik.http.middlewares.phpmyadmin-auth.basicauth.users=myuser:...hash..."
  - "traefik.http.routers.phpmyadmin-https.middlewares=phpmyadmin-auth"
  ```
- Deploy:
  ```bash
  cd /path/to/wordpress-stack
  set -a && source /etc/environment && set +a
  docker stack deploy -c phpmyadmin-stack.yml wpstack__pma   # change prefix if you prefer
  ```
- Create DBs via UI:
  - Open your phpMyAdmin domain, log in with DB creds (run from `deployer` user).  
    - Server/Host: `mariadb-svc` (from `WORDPRESS_DB_HOST` in `/etc/environment`)  
    - Username: DB root user (`MARIADB_ROOT_USER`) or non-root user (`MARIADB_USER`)  
    - Password: matching password (`MARIADB_ROOT_PASSWORD` or `MARIADB_PASSWORD`)
  - Create databases matching the names in `/etc/environment`:  
    - Site1 DB name from `WORDPRESS_APP1_DB_NAME` (default example: `wordpress_db_site1`)  
    - Site2 DB name from `WORDPRESS_APP2_DB_NAME` (default example: `wordpress_db_site2`)  
    If you changed those env values, create the DBs with the names you set.
- Verify:
  ```bash
  docker stack ps wpstack__pma
  docker service logs -f wpstack__pma_phpmyadmin-svc
  ```
- After you finish creating databases, you can stop/remove phpMyAdmin to reduce exposure:
  ```bash
  docker stack rm wpstack__pma   # remove phpMyAdmin stack
  ```
  Start it again later if needed:
  ```bash
  cd /path/to/wordpress-stack
  set -a && source /etc/environment && set +a
  docker stack deploy -c phpmyadmin-stack.yml wpstack__pma
  ```

## 9) WordPress site 1 (edit → deploy → verify)
- Edit `wordpress-site1-stack.yml`: change hosts `site1.example.com`/`www.site1.example.com` to your domain.
- WordPress image tag is controlled by `WORDPRESS_IMAGE_TAG` (default example: `6.8.3-php8.1-fpm`; choose any tag from https://hub.docker.com/_/wordpress).
- Site files `wp_appname1/` (choose the path based on your scenario):
  - Set ownership/permissions (run inside `wp_appname1`, before or after copying files):
    ```bash
    cd /path/to/wordpress-stack/wp_appname1
    sudo chown www-data:www-data -R *
    sudo find . -type d -exec chmod 755 {} \;
    sudo find . -type f -exec chmod 644 {} \;
    cd ..
    ```
  - Migrating an existing site: copy your old `wp-content`, `wp-includes`, and `wp-admin` into `wp_appname1/` (folders are pre-created).
  - Fresh install: populate `wp_appname1/wp-admin`, `wp_appname1/wp-includes`, and `wp_appname1/wp-content` from a fresh WordPress download, then add your theme/plugin files:
    ```bash
    curl -L https://wordpress.org/latest.tar.gz -o /tmp/wordpress.tar.gz
    tar -xzf /tmp/wordpress.tar.gz -C /tmp
    sudo cp -r /tmp/wordpress/wp-admin /tmp/wordpress/wp-includes /tmp/wordpress/wp-content wp_appname1/
    rm -rf /tmp/wordpress /tmp/wordpress.tar.gz
    ```
  - Edit salts in `wp_appname1/wp-config/wp-config.php`: open the file (`sudo nano wp_appname1/wp-config/wp-config.php`), find the block from `define('AUTH_KEY'` through `define('NONCE_SALT'`, and replace all eight lines with new ones from https://api.wordpress.org/secret-key/1.1/salt/ (copy-paste the whole block).
  - Defaults use DB name `wordpress_site1` and prefix `wp1_`; adjust if needed.
- WordPress DB user/password in this stack come from `MARIADB_USER` / `MARIADB_PASSWORD` (non-root).
- Create DB (if not yet): use phpMyAdmin or MySQL to create the DB name set in `/etc/environment` under `WORDPRESS_APP1_DB_NAME` (default example: `wordpress_db_site1`).
- Deploy:
  ```bash
  cd /path/to/wordpress-stack
  set -a && source /etc/environment && set +a
  docker stack deploy -c wordpress-site1-stack.yml wpstack__wp1   # change prefix if you prefer
  ```
- Verify:
  ```bash
  docker stack ps wpstack__wp1
  docker service logs -f wpstack__wp1_wp_site1
  ```

## 10) WordPress site 2 (edit → deploy → verify)
- Edit `wordpress-site2-stack.yml`: change hosts `site2.example.com`/`www.site2.example.com` to your domain.
- WordPress image tag is controlled by `WORDPRESS_IMAGE_TAG` (default example: `6.8.3-php8.1-fpm`; choose any tag from https://hub.docker.com/_/wordpress).
- Site files `wp_appname2/` (choose the path based on your scenario):
  - Set ownership/permissions (run inside `wp_appname2`, before or after copying files):
    ```bash
    cd /path/to/wordpress-stack/wp_appname2
    sudo chown www-data:www-data -R *
    sudo find . -type d -exec chmod 755 {} \;
    sudo find . -type f -exec chmod 644 {} \;
    cd ..
    ```
  - Migrating an existing site: copy your old `wp-content`, `wp-includes`, and `wp-admin` into `wp_appname2/` (folders are pre-created).
  - Fresh install: populate `wp_appname2/wp-admin`, `wp_appname2/wp-includes`, and `wp_appname2/wp-content` from a fresh WordPress download, then add your theme/plugin files:
    ```bash
    curl -L https://wordpress.org/latest.tar.gz -o /tmp/wordpress.tar.gz
    tar -xzf /tmp/wordpress.tar.gz -C /tmp
    sudo cp -r /tmp/wordpress/wp-admin /tmp/wordpress/wp-includes /tmp/wordpress/wp-content wp_appname2/
    rm -rf /tmp/wordpress /tmp/wordpress.tar.gz
    ```
  - Edit salts in `wp_appname2/wp-config/wp-config.php`: open the file (`sudo nano wp_appname2/wp-config/wp-config.php`), find the block from `define('AUTH_KEY'` through `define('NONCE_SALT'`, and replace all eight lines with new ones from https://api.wordpress.org/secret-key/1.1/salt/ (copy-paste the whole block).
  - Defaults use DB name `wordpress_site2`, prefix `wp2_`, Redis DB index 1; adjust if needed.
- WordPress DB user/password in this stack come from `MARIADB_USER` / `MARIADB_PASSWORD` (non-root).
- Create DB (if not yet): use phpMyAdmin or MySQL to create the DB name set in `/etc/environment` under `WORDPRESS_APP2_DB_NAME` (default example: `wordpress_db_site2`).
- Deploy:
  ```bash
  cd /path/to/wordpress-stack
  set -a && source /etc/environment && set +a
  docker stack deploy -c wordpress-site2-stack.yml wpstack__wp2   # change prefix if you prefer
  ```
- Verify:
  ```bash
  docker stack ps wpstack__wp2
  docker service logs -f wpstack__wp2_wp_site2
  ```

## 11) After deployment: quick health checks (next logins)
Every time you SSH back in (as `deployer` user), run:
```bash
docker stack ls                      # stacks should show wpstack__db/wpstack__traefik/wpstack__wp1/wpstack__wp2/wpstack__pma
docker stack services wpstack__wp1   # check service state for site1
docker stack services wpstack__wp2   # check service state for site2
docker stack services wpstack__traefik
docker stack services wpstack__db
```
If you see issues, tail logs:
```bash
docker service logs -f wpstack__wp1_wp_site1
docker service logs -f wpstack__wp2_wp_site2
docker service logs -f wpstack__traefik_traefik-svc
docker service logs -f wpstack__db_mariadb-svc
docker service logs -f wpstack__db_redis-svc
```

## 12) Stack file highlights
- `database-stack.yml`  
  - External overlay network `private-network`.  
  - `mariadb-svc` mounts `/www/data/mysql-data` → `/var/lib/mysql`; needs `MARIADB_ROOT_PASSWORD`; constrained to manager. Image tag via `MARIADB_IMAGE_TAG` (example `12.1.2-noble`, stack falls back to `latest` if unset): https://hub.docker.com/_/mariadb  
  - `redis-svc` single replica on `private-network`. Image tag via `REDIS_IMAGE_TAG` (example `7.4.1`, stack falls back to `latest` if unset): https://hub.docker.com/_/redis  
- `traefik-stack.yml`  
  - External overlay `public-network`.  
  - Mounts `traefik/traefik.toml` and `traefik/letsencrypt`; exposes 80/443.  
  - Labels configure routers for `traefik.domain.com` with HTTP→HTTPS redirect and optional basicauth (add user hash to `traefik.http.middlewares.traefik-svc-auth.basicauth.users`).  
- `wordpress-site1-stack.yml`  
  - Joins both `public-network` and `private-network`.  
  - Service `wp_site1` mounts `./wp_appname1/...`.  
  - Labels route `site1.example.com` to the service with cert resolver `myhttpchallenge`.  
  - Requires env vars: shared DB host (`WORDPRESS_DB_HOST`), DB user/pass (`MARIADB_USER`/`MARIADB_PASSWORD`), site1 DB name/prefix (`WORDPRESS_APP1_DB_*`), shared Redis host/port (`WORDPRESS_REDIS_HOST`, `WORDPRESS_REDIS_PORT`), and site1 Redis DB index (`WORDPRESS_APP1_REDIS_DATABASE`). Salts set in `wp_appname1/wp-config/wp-config.php`.
- `wordpress-site2-stack.yml`  
  - Joins both `public-network` and `private-network`.  
  - Service `wp_site2` mounts `./wp_appname2/...`.  
  - Labels route `site2.example.com` to the service with cert resolver `myhttpchallenge`.  
  - Requires env vars: shared DB host (`WORDPRESS_DB_HOST`), DB user/pass (`MARIADB_USER`/`MARIADB_PASSWORD`), site2 DB name/prefix (`WORDPRESS_APP2_DB_*`), shared Redis host/port (`WORDPRESS_REDIS_HOST`, `WORDPRESS_REDIS_PORT`), and site2 Redis DB index (`WORDPRESS_APP2_REDIS_DATABASE`). Salts set in `wp_appname2/wp-config/wp-config.php`.
- `phpmyadmin-stack.yml`  
  - Joins both `public-network` and `private-network` to reach Traefik and MariaDB.  
  - Routes `pma.example.com` (change to your domain) to phpMyAdmin.  
  - Uses shared DB host (`WORDPRESS_DB_HOST`) and root creds; consider enabling basicauth middleware for security.  

## 13) Ops notes
- Ensure DNS points to the manager/load balancer before enabling Traefik so ACME HTTP challenge succeeds.
- When adding nodes, create the overlay networks on the manager first; Swarm will handle distribution.
- Back up `/www/data/mysql-data` and `traefik/letsencrypt/acme.json` regularly.
- Use `docker service logs -f <stack>_<service>` for troubleshooting.

## 14) Config observations
- `public-network` and `private-network` are `external: true`; they must exist before deploy (see step 3).  
- `traefik/traefik.toml` still has a placeholder email—must be updated for ACME.  
- `acme.json` must exist with `chmod 600` (step 4).  
