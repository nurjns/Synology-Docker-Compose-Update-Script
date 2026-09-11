#!/bin/bash
#
# curl-smtp Update Script - nurjns
# Version 1.0.0 - 2026-09-11
#
# Updates the static curl-smtp binary used for sending status emails.
# The previous binary is backed up as curl-smtp.old first. If the updated
# binary can no longer be executed or no longer supports SMTP, the previous
# version is restored automatically.
#
# Run as root (DSM Task Scheduler, user-defined script)

set -o pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BASE_DIR="/volume1/homes/admin/scripts" # same directory as update.sh: logs, secrets, curl-smtp
SECRETS_DIR="$BASE_DIR/secrets"
LOGS_DIR="$BASE_DIR/logs/update-curl"

CURL_SMTP_BIN="$BASE_DIR/curl-smtp"

# source for the static curl binary
CURL_REPO='stunnel/static-curl'

# used in the email subject: [Success]/[Failed] MAIL_SUBJECT_TAG
MAIL_SUBJECT_TAG="curl-smtp update"

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
# Helper functions
# ---------------------------------------------------------------------------

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

send_mail() {
	local subject="$1"
	local mailfile="/tmp/update-curl-mail-$$.txt"

	if [ ! -x "$CURL_SMTP_BIN" ]; then
		log "No working curl-smtp available - cannot send mail."
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

# Checks whether a binary runs. If not, the .old backup is restored.
verify_or_rollback() {
	local bin="$1"
	local name="$2"
	shift 2

	if "$bin" "$@" > /dev/null 2>&1; then
		return 0
	fi

	log "ERROR: $name can no longer be executed after the update."

	if [ -f "${bin}.old" ]; then
		if mv "${bin}.old" "$bin"; then
			log "Rolled back to the previous version of $name."
		else
			log "ERROR: rollback of $name failed - please check manually."
		fi
	else
		log "ERROR: no backup ${bin}.old available - $name is broken."
	fi

	OVERALL_STATUS="Failed"
	return 1
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
	echo "Please run as root."
	exit 1
fi

log "=== Update run started ==="

# ---------------------------------------------------------------------------
# curl-smtp (no self-update available, so this goes through the GitHub API)
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
		log "ERROR: unknown architecture $(uname -m) - skipping curl-smtp."
		OVERALL_STATUS="Failed"
		;;
esac

if [ -n "$CURL_ARCH" ]; then
	if [ -x "$CURL_SMTP_BIN" ]; then
		CURL_OLD_VER="$("$CURL_SMTP_BIN" --version 2>/dev/null | head -1 | awk '{print $2}')"
	else
		CURL_OLD_VER='(not present)'
	fi
	log "Current version: $CURL_OLD_VER"

	# determine the latest version
	CURL_TAG="$(curl -s "https://api.github.com/repos/$CURL_REPO/releases/latest" | grep -m1 '"tag_name"' | sed 's/.*"tag_name"[^"]*"//; s/".*//')"

	if [ -z "$CURL_TAG" ]; then
		log "ERROR: could not determine the latest version (GitHub API unreachable?)."
		OVERALL_STATUS="Failed"
	elif [ "$CURL_TAG" = "$CURL_OLD_VER" ]; then
		log "Already up to date ($CURL_OLD_VER)."
	else
		log "Latest version: $CURL_TAG"

		# IMPORTANT: NOT under /tmp - DSM7 mounts /tmp as tmpfs with noexec,
		# which would make any freshly downloaded binary unexecutable even
		# with the executable bit set. BASE_DIR is proven to allow exec.
		TMPDIR_CURL="$(mktemp -d "$BASE_DIR/.curlupd.XXXXXX")"
		ARCHIVE="curl-linux-${CURL_ARCH}-musl-${CURL_TAG}.tar.xz"
		URL="https://github.com/$CURL_REPO/releases/download/$CURL_TAG/$ARCHIVE"

		log "Downloading $URL"
		if curl -sL -o "$TMPDIR_CURL/$ARCHIVE" "$URL" && tar -xf "$TMPDIR_CURL/$ARCHIVE" -C "$TMPDIR_CURL"; then
			NEW_CURL="$(find "$TMPDIR_CURL" -type f -name curl | head -1)"

			if [ -z "$NEW_CURL" ]; then
				log "ERROR: no curl file found in the archive."
				OVERALL_STATUS="Failed"
			else
				# tar doesn't always preserve the executable bit reliably,
				# so set it explicitly before testing the binary
				chmod +x "$NEW_CURL"

				if ! CURL_TEST_OUTPUT="$("$NEW_CURL" --version 2>&1)"; then
					log "ERROR: the new binary cannot be executed:"
					log "$CURL_TEST_OUTPUT"
					OVERALL_STATUS="Failed"
				elif ! echo "$CURL_TEST_OUTPUT" | grep -qi 'smtp'; then
					log "ERROR: the new binary does not support SMTP - not adopting it."
					OVERALL_STATUS="Failed"
				else
					if [ -x "$CURL_SMTP_BIN" ]; then
						cp -p "$CURL_SMTP_BIN" "${CURL_SMTP_BIN}.old"
					fi

					if cp "$NEW_CURL" "$CURL_SMTP_BIN" && chmod +x "$CURL_SMTP_BIN"; then
						if verify_or_rollback "$CURL_SMTP_BIN" 'curl-smtp' --version; then
							log "Updated: $CURL_OLD_VER -> $CURL_TAG"
							CHANGES+=("curl-smtp $CURL_OLD_VER -> $CURL_TAG")
						fi
					else
						log "ERROR: could not install the new binary."
						OVERALL_STATUS="Failed"
					fi
				fi
			fi
		else
			log "ERROR: download or extraction failed."
			OVERALL_STATUS="Failed"
		fi

		rm -rf "$TMPDIR_CURL"
	fi
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

if [ "${#CHANGES[@]}" -eq 0 ]; then
	log "No updates were made."
else
	log "Updates: ${CHANGES[*]}"
	log "The old binary is kept alongside as curl-smtp.old and can be removed after a successful run."
fi

log "Overall status: $OVERALL_STATUS"
send_mail "[$OVERALL_STATUS] $MAIL_SUBJECT_TAG"

if [ "$OVERALL_STATUS" = 'Failed' ]; then
	exit 1
fi