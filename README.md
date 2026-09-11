# Synology Docker Compose Update Script

Update Docker Compose projects on a Synology NAS through the official Container Manager API — no bare `docker compose` calls over SSH, no risk of the CLI disagreeing with what Container Manager actually has running. Stops each project (API first, `docker stop` as fallback), pulls new images, recreates the containers, and reports the result by email.

## Why

An update run that just does `compose pull && compose up -d` on a cron schedule has two problems on a Synology: it can start a project you deliberately shut down, and it never confirms that Container Manager's own view of the project matches reality before touching it. This script stops each project through the `SYNO.Docker.Project` API, falls back to a raw `docker stop` by container ID if the API call doesn't do what it should, and verifies the real state via `docker ps` before pulling or recreating anything.

## Features

- Stops each project via the Container Manager API, with a `docker stop` fallback and a `docker ps` verification loop before continuing
- Pulls new images per project (`compose pull`) and recreates the containers (`compose up -d`)
- Configurable start behavior after the update via `START_MODE` — see below; a project you stopped on purpose can stay stopped instead of being switched back on by the update
- Lock file with a stale-PID check, so overlapping runs can't stop each other's containers
- Status email (`[Success]`/`[Failed]`) with the full run log, sent via a self-contained static `curl` build (works around DSM's SMTP-less `curl`)
- Optional cleanup of dangling images after the run (`docker image prune`)
- Log rotation (logs older than 30 days are deleted on each run)

## Requirements

- DSM 7 with Container Manager (Docker) installed
- SSH access with an administrator account, root via `sudo -i`
- `jq` — used to resolve a project name to its Container Manager UUID
- `docker compose` v2, or `docker-compose` v1 as a fallback — auto-detected

## Installation

All binaries live in the script's own directory rather than `/usr/local/bin`, since that can be wiped by major DSM upgrades.

```bash
mkdir -p /volume1/homes/admin/scripts
cd /volume1/homes/admin/scripts
```

**curl with SMTP support** — DSM's bundled `curl` is built without SMTP. Grab a static build from [stunnel/static-curl](https://github.com/stunnel/static-curl/releases) (use the **musl** variant):
```bash
TAG="$(curl -s https://api.github.com/repos/stunnel/static-curl/releases/latest | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[^"]*"//; s/".*//')"
curl -LO "https://github.com/stunnel/static-curl/releases/download/$TAG/curl-linux-x86_64-musl-$TAG.tar.xz"
tar -xf "curl-linux-x86_64-musl-$TAG.tar.xz"
mv curl curl-smtp
chmod +x curl-smtp
./curl-smtp --version | grep -i smtp   # must list "smtp smtps"
```

Then place `update.sh` in the same directory and make it executable:
```bash
chmod +x update.sh
```

## Secrets

The SMTP password lives in its own subdirectory, root-only:

```bash
mkdir -p /volume1/homes/admin/scripts/secrets
echo 'your-smtp-password' > /volume1/homes/admin/scripts/secrets/smtp_password

sudo chown -R root:root /volume1/homes/admin/scripts/secrets
sudo chmod 700 /volume1/homes/admin/scripts/secrets
sudo chmod 600 /volume1/homes/admin/scripts/secrets/*
```

On Synology volumes, a plain `chmod` on a directory that carries a Windows-style ACL can leave a stale ACL entry that still grants access. Confirm with `ls -le secrets` — you want no `+` and no leftover ACL lines. If you see one, strip it explicitly:
```bash
sudo synoacltool -del /volume1/homes/admin/scripts/secrets
```

## SMTP setup

The included static `curl` talks SMTP directly — no mail relay or MTA needed. Fill in your own server:

```bash
SMTP_HOST="mailhost"
SMTP_PORT="587"
SMTP_USER="smtpuser@example.com"
SMTP_FROM="sender@example.com"
SMTP_TO="receiver@example.com"
```

Test it in isolation before trusting the full update run:
```bash
printf 'From: sender@example.com\nTo: receiver@example.com\nSubject: Test\n\nTest mail\n' > /tmp/test-mail.txt
./curl-smtp -v --url "smtp://mailhost:587" --ssl-reqd \
	--mail-from "sender@example.com" --mail-rcpt "receiver@example.com" \
	--upload-file /tmp/test-mail.txt --user "smtpuser@example.com:$(cat secrets/smtp_password)"
```
If your server uses implicit TLS instead of STARTTLS, use `smtps://host:465` instead of `smtp://host:587` with `--ssl-reqd`.

## Configuration

Edit the variables at the top of `update.sh`:

```bash
PROJECTS=(
	project1
	project2
)

COMPOSE_BASE="/volume1/docker"          # where each project's compose.yaml lives

BASE_DIR="/volume1/homes/admin/scripts" # this script's own directory: logs, lock, secrets, curl-smtp

PRUNE_IMAGES=1                          # remove dangling images after the run
START_MODE=1                            # see 'Start behavior' below
```

Each entry in `PROJECTS` must match the directory name under `COMPOSE_BASE` and the value Container Manager uses as the project name. Check the latter with:
```bash
sudo docker ps --format '{{.Label "com.docker.compose.project"}} {{.Names}}'
```

## Start behavior (`START_MODE`)

Controls what happens to a project after its update, based on whether it was running before the script touched it. An invalid value falls back to the default.

| Value | Behavior |
|---|---|
| `1` (default) | Only start projects that were already running. A project you stopped on purpose gets updated (new image pulled, container recreated) but stays stopped. |
| `2` | Always start every project after updating it, regardless of its previous state. |
| `3` | Skip stopped projects entirely — no pull, no update, no start. Only running projects are touched. |

## Scheduling

Use DSM's Task Scheduler rather than a hand-edited crontab:

*Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script*
- User: **root**
- Schedule: for example monthly, at night
- Custom script: `/volume1/homes/admin/scripts/update.sh`

Running as root avoids two separate headaches: your admin account doesn't need to be in the `docker` group, and you don't need `NOPASSWD` sudo rules for an unattended job.

Set up `update-curl.sh` the same way, on its own schedule — it keeps the static `curl-smtp` binary itself up to date (there's no upstream self-update for it, so this pulls the latest release from [stunnel/static-curl](https://github.com/stunnel/static-curl) via the GitHub API). The previous binary is kept as `curl-smtp.old` and restored automatically if the new one turns out broken or drops SMTP support, so a bad release can't take down your status emails.

## Usage

```bash
sudo ./update.sh
```

Runs unattended: stops the configured projects, updates them according to `START_MODE`, prunes dangling images if enabled, and sends a status email with the full log attached. Check `logs/update/` for individual run logs.

## Disclaimer

This project is an independent tool and is not affiliated, associated, authorized, endorsed by, or in any way officially connected with Synology Inc. or Pi-hole LLC, or any of their subsidiaries or affiliates.
