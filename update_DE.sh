#!/bin/bash
#
# Container Update Script - nurjns
# Version 1.0.0 - 10.09.2026
#
# Stoppt pro Docker-Compose-Projekt die Container (vorrangig ueber die
# Synology-API, mit Fallback auf docker stop), zieht neue Images per
# 'compose pull', erstellt die Container mit 'compose up -d' neu und
# verschickt eine Status-Mail mit vollem Log.

set -o pipefail

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

# Projektnamen = Ordnername unter COMPOSE_BASE UND Wert vom Label
# com.docker.compose.project. Pruefen mit:
# sudo docker ps --format '{{.Label "com.docker.compose.project"}} {{.Names}}'
PROJECTS=(
	project1
	project2
	project3
)

COMPOSE_BASE="/volume1/docker" # docker-compose.yml (Container Manager)

BASE_DIR="/volume1/homes/sa/scripts" # eigenes Script-Verzeichnis: Logs, Lock, Secrets, curl-smtp

SECRETS_DIR="$BASE_DIR/secrets"
LOGS_DIR="$BASE_DIR/logs/update"

# Synologys eingebauter curl unterstuetzt nur http/https, kein smtp
CURL_SMTP_BIN="$BASE_DIR/curl-smtp"

# alte, ungenutzte Images nach dem Update entfernen (dangling)
PRUNE_IMAGES=1

# Start-Verhalten nach dem Update:
#   1 = nur starten, wenn das Projekt vorher lief (Default)
#   2 = immer starten
#   3 = ausgeschaltete Projekte gar nicht aktualisieren
START_MODE=1

# SMTP-Server
SMTP_HOST="mailhost"
SMTP_PORT="587"
SMTP_USER="smtpuser@example.com"
SMTP_FROM="sender@example.com"
SMTP_TO="receiver@example.com"
SMTP_PASS_FILE="$SECRETS_DIR/smtp_password"

LOCKFILE="$BASE_DIR/update.lock"

mkdir -p "$LOGS_DIR"
LOGFILE="$LOGS_DIR/update-$(date +%Y-%m-%d_%H-%M-%S).log"

# alte Logs aufraeumen (aelter als 365 Tage)
find "$LOGS_DIR" -name 'update-*.log' -mtime +365 -delete 2>/dev/null

OVERALL_STATUS="Success"
FAILED_PROJECTS=()

# ---------------------------------------------------------------------------
# Hilfsfunktionen
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

# Projekt-UUID im Container Manager anhand des Namens ermitteln
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

# docker compose (v2) bevorzugt, sonst docker-compose (v1)
if docker compose version > /dev/null 2>&1; then
	DOCKER_COMPOSE=(docker compose)
elif command -v docker-compose > /dev/null 2>&1; then
	DOCKER_COMPOSE=(docker-compose)
else
	mkdir -p "$LOGS_DIR"
	log "FATAL: Weder 'docker compose' noch 'docker-compose' gefunden."
	send_mail "[Failed] JNAS Container-Update"
	exit 1
fi

# START_MODE validieren (ungueltig -> Default 1)
case "$START_MODE" in
	1|2|3) ;;
	*)
		log "WARNUNG: Ungueltiger START_MODE '$START_MODE', nutze Default (1)."
		START_MODE=1
		;;
esac

# Lock: verhindert, dass zwei Laeufe gleichzeitig Container stoppen/updaten
if [ -e "$LOCKFILE" ]; then
	OLD_PID="$(cat "$LOCKFILE" 2>/dev/null)"
	if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
		log "Update laeuft bereits (PID $OLD_PID), Abbruch."
		exit 1
	fi
	log "Alte Lock-Datei mit toter PID $OLD_PID gefunden, wird ignoriert."
fi
echo $$ > "$LOCKFILE"

for cmd in synowebapi jq; do
	if ! command -v "$cmd" > /dev/null 2>&1; then
		log "FATAL: Benoetigter Befehl '$cmd' wurde nicht gefunden."
		send_mail "[Failed] JNAS Container-Update"
		rm -f "$LOCKFILE"
		exit 1
	fi
done

# Projekte, die vor dem Update liefen -> bei Abbruch/Fehler wieder hoch
declare -A WAS_RUNNING

# Sicherheitsnetz: bei Abbruch/Signal alles wieder starten, was vorher lief.
# 'compose up -d' startet mit dem (ggf. schon gezogenen) neuen Image.
restart_all() {
	local project

	for project in "${!WAS_RUNNING[@]}"; do
		[ -n "$(project_running_ids "$project")" ] && continue

		log "Starte $project (Wiederherstellung) ..."
		if ! compose "$project" up -d >> "$LOGFILE" 2>&1; then
			log "FEHLER beim Starten von $project."
		fi
	done
}

cleanup_on_exit() {
	restart_all
	rm -f "$LOCKFILE"
}
trap cleanup_on_exit EXIT

# ---------------------------------------------------------------------------
# Projekte stoppen (API vorrangig) + Images ziehen + neu hochfahren
# ---------------------------------------------------------------------------

for project in "${PROJECTS[@]}"; do
	compose_dir="$COMPOSE_BASE/$project"

	if [ ! -d "$compose_dir" ]; then
		log "FEHLER: Compose-Ordner $compose_dir existiert nicht - ueberspringe $project."
		FAILED_PROJECTS+=("$project (Compose-Ordner fehlt)")
		continue
	fi

	# Laufstatus VOR dem Eingriff merken
	if [ -n "$(project_running_ids "$project")" ]; then
		was_running=1
		WAS_RUNNING["$project"]=1
	else
		was_running=0
	fi

	# START_MODE 3: ausgeschaltete Projekte nicht aktualisieren
	if [ "$was_running" -eq 0 ] && [ "$START_MODE" -eq 3 ]; then
		log "Projekt $project ist aus (START_MODE=3), wird uebersprungen."
		continue
	fi

	# --- Stoppen (nur wenn ueberhaupt was laeuft) ---
	if [ "$was_running" -eq 1 ]; then
		pid="$(project_id_lookup "$project")"
		if [ -z "$pid" ]; then
			log "WARNUNG: Container-Manager-Projekt-ID fuer '$project' nicht gefunden, stoppe direkt per docker."
		else
			log "Stoppe Projekt $project (ID $pid) ..."
			project_api_stop "$pid" >> "$LOGFILE" 2>&1
		fi

		# Fallback, falls die API-Antwort ok meldet, aber tatsaechlich noch was laeuft
		if [ -n "$(project_running_ids "$project")" ]; then
			log "HINWEIS: $project laeuft noch, stoppe Container direkt ueber die IDs."
			for id in $(project_running_ids "$project"); do
				if docker stop "$id" >> "$LOGFILE" 2>&1; then
					log "  gestoppt: $id"
				else
					log "  FEHLER beim Stoppen von $id"
				fi
			done
		fi

		tries=0
		while [ -n "$(project_running_ids "$project")" ]; do
			tries=$((tries + 1))
			if [ "$tries" -ge 6 ]; then
				log "FEHLER: Projekt $project laeuft nach Stop-Versuch immer noch, ueberspringe Update!"
				log "Container-Status $project: $(project_all_states "$project")"
				FAILED_PROJECTS+=("$project (stoppt nicht)")
				break
			fi
			sleep 5
		done

		[ "$tries" -ge 6 ] && continue
	else
		log "Projekt $project war bereits gestoppt."
	fi

	# --- Neue Images ziehen ---
	log "Ziehe neue Images fuer $project ..."
	if ! compose "$project" pull >> "$LOGFILE" 2>&1; then
		log "FEHLER: 'compose pull' fuer $project fehlgeschlagen."
		FAILED_PROJECTS+=("$project (pull fehlgeschlagen)")
		# nur wieder hochfahren, wenn es vorher lief
		[ "$was_running" -eq 1 ] && compose "$project" up -d >> "$LOGFILE" 2>&1
		continue
	fi

	# --- Container mit neuem Image neu erstellen ---
	# Starten, wenn START_MODE=2 (immer) oder das Projekt vorher lief.
	# Sonst nur neu erstellen (--no-start), bleibt gestoppt.
	if [ "$START_MODE" -eq 2 ] || [ "$was_running" -eq 1 ]; then
		log "Erstelle/starte $project mit neuem Image ..."
		if ! compose "$project" up -d >> "$LOGFILE" 2>&1; then
			log "FEHLER: 'compose up -d' fuer $project fehlgeschlagen."
			FAILED_PROJECTS+=("$project (up fehlgeschlagen)")
			continue
		fi

		if [ -z "$(project_running_ids "$project")" ]; then
			log "FEHLER: $project laeuft nach dem Update nicht."
			log "Container-Status $project: $(project_all_states "$project")"
			FAILED_PROJECTS+=("$project (laeuft nach Update nicht)")
		else
			log "Projekt $project erfolgreich aktualisiert."
		fi
	else
		log "Erstelle $project mit neuem Image, bleibt gestoppt (war vorher aus) ..."
		if ! compose "$project" up --no-start >> "$LOGFILE" 2>&1; then
			log "FEHLER: 'compose up --no-start' fuer $project fehlgeschlagen."
			FAILED_PROJECTS+=("$project (up fehlgeschlagen)")
			continue
		fi
		log "Projekt $project aktualisiert, bleibt gestoppt."
	fi
done

# ---------------------------------------------------------------------------
# Aufraeumen: alte, ungenutzte Images entfernen
# ---------------------------------------------------------------------------

if [ "$PRUNE_IMAGES" = '1' ]; then
	log "Entferne ungenutzte Images (docker image prune) ..."
	if ! docker image prune -f >> "$LOGFILE" 2>&1; then
		log "WARNUNG: 'docker image prune' fehlgeschlagen."
	fi
fi

# ---------------------------------------------------------------------------
# Status / Mail
# ---------------------------------------------------------------------------

# Container sind bereits explizit oben hochgefahren -> Trap-Neustart entbehrlich
WAS_RUNNING=()
trap - EXIT
rm -f "$LOCKFILE"

if [ "${#FAILED_PROJECTS[@]}" -gt 0 ]; then
	OVERALL_STATUS="Failed"
	log "Fehlgeschlagene Projekte: ${FAILED_PROJECTS[*]}"
fi

log "Gesamtstatus: $OVERALL_STATUS"
log "Log gespeichert unter: $LOGFILE"
send_mail "[$OVERALL_STATUS] JNAS Container-Update"

if [ "$OVERALL_STATUS" = 'Failed' ]; then
	exit 1
fi
