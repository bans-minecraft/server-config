#!/bin/bash

set -euo pipefail

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
                        echo "ERROR: unable to execute ${*} (attempt ${i}/${retries}. Retrying in ${interval})"
                        if [ -n "${output}" ]; then
                                echo "ERROR: failure reason: ${output}"
                        fi
                fi

                sleep ${interval}
        done
        return 2
}

init() {
        if [ ! -d "${BACKUP_ROOT}" ]; then
                echo "Ensuring backup root directory: ${BACKUP_ROOT}"
                mkdir -p "${BACKUP_ROOT}"

                echo "Initializing Borg backup repostiory: ${BACKUP_ROOT}"
                borg init --encryption=none "${BACKUP_ROOT}"
        }
}

BACKUP_SRC="/var/lib/docker/volumes/minecraft_data/_data"
BACKUP_ROOT="$HOME/borg-mc-backups"

backup() {
        TIMESTAMP=$(date +"%Y-%m-%d_%H:%M")
        echo "Performing backup: ${TIMESTAMP}"
        borg create --stats "${BACKUP_ROOT}"::"${TIMESTAMP}" "${BACKUP_SRC}"
}

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
        backup

        # Turn saving back on, and clear out the trap
        retry ${RCON_CLI_RETRIES} ${RCON_CLI_INTERVAL} ${RCON_CLI} save-on
        trap EXIT
else
        echo "ERROR: Unable to turn saving off. Is the server running?"
        exit 1
fi
