#!/bin/bash

set -euo pipefail

# We have to retry rcon quite often, so we have a function to encapsulate repeatedly attempting a command a given
# number of files with a given interval.
retry() {
	local retries="${1}"
	local interval="${2}"
	readonly retries interval
	shift 2

	local i=-1
	while ((retries >= ++i)); do
		if output="$(timeout --signal=SIGINT --kill-after=30s 5m "${@}" 2>&1 | tr '\n' '\t')"; then
			echo "Command executed successfully ${*}"
			return 0
		else
			echo "ERROR: unable to execute ${*} (attempt ${i}/${retries}. Retrying in ${interval}"
			if [ -n "${output}" ]; then
				echo "ERROR: Failure reason: ${output}"
			fi
		fi

		sleep ${interval}
	done
	return 2
}

init() {
	echo "Ensuring backup root directory: ${BACKUP_ROOT}"
	mkdir -p "${BACKUP_ROOT}"
}

BACKUP_SRC="/var/lib/docker/volumes/minecraft_data/_data"
BACKUP_ROOT="$HOME/banutama-mc-backups"

backup() {
	TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
	OUTFILE="${BACKUP_ROOT}/banutama-mc-backup-$1-${TIMESTAMP}.tar.gz"
	echo "Performing $1 backup: ${OUTFILE}"
	(cd "${BACKUP_SRC}" && {
		find . -type f -name "*.dat" -o -name "*.dat_old"
		find . -type f -not -name "*.dat" -not -name "*.dat_old"
	}) | command tar --gzip -cf "${OUTFILE}" -C "${BACKUP_SRC}" -T - || EXIT_CODE=$?
	if [ ${EXIT_CODE:-0} -eq 0 ]; then
		true
	elif [ ${EXIT_CODE:-0} -eq 1 ]; then
		echo "WARNING: dat files were changed during backup"
	elif [ ${EXIT_CODE:-0} -gt 1 ]; then
		echo "ERROR: tar exited with code ${EXIT_CODE}"
		exit 1
	fi

	echo "Creating link to latest backup: ${BACKUP_ROOT}/banutama-mc-backup-$1-latest.tar.gz"
	ln -sf "${OUTFILE}" "${BACKUP_ROOT}/banutama-mc-backup-$1-latest.tar.gz"
}

prune() {
	local interval="${1}"
	local limit=""

	case "${interval}" in
	hourly)
		limit=$(date -d '6 hours ago' '+%Y-%m-%d %H:00:00')
		;;
	daily)
		limit=$(date -d '7 days ago' '+%Y-%m-%d 00:00:00')
		;;
	*)
		echo "ERROR: invalid interval '${interval}' passed to prune()"
		;;
	esac

	echo "Deleting ${interval} backups older than ${limit} ..."
	find "${BACKUP_ROOT}" -name "banutama-mc-backup-${interval}-"'*' ! -newermt "${limit}" | while read file; do
		echo "Deleting old ${interval} backup: ${file}"
		rm "${file}"
	done
}

# -----------------------------------------------------------------------------------------------------------------
# Main entry point

INTERVAL="${1:-hourly}"
case "${INTERVAL}" in
hourly)
	echo "Performing hourly backup"
	;;
daily)
	echo "Performing daily backup"
	;;
*)
	echo "Unknown backup interval '${INTERVAL}'; falling back to hourly"
	INTERVAL="hourly"
	;;
esac

RCON_CLI="docker exec minecraft rcon-cli"
RCON_CLI_RETRIES=5
RCON_CLI_INTERVAL=10s

init

echo "Waiting for RCON ..."
retry ${RCON_CLI_RETRIES} ${RCON_CLI_INTERVAL} ${RCON_CLI} save-on

if retry ${RCON_CLI_RETRIES} ${RCON_CLI_INTERVAL} ${RCON_CLI} save-off; then
	# Make sure that when this script explodes, we turn saving on
	trap 'retry 5 5s ${RCON_CLI} save-on' EXIT

	retry ${RCON_CLI_RETRIES} ${RCON_CLI_INTERVAL} ${RCON_CLI} save-all flush
	retry ${RCON_CLI_RETRIES} ${RCON_CLI_INTERVAL} sync
	backup ${INTERVAL}

	# Turn saving back on, and clear our trap
	retry ${RCON_CLI_RETRIES} ${RCON_CLI_INTERVAL} ${RCON_CLI} save-on
	trap EXIT
else
	echo "ERROR: Unable to turn saving off. Is the server running?"
	exit 1
fi

prune ${INTERVAL}
