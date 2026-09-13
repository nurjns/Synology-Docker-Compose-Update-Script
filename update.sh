#!/bin/bash
#
# Container Update Script - nurjns
# Version 1.0.0 - 2026-09-11
#
# Stops the containers per Docker Compose project (primarily via the
# Synology API, falling back to docker stop), pulls new images via
# 'compose pull', recreates the containers with 'compose up -d',
# and sends a status email with the full log.

set -o pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Project names = directory name under COMPOSE_BASE AND the value of the
# label com.docker.compose.project. Check with:
# sudo docker ps --format '{{.Label "com.docker.compose.project"}} {{.Names}}'
PROJECTS=(
	project1
	project2
	project3
)

COMPOSE_BASE="/volume1/docker" # docker-compose.yml (Container Manager)

BASE_DIR="/volume1/homes/admin/scripts" # this script's own directory: logs, lock, secrets, curl-smtp

SECRETS_DIR="$BASE_DIR/secrets"
LOGS_DIR="$BASE_DIR/logs/update"

# Synology's built-in curl only supports http/https, not smtp
CURL_SMTP_BIN="$BASE_DIR/curl-smtp"

# remove old, unused images after the update (dangling)
PRUNE_IMAGES=1

# Start behavior after the update:
#   1 = only start if the project was running before (default)
#   2 = always start
#   3 = do not update projects that are switched off
START_MODE=1

# SMTP server
SMTP_HOST="mailhost"
SMTP_PORT="587"
SMTP_USER="smtpuser@example.com"
SMTP_FROM="sender@example.com"
SMTP_TO="receiver@example.com"
SMTP_PASS_FILE="$SECRETS_DIR/smtp_password"

LOCKFILE="$BASE_DIR/update.lock"

mkdir -p "$LOGS_DIR"
LOGFILE="$LOGS_DIR/update-$(date +%Y-%m-%d_%H-%M-%S).log"

# clean up old logs (older than 365 days)
find "$LOGS_DIR" -name 'update-*.log' -mtime +365 -delete 2>/dev/null

OVERALL_STATUS="Success"
FAILED_PROJECTS=()

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

compose() {
	local project="$1"; shift
	"${DOCKER_COMPOSE[@]}" --project-directory "$COMPOSE_BASE/$project" -p "$project" "$@"
}

project_running_ids() {
	local project="$1"
	docker ps -a --filter "label=com.docker.compose.project=$project" --filter 'status=running' --format '{{.ID}}'
}

project_all_states() {
	local project="$1"
	docker ps -a --filter "label=com.docker.compose.project=$project" --format '{{.Names}}: {{.State}}'
}

# Look up the project UUID in Container Manager by name
project_id_lookup() {
	local project="$1"
	synowebapi --exec api=SYNO.Docker.Project version=1 method=list 2>/dev/null | jq -r --arg name "$project" '.data[] | select(.name == $name) | .id'
}

project_api_stop() {
	local id="$1"
	synowebapi --exec api=SYNO.Docker.Project version=1 method=stop "id=\"$id\""
}

send_mail() {
	local subject="$1"
	local mailfile="/tmp/update-mail-$$.txt"

	{
		echo "From: $SMTP_FROM"
		echo "To: $SMTP_TO"
		echo "Subject: $subject"
		echo "Content-Type: text/plain; charset=UTF-8"
		echo
		cat "$LOGFILE"
	} > "$mailfile"

	"$CURL_SMTP_BIN" --silent --show-error \
		--url "smtp://$SMTP_HOST:$SMTP_PORT" \
		--ssl-reqd \
		--mail-from "$SMTP_FROM" \
		--mail-rcpt "$SMTP_TO" \
		--upload-file "$mailfile" \
		--user "$SMTP_USER:$(cat "$SMTP_PASS_FILE")"

	rm -f "$mailfile"
}

# prefer docker compose (v2), fall back to docker-compose (v1)
if docker compose version > /dev/null 2>&1; then
	DOCKER_COMPOSE=(docker compose)
elif command -v docker-compose > /dev/null 2>&1; then
	DOCKER_COMPOSE=(docker-compose)
else
	mkdir -p "$LOGS_DIR"
	log "FATAL: Neither 'docker compose' nor 'docker-compose' was found."
	send_mail "[Failed] JNAS Container Update"
	exit 1
fi

# validate START_MODE (invalid -> default 1)
case "$START_MODE" in
	1|2|3) ;;
	*)
		log "WARNING: Invalid START_MODE '$START_MODE', using default (1)."
		START_MODE=1
		;;
esac

# Lock: prevents two runs from stopping/updating containers at the same time
if [ -e "$LOCKFILE" ]; then
	OLD_PID="$(cat "$LOCKFILE" 2>/dev/null)"
	if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
		log "Update is already running (PID $OLD_PID), aborting."
		exit 1
	fi
	log "Found stale lock file with dead PID $OLD_PID, ignoring it."
fi
echo $$ > "$LOCKFILE"

for cmd in synowebapi jq; do
	if ! command -v "$cmd" > /dev/null 2>&1; then
		log "FATAL: Required command '$cmd' was not found."
		send_mail "[Failed] JNAS Container Update"
		rm -f "$LOCKFILE"
		exit 1
	fi
done

# projects that were running before the update -> started again on abort/error
declare -A WAS_RUNNING

# Safety net: on abort/signal, restart everything that was running before.
# 'compose up -d' starts it with the (already pulled, if applicable) new image.
restart_all() {
	local project

	for project in "${!WAS_RUNNING[@]}"; do
		[ -n "$(project_running_ids "$project")" ] && continue

		log "Starting $project (recovery) ..."
		if ! compose "$project" up -d >> "$LOGFILE" 2>&1; then
			log "ERROR starting $project."
		fi
	done
}

cleanup_on_exit() {
	restart_all
	rm -f "$LOCKFILE"
}
trap cleanup_on_exit EXIT

# ---------------------------------------------------------------------------
# Stop projects (API first) + pull images + start them back up
# ---------------------------------------------------------------------------

for project in "${PROJECTS[@]}"; do
	compose_dir="$COMPOSE_BASE/$project"

	if [ ! -d "$compose_dir" ]; then
		log "ERROR: Compose directory $compose_dir does not exist - skipping $project entirely."
		FAILED_PROJECTS+=("$project (compose directory missing)")
		continue
	fi

	# remember the running state BEFORE touching anything
	if [ -n "$(project_running_ids "$project")" ]; then
		was_running=1
		WAS_RUNNING["$project"]=1
	else
		was_running=0
	fi

	# START_MODE 3: do not update projects that are switched off
	if [ "$was_running" -eq 0 ] && [ "$START_MODE" -eq 3 ]; then
		log "Project $project is off (START_MODE=3), skipping."
		continue
	fi

	# --- Stop (only if something is actually running) ---
	if [ "$was_running" -eq 1 ]; then
		pid="$(project_id_lookup "$project")"
		if [ -z "$pid" ]; then
			log "WARNING: Container Manager project ID for '$project' not found, stopping directly via docker."
		else
			log "Stopping project $project (ID $pid) ..."
			project_api_stop "$pid" >> "$LOGFILE" 2>&1
			sleep 1
		fi

		# fallback in case the API reports ok but something is actually still running
		if [ -n "$(project_running_ids "$project")" ]; then
			log "NOTE: $project is still running, stopping containers directly by ID."
			for id in $(project_running_ids "$project"); do
				if docker stop "$id" >> "$LOGFILE" 2>&1; then
					log "  stopped: $id"
				else
					log "  ERROR stopping $id"
				fi
			done
		fi

		tries=0
		while [ -n "$(project_running_ids "$project")" ]; do
			tries=$((tries + 1))
			if [ "$tries" -ge 6 ]; then
				log "ERROR: Project $project is still running after the stop attempt, skipping!"
				log "Container status $project: $(project_all_states "$project")"
				FAILED_PROJECTS+=("$project (won't stop)")
				break
			fi
			sleep 5
		done

		[ "$tries" -ge 6 ] && continue
	else
		log "Project $project was already stopped."
	fi

	# --- Pull new images ---
	log "Pulling new images for $project ..."
	if ! compose "$project" pull >> "$LOGFILE" 2>&1; then
		log "ERROR: 'compose pull' failed for $project."
		FAILED_PROJECTS+=("$project (pull failed)")
		# only start it back up if it was running before
		[ "$was_running" -eq 1 ] && compose "$project" up -d >> "$LOGFILE" 2>&1
		continue
	fi

	# --- Recreate the containers with the new image ---
	# Start if START_MODE=2 (always) or the project was running before.
	# Otherwise just recreate (--no-start), stays stopped.
	if [ "$START_MODE" -eq 2 ] || [ "$was_running" -eq 1 ]; then
		log "Creating/starting $project with the new image ..."
		if ! compose "$project" up -d >> "$LOGFILE" 2>&1; then
			log "ERROR: 'compose up -d' failed for $project."
			FAILED_PROJECTS+=("$project (up failed)")
			continue
		fi

		if [ -z "$(project_running_ids "$project")" ]; then
			log "ERROR: $project is not running after the update."
			log "Container status $project: $(project_all_states "$project")"
			FAILED_PROJECTS+=("$project (not running after update)")
		else
			log "Project $project updated successfully."
		fi
	else
		log "Creating $project with the new image, staying stopped (was off before) ..."
		if ! compose "$project" up --no-start >> "$LOGFILE" 2>&1; then
			log "ERROR: 'compose up --no-start' failed for $project."
			FAILED_PROJECTS+=("$project (up failed)")
			continue
		fi
		log "Project $project updated, staying stopped."
	fi
done

# ---------------------------------------------------------------------------
# Cleanup: remove old, unused images
# ---------------------------------------------------------------------------

if [ "$PRUNE_IMAGES" = '1' ]; then
	log "Removing unused images (docker image prune) ..."
	if ! docker image prune -f >> "$LOGFILE" 2>&1; then
		log "WARNING: 'docker image prune' failed."
	fi
fi

# ---------------------------------------------------------------------------
# Status / Mail
# ---------------------------------------------------------------------------

# containers have already been started explicitly above -> trap restart not needed
WAS_RUNNING=()
trap - EXIT
rm -f "$LOCKFILE"

if [ "${#FAILED_PROJECTS[@]}" -gt 0 ]; then
	OVERALL_STATUS="Failed"
	log "Failed projects: ${FAILED_PROJECTS[*]}"
fi

log "Overall status: $OVERALL_STATUS"
log "Log saved at: $LOGFILE"
send_mail "[$OVERALL_STATUS] JNAS Container Update"

if [ "$OVERALL_STATUS" = 'Failed' ]; then
	exit 1
fi
