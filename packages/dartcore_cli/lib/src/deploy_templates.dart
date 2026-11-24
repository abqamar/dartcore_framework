/// Templates for `dartcore deploy:init` (systemd unit, nginx site, install
/// script and README). Placeholders use the `{{key}}` syntax of [render].
library;

const systemdUnitT = r'''
[Unit]
Description={{name}} (DartCore API)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{user}}
Group={{user}}
WorkingDirectory=/opt/{{name}}
ExecStart=/opt/{{name}}/server
Restart=on-failure
RestartSec=3
# The server drains in-flight requests for up to 10 s after SIGTERM.
TimeoutStopSec=20
LimitNOFILE=65535

# Hardening
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/opt/{{name}}/storage

[Install]
WantedBy=multi-user.target
''';

const nginxConfT = r'''
# nginx site for {{name}}. Installed by install.sh --nginx into
# /etc/nginx/sites-available/{{name}} (and linked from sites-enabled).
# TLS: run `sudo certbot --nginx -d {{serverName}}` afterwards (needs a real domain).
server {
    listen 80;
    listen [::]:80;
    server_name {{serverName}};

    # Largest request body nginx accepts (uploads). Keep in sync with the
    # body limits of your DartCore app.
    client_max_body_size 10m;

    location / {
        proxy_pass http://127.0.0.1:{{port}};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
    }
}
''';

const installScriptT = r'''
#!/usr/bin/env bash
# Installs the {{name}} release bundle on an Ubuntu/Debian server.
# Run ON the server, as root, from the unpacked bundle:
#
#   sudo ./deploy/install.sh [--migrate] [--nginx] [--no-start]
#
# Safe to run again: it never overwrites an existing /opt/{{name}}/.env.
set -euo pipefail
umask 077

NAME="{{name}}"
SERVICE_USER="{{user}}"
PORT_DEFAULT="{{port}}"
DOMAIN="{{domain}}"
APP_DIR="/opt/${NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(dirname "${SCRIPT_DIR}")"
TOTAL=9
STEP=0
RUN_MIGRATE=0
USE_NGINX=0
START=1

usage() {
  cat <<EOF
Usage: sudo ./deploy/install.sh [options]

  --migrate    run "console migrate" (changes the database) before starting
  --nginx      install the nginx reverse-proxy site and reload nginx
  --no-start   install everything but do not (re)start the service
  -h, --help   show this help
EOF
}

step() {
  STEP=$((STEP + 1))
  printf '\n[%d/%d] %s\n' "${STEP}" "${TOTAL}" "$1"
}

info() { printf '      %s\n' "$1"; }
warn() { printf '      WARNING: %s\n' "$1" >&2; }

die() {
  printf '\nFAILED at step %d/%d: %s\n' "${STEP}" "${TOTAL}" "$1" >&2
  if [ "$#" -gt 1 ]; then
    printf 'What to do: %s\n' "$2" >&2
  fi
  printf 'Nothing is half-installed in a harmful way: fix the problem and run this script again.\n' >&2
  exit 1
}

on_error() {
  printf '\nFAILED at step %d/%d (script line %s). The command above printed the reason.\n' \
    "${STEP}" "${TOTAL}" "$1" >&2
  printf 'Fix the problem and run this script again; it is safe to repeat.\n' >&2
}
trap 'on_error "${LINENO}"' ERR

while [ "$#" -gt 0 ]; do
  case "$1" in
    --migrate) RUN_MIGRATE=1 ;;
    --nginx) USE_NGINX=1 ;;
    --no-start) START=0 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; printf '\nUnknown option: %s\n' "$1" >&2; exit 64 ;;
  esac
  shift
done

# Reads KEY from an env file (empty output when missing).
get_env() {
  local key="$1" file="$2"
  grep -m1 "^${key}=" "${file}" 2>/dev/null | cut -d= -f2- || true
}

# Sets KEY=VALUE in an env file (replaces the first match, else appends).
# The value is passed through the environment so no character needs escaping.
set_env() {
  local key="$1" value="$2" file="$3" tmp
  tmp="$(mktemp)"
  KEY="${key}" VAL="${value}" awk '
    BEGIN { FS = OFS = "="; k = ENVIRON["KEY"]; v = ENVIRON["VAL"]; done = 0 }
    $1 == k && !done { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "${file}" > "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

is_placeholder() {
  case "$1" in
    '' | CHANGE_ME | change_me | changeme | CHANGEME) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints the names of required values that are still missing in an env file.
missing_values() {
  local file="$1" key value
  for key in DB_HOST DB_DATABASE DB_USERNAME DB_PASSWORD; do
    value="$(get_env "${key}" "${file}")"
    if is_placeholder "${value}"; then printf '%s\n' "${key}"; fi
  done
  value="$(get_env JWT_SECRET "${file}")"
  if is_placeholder "${value}" || [ "${#value}" -lt 32 ]; then
    printf '%s\n' "JWT_SECRET (needs at least 32 characters)"
  fi
}

# ---------------------------------------------------------------------------
step "Checking this server and the bundle"
[ "${EUID}" -eq 0 ] || die "this script must run as root." "run it with: sudo ./deploy/install.sh"
for f in server console .env.example "deploy/${NAME}.service" deploy/nginx.conf; do
  [ -e "${BUNDLE_DIR}/${f}" ] || die "the bundle is incomplete: ${f} is missing in ${BUNDLE_DIR}." \
    "upload the whole build/release folder again (rsync -av build/release/ ...)."
done
command -v systemctl > /dev/null 2>&1 || die "systemd (systemctl) was not found." "this script supports Ubuntu/Debian with systemd."
command -v openssl > /dev/null 2>&1 || die "openssl is not installed." "run: sudo apt-get install -y openssl"
info "bundle: ${BUNDLE_DIR}"
info "no Dart SDK, git or pub is needed on this server."

# ---------------------------------------------------------------------------
step "Creating the service user '${SERVICE_USER}'"
if id -u "${SERVICE_USER}" > /dev/null 2>&1; then
  info "user already exists."
else
  useradd --system --user-group --home-dir "${APP_DIR}" --no-create-home \
    --shell /usr/sbin/nologin "${SERVICE_USER}"
  info "created system user ${SERVICE_USER} (no login shell)."
fi

# ---------------------------------------------------------------------------
step "Creating ${APP_DIR} and the data directory"
install -d -m 755 -o root -g root "${APP_DIR}"
install -d -m 755 -o root -g root "${APP_DIR}/deploy"
install -d -m 750 -o "${SERVICE_USER}" -g "${SERVICE_USER}" "${APP_DIR}/storage"
info "${APP_DIR}/storage is writable by ${SERVICE_USER} (uploads and other data)."

# ---------------------------------------------------------------------------
step "Copying the new version"
for bin in server console; do
  if [ -f "${APP_DIR}/${bin}" ]; then
    cp -p "${APP_DIR}/${bin}" "${APP_DIR}/${bin}.prev"
    info "kept the previous ${bin} as ${bin}.prev (for rollback)."
  fi
  # Copy next to the target, then rename: replacing a running binary in place fails.
  install -m 755 -o root -g root "${BUNDLE_DIR}/${bin}" "${APP_DIR}/${bin}.new"
  mv -f "${APP_DIR}/${bin}.new" "${APP_DIR}/${bin}"
done
install -m 644 -o root -g root "${BUNDLE_DIR}/.env.example" "${APP_DIR}/.env.example"
for f in "${NAME}.service" nginx.conf install.sh README.md; do
  if [ -f "${BUNDLE_DIR}/deploy/${f}" ]; then
    install -m 644 -o root -g root "${BUNDLE_DIR}/deploy/${f}" "${APP_DIR}/deploy/${f}"
  fi
done
chmod 755 "${APP_DIR}/deploy/install.sh" 2> /dev/null || true
info "installed server and console into ${APP_DIR}."

# ---------------------------------------------------------------------------
step "Checking the configuration file ${APP_DIR}/.env"
ENV_FILE="${APP_DIR}/.env"
if [ -d "${ENV_FILE}" ]; then
  die "${ENV_FILE} is a directory, not a file." "remove it (sudo rmdir '${ENV_FILE}') and run this script again."
fi
if [ -e "${ENV_FILE}" ]; then
  info "found an existing .env: it is left untouched (never overwritten)."
else
  info "no .env yet: creating one from .env.example."
  cp "${APP_DIR}/.env.example" "${ENV_FILE}"
  set_env APP_ENV production "${ENV_FILE}"
  set_env APP_DEBUG false "${ENV_FILE}"
  set_env APP_PORT "${PORT_DEFAULT}" "${ENV_FILE}"
  if [ "${USE_NGINX}" -eq 1 ]; then
    set_env APP_HOST 127.0.0.1 "${ENV_FILE}"
    set_env APP_TRUST_PROXY true "${ENV_FILE}"
  else
    set_env APP_HOST 0.0.0.0 "${ENV_FILE}"
  fi
  # Generate every secret placeholder (JWT_SECRET and any *_SECRET / *_KEY that is empty).
  while IFS= read -r key; do
    set_env "${key}" "$(openssl rand -base64 48 | tr -d '\n')" "${ENV_FILE}"
    info "generated a random value for ${key}."
  done < <({ awk -F= '/^[A-Z][A-Z0-9_]*(_SECRET|_KEY)=/ { v = $2; if (v == "" || v == "CHANGE_ME") print $1 }' "${ENV_FILE}"; echo JWT_SECRET; } | sort -u)
fi
chown "${SERVICE_USER}:${SERVICE_USER}" "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

MISSING="$(missing_values "${ENV_FILE}")"
if [ -n "${MISSING}" ]; then
  printf '\n----------------------------------------------------------------------\n'
  printf 'STOP: the new server is copied, but .env still needs values from you:\n\n'
  while IFS= read -r m; do printf '    - %s\n' "${m}"; done <<< "${MISSING}"
  printf '\nEdit the file (it is readable only by root and %s):\n\n' "${SERVICE_USER}"
  printf '    sudo nano %s\n\n' "${ENV_FILE}"
  printf 'Then run this script again with the same options. This stop is expected on a first install.\n'
  printf -- '----------------------------------------------------------------------\n'
  exit 3
fi
info ".env looks complete (mode 600, owner ${SERVICE_USER}). Secret values are not printed."
if [ "${USE_NGINX}" -eq 1 ] && [ "$(get_env APP_TRUST_PROXY "${ENV_FILE}")" != "true" ]; then
  warn "APP_TRUST_PROXY is not 'true' in .env; client IPs and rate limits will see nginx instead of real clients."
fi

# ---------------------------------------------------------------------------
step "Database migrations"
if [ "${RUN_MIGRATE}" -eq 1 ]; then
  info "running: console migrate (as ${SERVICE_USER}). This changes the database."
  command -v runuser > /dev/null 2>&1 || die "runuser was not found." "install util-linux (sudo apt-get install -y util-linux)."
  if ! (cd "${APP_DIR}" && runuser -u "${SERVICE_USER}" -- ./console migrate); then
    die "the migration failed; the service was not restarted." \
      "read the error above (usually a wrong DB_* value or an unreachable database), fix .env and run again."
  fi
else
  info "skipped (pass --migrate to run pending migrations). Check with: sudo -u ${SERVICE_USER} ${APP_DIR}/console migrate:status"
fi

# ---------------------------------------------------------------------------
step "Installing and starting the systemd service"
install -m 644 -o root -g root "${BUNDLE_DIR}/deploy/${NAME}.service" "/etc/systemd/system/${NAME}.service"
systemctl daemon-reload
systemctl enable "${NAME}.service" > /dev/null 2>&1
if [ "${START}" -eq 1 ]; then
  systemctl restart "${NAME}.service"
  info "service ${NAME} (re)started."
else
  info "service enabled but not started (--no-start)."
fi

# ---------------------------------------------------------------------------
step "nginx reverse proxy"
if [ "${USE_NGINX}" -eq 1 ]; then
  command -v nginx > /dev/null 2>&1 || die "nginx is not installed." "run: sudo apt-get install -y nginx   then run this script again."
  [ -d /etc/nginx/sites-available ] || die "/etc/nginx/sites-available does not exist." "this script expects the Debian/Ubuntu nginx layout."
  install -m 644 -o root -g root "${BUNDLE_DIR}/deploy/nginx.conf" "/etc/nginx/sites-available/${NAME}"
  ln -sf "/etc/nginx/sites-available/${NAME}" "/etc/nginx/sites-enabled/${NAME}"
  if ! nginx -t; then
    die "nginx rejected the configuration (see above); it was not reloaded." \
      "fix /etc/nginx/sites-available/${NAME} and run: sudo nginx -t && sudo systemctl reload nginx"
  fi
  systemctl reload nginx
  info "nginx site installed and reloaded."
  if [ -z "${DOMAIN}" ]; then
    info "no domain was set (server_name _). If you see the nginx welcome page, remove /etc/nginx/sites-enabled/default."
  else
    info "for HTTPS run: sudo certbot --nginx -d ${DOMAIN}"
  fi
else
  info "skipped (pass --nginx to install the reverse proxy)."
fi

# ---------------------------------------------------------------------------
step "Health check"
if [ "${START}" -ne 1 ]; then
  info "skipped (--no-start)."
elif ! command -v curl > /dev/null 2>&1; then
  warn "curl is not installed; check manually: systemctl status ${NAME}"
else
  PORT="$(get_env APP_PORT "${ENV_FILE}")"
  PORT="${PORT:-${PORT_DEFAULT}}"
  URL="http://127.0.0.1:${PORT}/health"
  OK=0
  for _ in $(seq 1 20); do
    if curl -fsS --max-time 3 "${URL}" > /dev/null 2>&1; then OK=1; break; fi
    sleep 1
  done
  if [ "${OK}" -eq 1 ]; then
    info "GET ${URL} -> $(curl -fsS --max-time 3 "${URL}")"
    printf '\nDone. %s is running.\n' "${NAME}"
  else
    printf '\n' >&2
    warn "the service did not answer at ${URL} within 20 seconds."
    warn "see why with: sudo journalctl -u ${NAME} -n 50 --no-pager"
    exit 1
  fi
fi
printf '\nUseful commands:\n'
printf '  sudo systemctl status %s\n  sudo journalctl -u %s -f\n' "${NAME}" "${NAME}"
''';

const deployReadmeT = r'''
# Deploying {{name}} to Ubuntu (no Docker, no Dart on the server)

This folder was generated by `dartcore deploy:init`. `dartcore build` copies it
into `build/release/deploy/` together with the compiled `server` and `console`
binaries and `.env.example`.

> `install.sh` was linted/syntax-checked and its logic was unit-tested, but it
> has not been executed on a real Ubuntu host by the DartCore authors. Read it
> (it is short) and try it on a throwaway server first.

## What the server needs

* Ubuntu 22.04+ / Debian 12+ with systemd, on the CPU architecture you built for
  (`--target linux-x64` or `linux-arm64`). Check with `uname -m`
  (`x86_64` = linux-x64, `aarch64` = linux-arm64).
* A PostgreSQL (or MySQL) database that the server can reach, with a database and
  user already created. The database can be on the same machine or remote.
* Optional: `nginx` (`sudo apt install nginx`) and `certbot` for HTTPS.
* NOT needed: Dart SDK, git, pub, Docker.

## First deployment

On your machine:

```bash
dartcore build                     # creates build/release/
rsync -av build/release/ user@host:~/{{name}}-release/
ssh -t user@host 'cd ~/{{name}}-release && sudo ./deploy/install.sh --migrate --nginx'
```

The first run creates `/opt/{{name}}/.env` with random secrets and then STOPS,
because only you know the database password. Edit it and run the same ssh
command again:

```bash
ssh -t user@host 'sudo nano /opt/{{name}}/.env'
ssh -t user@host 'cd ~/{{name}}-release && sudo ./deploy/install.sh --migrate --nginx'
```

What `install.sh` does (every step is printed as `[n/9]`): creates the `{{user}}`
system user, installs to `/opt/{{name}}`, never overwrites an existing `.env`
(mode 600, owned by `{{user}}`), runs `console migrate` only with `--migrate`,
installs and starts `{{name}}.service`, installs the nginx site only with
`--nginx`, and finally calls `GET /health`.

HTTPS: `sudo certbot --nginx -d {{domainOrExample}}` once DNS points at the server.

## Updating

Build again, upload again, run the same install command:

```bash
dartcore build
rsync -av build/release/ user@host:~/{{name}}-release/
ssh -t user@host 'cd ~/{{name}}-release && sudo ./deploy/install.sh --migrate'
```

The existing `.env` and `storage/` are kept. The previous binaries are saved as
`/opt/{{name}}/server.prev` and `/opt/{{name}}/console.prev`.

## Rolling back

Code only (fast):

```bash
ssh -t user@host 'cd /opt/{{name}} && sudo mv server.prev server && sudo mv console.prev console && sudo systemctl restart {{name}}'
```

If the new version ran migrations the old code cannot work with, roll the
database back first (this runs the `down()` of the last batch; check
`console migrate:status` before):

```bash
ssh -t user@host 'cd /opt/{{name}} && sudo -u {{user}} ./console migrate:rollback --force'
```

## Day to day

```bash
sudo systemctl status {{name}}
sudo journalctl -u {{name}} -f          # logs
sudo systemctl restart {{name}}
sudo -u {{user}} /opt/{{name}}/console migrate:status
```

Run `dartcore doctor` on your machine to validate the project's `.env` and database
before building.
''';
