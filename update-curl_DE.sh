#!/bin/bash
#
# curl-smtp Update Script - nurjns
# Version 1.0.0 - 11.09.2026
#
# Aktualisiert die statische curl-smtp-Binary, die fuer den Versand der
# Status-Mails genutzt wird. Die bisherige Binary wird zuerst als
# curl-smtp.old gesichert. Laesst sich die aktualisierte Binary nicht mehr
# ausfuehren oder unterstuetzt kein SMTP mehr, wird automatisch die
# vorherige Version wiederhergestellt.
#
# Ausfuehrung: als root (DSM Task Scheduler, benutzerdefiniertes Skript)

set -o pipefail

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

BASE_DIR="/volume1/homes/admin/scripts" # gleiches Verzeichnis wie update.sh: Logs, Secrets, curl-smtp
SECRETS_DIR="$BASE_DIR/secrets"
LOGS_DIR="$BASE_DIR/logs/update-curl"

CURL_SMTP_BIN="$BASE_DIR/curl-smtp"

# Quelle fuer die statische curl-Binary
CURL_REPO='stunnel/static-curl'

# wird im Mail-Betreff verwendet: [Success]/[Failed] MAIL_SUBJECT_TAG
MAIL_SUBJECT_TAG="curl-smtp Update"

SMTP_HOST="mailhost"
SMTP_PORT="587"
SMTP_USER="smtpuser@example.com"
SMTP_FROM="sender@example.com"
SMTP_TO="receiver@example.com"
SMTP_PASS_FILE="$SECRETS_DIR/smtp_password"

mkdir -p "$LOGS_DIR"
LOGFILE="$LOGS_DIR/update-curl-$(date +%Y-%m-%d_%H-%M-%S).log"

find "$LOGS_DIR" -name 'update-curl-*.log' -mtime +365 -delete 2>/dev/null

OVERALL_STATUS="Success"
CHANGES=()

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

send_mail() {
	local subject="$1"
	local mailfile="/tmp/update-curl-mail-$$.txt"

	if [ ! -x "$CURL_SMTP_BIN" ]; then
		log "Keine funktionierende curl-smtp vorhanden - kann keine Mail versenden."
		return 1
	fi

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

# Prueft, ob eine Binary laeuft. Falls nicht, wird das .old-Backup wiederhergestellt.
verify_or_rollback() {
	local bin="$1"
	local name="$2"
	shift 2

	if "$bin" "$@" > /dev/null 2>&1; then
		return 0
	fi

	log "FEHLER: $name laesst sich nach dem Update nicht mehr ausfuehren."

	if [ -f "${bin}.old" ]; then
		if mv "${bin}.old" "$bin"; then
			log "Rollback auf die vorherige Version von $name durchgefuehrt."
		else
			log "FEHLER: Rollback von $name fehlgeschlagen - bitte manuell pruefen."
		fi
	else
		log "FEHLER: kein Backup ${bin}.old vorhanden - $name ist kaputt."
	fi

	OVERALL_STATUS="Failed"
	return 1
}

# ---------------------------------------------------------------------------
# Vorab-Pruefungen
# ---------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
	echo "Bitte als root ausfuehren."
	exit 1
fi

log "=== Update-Lauf gestartet ==="

# ---------------------------------------------------------------------------
# curl-smtp (kein Self-Update vorhanden, daher ueber die GitHub-API)
# ---------------------------------------------------------------------------

log "--- curl-smtp ---"

case "$(uname -m)" in
	x86_64)
		CURL_ARCH='x86_64'
		;;
	aarch64|arm64)
		CURL_ARCH='aarch64'
		;;
	*)
		CURL_ARCH=''
		log "FEHLER: unbekannte Architektur $(uname -m) - ueberspringe curl-smtp."
		OVERALL_STATUS="Failed"
		;;
esac

if [ -n "$CURL_ARCH" ]; then
	if [ -x "$CURL_SMTP_BIN" ]; then
		CURL_OLD_VER="$("$CURL_SMTP_BIN" --version 2>/dev/null | head -1 | awk '{print $2}')"
	else
		CURL_OLD_VER='(nicht vorhanden)'
	fi
	log "Aktuelle Version: $CURL_OLD_VER"

	# neueste Version ermitteln
	CURL_TAG="$(curl -s "https://api.github.com/repos/$CURL_REPO/releases/latest" | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[^"]*"//; s/".*//')"

	if [ -z "$CURL_TAG" ]; then
		log "FEHLER: konnte die neueste Version nicht ermitteln (GitHub-API nicht erreichbar?)."
		OVERALL_STATUS="Failed"
	elif [ "$CURL_TAG" = "$CURL_OLD_VER" ]; then
		log "Bereits aktuell ($CURL_OLD_VER)."
	else
		log "Neueste Version: $CURL_TAG"

		# WICHTIG: NICHT unter /tmp - DSM7 mountet /tmp als tmpfs mit noexec,
		# wodurch jede frisch heruntergeladene Binary trotz gesetztem
		# Ausfuehrungsbit nicht ausfuehrbar waere. BASE_DIR erlaubt exec nachweislich.
		TMPDIR_CURL="$(mktemp -d "$BASE_DIR/.curlupd.XXXXXX")"
		ARCHIVE="curl-linux-${CURL_ARCH}-musl-${CURL_TAG}.tar.xz"
		URL="https://github.com/$CURL_REPO/releases/download/$CURL_TAG/$ARCHIVE"

		log "Lade $URL herunter"
		if curl -sL -o "$TMPDIR_CURL/$ARCHIVE" "$URL" && tar -xf "$TMPDIR_CURL/$ARCHIVE" -C "$TMPDIR_CURL"; then
			NEW_CURL="$(find "$TMPDIR_CURL" -type f -name curl | head -1)"

			if [ -z "$NEW_CURL" ]; then
				log "FEHLER: keine curl-Datei im Archiv gefunden."
				OVERALL_STATUS="Failed"
			else
				# tar erhaelt das Ausfuehrungsbit nicht immer zuverlaessig,
				# daher vor dem Test explizit setzen
				chmod +x "$NEW_CURL"

				if ! CURL_TEST_OUTPUT="$("$NEW_CURL" --version 2>&1)"; then
					log "FEHLER: die neue Binary laesst sich nicht ausfuehren:"
					log "$CURL_TEST_OUTPUT"
					OVERALL_STATUS="Failed"
				elif ! echo "$CURL_TEST_OUTPUT" | grep -qi 'smtp'; then
					log "FEHLER: die neue Binary unterstuetzt kein SMTP - wird nicht uebernommen."
					OVERALL_STATUS="Failed"
				else
					if [ -x "$CURL_SMTP_BIN" ]; then
						cp -p "$CURL_SMTP_BIN" "${CURL_SMTP_BIN}.old"
					fi

					if cp "$NEW_CURL" "$CURL_SMTP_BIN" && chmod +x "$CURL_SMTP_BIN"; then
						if verify_or_rollback "$CURL_SMTP_BIN" 'curl-smtp' --version; then
							log "Aktualisiert: $CURL_OLD_VER -> $CURL_TAG"
							CHANGES+=("curl-smtp $CURL_OLD_VER -> $CURL_TAG")
						fi
					else
						log "FEHLER: konnte die neue Binary nicht installieren."
						OVERALL_STATUS="Failed"
					fi
				fi
			fi
		else
			log "FEHLER: Download oder Entpacken fehlgeschlagen."
			OVERALL_STATUS="Failed"
		fi

		rm -rf "$TMPDIR_CURL"
	fi
fi

# ---------------------------------------------------------------------------
# Ergebnis
# ---------------------------------------------------------------------------

if [ "${#CHANGES[@]}" -eq 0 ]; then
	log "Es wurden keine Updates durchgefuehrt."
else
	log "Updates: ${CHANGES[*]}"
	log "Die alte Binary bleibt als curl-smtp.old erhalten und kann nach einem erfolgreichen Lauf entfernt werden."
fi

log "Gesamtstatus: $OVERALL_STATUS"
send_mail "[$OVERALL_STATUS] $MAIL_SUBJECT_TAG"

if [ "$OVERALL_STATUS" = 'Failed' ]; then
	exit 1
fi