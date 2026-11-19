#!/bin/bash

###############################################################################
# ORACLE HOST MIGRATION SCRIPT
#
# Version : 2.1
#
# Execute on NEW TARGET SERVER as root.
#
# Purpose:
#   1. Connect to old production server.
#   2. Backup multiple files/directories on source.
#   3. Store TAR archives in user-specified source backup directory.
#   4. Transfer archives using SCP.
#   5. Verify SHA256 checksums.
#   6. Extract archives only after validation.
#
###############################################################################

set -Eeuo pipefail

###############################################################################
# GLOBAL VARIABLES
###############################################################################

VERSION="2.1"

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

SOURCE_HOST=""
SOURCE_USER=""
BACKUP_DIR=""

EXECUTE=0
EXTRACT=0

STAGE=""
LOGDIR="/var/log/oracle_migration_transfer"
LOGFILE=""

declare -a MAPS=()

###############################################################################
# USAGE
###############################################################################

usage() {

cat <<'EOF'

==========================================================
ORACLE HOST MIGRATION SCRIPT
==========================================================

Usage:

oracle_host_migration.sh \
--source-host HOST \
--source-user USER \
--backup-dir SOURCE_BACKUP_DIRECTORY \
--map SOURCE_PATH=TARGET_DIRECTORY

OPTIONS:

--source-host HOST
    Old production server hostname.

--source-user USER
    SSH user on old production server.

--backup-dir DIR
    Backup directory on OLD production server.
    Mandatory.

--map SOURCE=TARGET
    Source file/directory and destination parent directory.
    Can be supplied multiple times.

--execute
    Create TAR backup and transfer using SCP.

--extract
    Extract transferred archives.
    Requires --execute in this initial version.

--help
    Display help.

EXAMPLE:

oracle_host_migration.sh \
--source-host dbprod01 \
--source-user oracle \
--backup-dir /backup/oracle_migration \
--map /opt/app/oracle/product/19CR3=/opt/app/oracle/product \
--map /opt/app/oracle/oraInventory=/opt/app/oracle \
--map /home/oracle/dba=/home/oracle

==========================================================

EOF

}

###############################################################################
# END OF PART 1
###############################################################################

###############################################################################
# PART 2 - ARGUMENT PARSING
###############################################################################

while [[ $# -gt 0 ]]; do

    case "$1" in

        --source-host)

            SOURCE_HOST="${2:?ERROR: Source host missing}"
            shift 2
            ;;

        --source-user)

            SOURCE_USER="${2:?ERROR: Source user missing}"
            shift 2
            ;;

        --backup-dir)

            BACKUP_DIR="${2:?ERROR: Backup directory missing}"
            shift 2
            ;;

        --map)

            MAPS+=("${2:?ERROR: Source=target mapping missing}")
            shift 2
            ;;

        --execute)

            EXECUTE=1
            shift
            ;;

        --extract)

            EXTRACT=1
            shift
            ;;

        --help)

            usage
            exit 0
            ;;

        *)

            echo "ERROR: Unknown argument: $1"
            usage
            exit 1
            ;;

    esac

done

###############################################################################
# MANDATORY ARGUMENT VALIDATION
###############################################################################

echo
echo "=========================================================="
echo "PART 2 - ARGUMENT VALIDATION"
echo "=========================================================="

# Source host

if [[ -z "$SOURCE_HOST" ]]; then

    echo "FAIL: Source host not provided."
    exit 1

fi

echo "[PASS] Source host: $SOURCE_HOST"

# Source user

if [[ -z "$SOURCE_USER" ]]; then

    echo "FAIL: Source user not provided."
    exit 1

fi

echo "[PASS] Source user: $SOURCE_USER"

# Backup directory

if [[ -z "$BACKUP_DIR" ]]; then

    echo "FAIL: Source backup directory not provided."
    echo "Use --backup-dir /backup/oracle_migration"
    exit 1

fi

if [[ ! "$BACKUP_DIR" =~ ^/[a-zA-Z0-9_./-]+$ ]] ||
   [[ "$BACKUP_DIR" == *"/../"* ]] ||
   [[ "$BACKUP_DIR" == */.. ]]; then

    echo "FAIL: Invalid backup directory: $BACKUP_DIR"
    exit 1

fi

echo "[PASS] Source backup directory: $BACKUP_DIR"

# Mapping validation

if [[ ${#MAPS[@]} -eq 0 ]]; then

    echo "FAIL: No source-to-target mapping provided."
    exit 1

fi

echo
echo "Validating source and target mappings..."

MAP_COUNT=0

for MAP in "${MAPS[@]}"; do

    MAP_COUNT=$((MAP_COUNT + 1))

    if [[ "$MAP" != *=* ]]; then

        echo "FAIL: Invalid mapping: $MAP"
        echo "Expected format: SOURCE_PATH=TARGET_DIRECTORY"
        exit 1

    fi

    SRC="${MAP%%=*}"
    DEST="${MAP#*=}"

    if [[ -z "$SRC" || -z "$DEST" ]]; then

        echo "FAIL: Empty source or destination in mapping."
        exit 1

    fi

    if [[ ! "$SRC" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then

        echo "FAIL: Invalid source path: $SRC"
        exit 1

    fi

    if [[ ! "$DEST" =~ ^/[a-zA-Z0-9_./-]+$ ]]; then

        echo "FAIL: Invalid target path: $DEST"
        exit 1

    fi

    case "$SRC" in
        *"/../"*|*/..|*/./*)

            echo "FAIL: Invalid source path traversal: $SRC"
            exit 1
            ;;
    esac

    case "$DEST" in
        *"/../"*|*/..|*/./*)

            echo "FAIL: Invalid target path traversal: $DEST"
            exit 1
            ;;
    esac

    echo "[PASS] Mapping $MAP_COUNT"
    echo "       SOURCE: $SRC"
    echo "       TARGET: $DEST"

done

echo
echo "Total mappings: $MAP_COUNT"

# Execution option validation

if [[ "$EXTRACT" -eq 1 && "$EXECUTE" -ne 1 ]]; then

    echo "FAIL: --extract requires --execute."
    exit 1

fi

echo
echo "[PASS] Execution arguments validated."

###############################################################################
# END OF PART 2
###############################################################################

###############################################################################
# PART 3 - ENVIRONMENT PREPARATION
###############################################################################

echo
echo "=========================================================="
echo "PART 3 - ENVIRONMENT PREPARATION"
echo "=========================================================="

###############################################################################
# ROOT VALIDATION
###############################################################################

if [[ "$EUID" -ne 0 ]]; then

    echo "FAIL: Script must run as root on target server."
    exit 1

fi

echo "[PASS] Running as root on target server."

###############################################################################
# REQUIRED COMMANDS ON TARGET
###############################################################################

echo
echo "Checking required commands on target..."

REQUIRED_COMMANDS=(
    ssh
    scp
    tar
    sha256sum
    df
    du
    realpath
    awk
    tee
)

for CMD in "${REQUIRED_COMMANDS[@]}"; do

    if ! command -v "$CMD" >/dev/null 2>&1; then

        echo "FAIL: Required command missing: $CMD"
        exit 1

    fi

    echo "[PASS] $CMD"

done

###############################################################################
# TARGET STAGING DIRECTORY
###############################################################################

STAGE="/var/tmp/oracle_migration_${TIMESTAMP}"

echo
echo "Preparing target staging directory..."

if [[ "$EXECUTE" -eq 1 ]]; then

    if [[ -e "$STAGE" ]]; then

        echo "FAIL: Target staging directory already exists:"
        echo "$STAGE"
        exit 1

    fi

    mkdir -p "$STAGE"
    chmod 700 "$STAGE"

    echo "[PASS] Target staging directory created:"
    echo "$STAGE"

else

    echo "[DRY RUN] Target staging directory would be:"
    echo "$STAGE"

fi

###############################################################################
# TARGET LOG DIRECTORY
###############################################################################

echo
echo "Preparing target log directory..."

if [[ "$EXECUTE" -eq 1 ]]; then

    mkdir -p "$LOGDIR"
    chmod 700 "$LOGDIR"

    LOGFILE="${LOGDIR}/migration_${TIMESTAMP}.log"

    touch "$LOGFILE"
    chmod 600 "$LOGFILE"

    echo "[PASS] Log directory prepared:"
    echo "$LOGDIR"

else

    echo "[DRY RUN] Log directory would be:"
    echo "$LOGDIR"

fi

###############################################################################
# SSH DESTINATION
###############################################################################

SSH_DEST="${SOURCE_USER}@${SOURCE_HOST}"

###############################################################################
# SSH CONNECTIVITY
###############################################################################

echo
echo "Checking SSH connectivity to source server..."

if ! ssh \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=yes \
    "$SSH_DEST" \
    "hostname"; then

    echo "FAIL: SSH connection unsuccessful."
    exit 1

fi
echo "[PASS] SSH connectivity verified."

###############################################################################
# SOURCE REQUIRED COMMANDS
###############################################################################

echo
echo "Checking required commands on source server..."

SOURCE_COMMANDS=(
    tar
    sha256sum
    df
    du
    realpath
    awk
)

for CMD in "${SOURCE_COMMANDS[@]}"; do

    if ! ssh "$SSH_DEST" \
        "command -v '$CMD' >/dev/null 2>&1"; then

        echo "FAIL: Required command missing on source: $CMD"
        exit 1

    fi

    echo "[PASS] Source command: $CMD"

done

###############################################################################
# SOURCE BACKUP DIRECTORY VALIDATION
###############################################################################

echo
echo "Validating source backup directory..."

if [[ "$EXECUTE" -eq 1 ]]; then

    ssh "$SSH_DEST" "
        set -e

        mkdir -p -- '$BACKUP_DIR'

        test -d '$BACKUP_DIR'
        test -w '$BACKUP_DIR'
        test -x '$BACKUP_DIR'

        df -h '$BACKUP_DIR'
    " || {

        echo "FAIL: Source backup directory is not writable."
        exit 1

    }

    echo "[PASS] Source backup directory verified."

else

    echo "[DRY RUN] Source backup directory:"
    echo "$BACKUP_DIR"

fi

###############################################################################
# SOURCE BACKUP FILESYSTEM INFORMATION
###############################################################################

if [[ "$EXECUTE" -eq 1 ]]; then

    echo
    echo "Source backup filesystem information:"

    ssh "$SSH_DEST" "
        df -h '$BACKUP_DIR'
    "

fi

###############################################################################
# TARGET FILESYSTEM INFORMATION
###############################################################################

echo
echo "Target staging filesystem information:"

if [[ "$EXECUTE" -eq 1 ]]; then

    df -h "$STAGE"

else

    echo "[DRY RUN] Target filesystem check deferred."

fi

###############################################################################
# PART 3 SUMMARY
###############################################################################

echo
echo "=========================================================="
echo "PART 3 ENVIRONMENT VALIDATION COMPLETED"
echo "=========================================================="

echo "Source Host     : $SOURCE_HOST"
echo "Source User     : $SOURCE_USER"
echo "Backup Location : $BACKUP_DIR"
echo "Target Staging  : $STAGE"
echo "Target Logs     : $LOGDIR"

echo
echo "[PASS] Environment preparation completed."

###############################################################################
# END OF PART 3
###############################################################################


