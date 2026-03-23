#!/bin/bash
# =============================================================================
#  Exadata SnapClone Automation Script
#  Based on Oracle Documentation Section 9.7.4.2:
#  "Creating a Snapshot of a Full Database" (Single Full Database Copy)
#  https://docs.oracle.com/en/engineered-systems/exadata-database-machine/
#         sagug/creating-snapshot-full-database.html
#
#  Description : Automates all steps to create a sparse snapclone database
#                from a Test Master on Exadata using Direct NFS (dNFS) and
#                Oracle ASM Sparse Disk Groups.
#
#  Usage       : ./exadata_snapclone_create.sh [--config <config_file>]
#                Or edit the CONFIG section below directly.
#
#  Pre-requisites:
#    - Exadata with SPARSE ASM disk group configured
#    - Test Master DB is a physical standby or read-only DB (not in recovery)
#    - Oracle environment variables set (ORACLE_HOME, PATH, etc.)
#    - Run as oracle OS user with SYSDBA privileges
#    - asmcmd available
# =============================================================================

# -----------------------------------------------------------------------------
# EARLY ARGUMENT PARSE: --config sourced BEFORE set -euo pipefail and before
# any defaults are assigned, so config file values win over built-in defaults.
# Runs in a plain subshell-safe loop with no strict mode active yet.
# -----------------------------------------------------------------------------
for (( _ci=1; _ci<=$#; _ci++ )); do
    if [[ "${!_ci}" == "--config" ]]; then
        _cf_idx=$(( _ci + 1 ))
        _cf="${!_cf_idx}"
        if [[ ! -f "${_cf}" ]]; then
            echo "ERROR: Config file not found: ${_cf}" >&2
            exit 1
        fi
        # Source without strict mode so config files can use simple assignments
        source "${_cf}"
        echo "[INFO]  Config loaded: ${_cf}"
        unset _cf _cf_idx
        break
    fi
done
unset _ci

set -euo pipefail

# -----------------------------------------------------------------------------
# SECTION 1 - CONFIGURATION  (Edit these values for your environment,
#             OR override any variable via --config myenv.conf)
# -----------------------------------------------------------------------------

# Test Master database settings
TM_DB_NAME="${TM_DB_NAME:-TESTMASTER}"            # Test Master DB_NAME (uppercase)
TM_DB_UNIQUE_NAME="${TM_DB_UNIQUE_NAME:-TESTMASTER}"     # Test Master DB_UNIQUE_NAME
TM_ORACLE_SID="${TM_ORACLE_SID:-TESTMASTER1}"        # Test Master ORACLE_SID (instance name)
TM_DATA_DG="${TM_DATA_DG:-+DATA}"                 # Test Master data disk group

# Snapshot (clone) database settings
SNAP_DB_NAME="${SNAP_DB_NAME:-SNAPTEST}"            # Snapshot DB_NAME  (uppercase)
SNAP_DB_UNIQUE_NAME="${SNAP_DB_UNIQUE_NAME:-SNAPTEST}"     # Snapshot DB_UNIQUE_NAME
SNAP_ORACLE_SID="${SNAP_ORACLE_SID:-SNAPTEST1}"        # Snapshot instance ORACLE_SID
SNAP_SPARSE_DG="${SNAP_SPARSE_DG:-+SPARSE}"          # Sparse disk group for snapshot datafiles
SNAP_DATA_DG="${SNAP_DATA_DG:-+DATA}"              # Data disk group for controlfile/redo logs

# Oracle environment
ORACLE_HOME="${ORACLE_HOME:-/u01/app/oracle/product/19.0.0/dbhome_1}"
ORACLE_BASE="${ORACLE_BASE:-/u01/app/oracle}"
ORACLE_USER="${ORACLE_USER:-oracle}"

# Grid Infrastructure environment (ASM runs as grid user on Exadata)
# ASMCMD-8102 occurs when asmcmd is run as oracle instead of grid.
# Set GRID_HOME to the GI home (usually /u01/app/grid or /u01/app/19.x.x/grid)
GRID_HOME="${GRID_HOME:-/u01/app/grid/product/19.0.0/grid}"
GRID_USER="${GRID_USER:-grid}"
ASM_SID="${ASM_SID:-+ASM1}"

# How to execute ASM commands as the grid user when running this script as oracle.
# Options:
#   sudo   - uses 'sudo -u grid ...'  (requires sudoers entry, most common on Exadata)
#   ssh    - uses 'ssh grid@localhost' (requires passwordless SSH from oracle to grid)
#   direct - run directly (use when script is already run as grid user)
ASM_EXEC_METHOD="${ASM_EXEC_METHOD:-sudo}"

# SSH key for grid user (only used when ASM_EXEC_METHOD=ssh)
ASM_SSH_KEY="${ASM_SSH_KEY:-/home/oracle/.ssh/id_rsa}"
ASM_SSH_HOST="${ASM_SSH_HOST:-localhost}"

# Working directory for generated scripts and init files
WORK_DIR="${WORK_DIR:-${ORACLE_BASE}/admin/${SNAP_DB_NAME,,}/scripts}"
ADUMP_DIR="${ADUMP_DIR:-${ORACLE_BASE}/admin/${SNAP_DB_NAME,,}/adump}"

# Redo log settings for snapshot database (stored in DATA, NOT SPARSE)
REDO_SIZE="${REDO_SIZE:-100M}"
REDO_BLOCKSIZE="${REDO_BLOCKSIZE:-512}"
REDO_GROUPS="${REDO_GROUPS:-2}"

# Temp file size for snapshot TEMP tablespace
TEMP_SIZE="${TEMP_SIZE:-10G}"

# Whether the Test Master is a CDB (true/false)
IS_CDB="${IS_CDB:-false}"

# Control file location for snapshot
SNAP_CONTROL_FILE="${SNAP_CONTROL_FILE:-${SNAP_DATA_DG}/${SNAP_DB_NAME}/control1.f}"

# Snapshot clone index within the current Test Master generation.
# Appended as _T<N> to every sparse datafile destination name so you can
# identify which clone in the hierarchy each file belongs to and avoid
# filename collisions when creating multiple clones from the same TM.
#
#   T0  = first clone created from this generation of the Test Master
#   T1  = second clone from the same Test Master (created before any refresh)
#   T2  = third clone from the same Test Master, etc.
#
# When --refresh is run the Test Master becomes a new generation, so the
# index RESETS to 0 -- the first clone off the refreshed TM is always T0.
#
# During a plain creation run (no --refresh) the script auto-increments the
# index by reading/writing ${WORK_DIR}/.snap_index_counter so each additional
# clone from the same TM gets the next number without any manual bookkeeping.
#
# Override at any time: --snap-index N  or  SNAP_INDEX=N in your config file.
SNAP_INDEX="${SNAP_INDEX:-0}"

# Log file for this script's output
LOGFILE="${LOGFILE:-${WORK_DIR}/snapclone_$(date +%Y%m%d_%H%M%S).log}"

# -----------------------------------------------------------------------------
# SECTION 2 - UTILITY FUNCTIONS
# -----------------------------------------------------------------------------

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $*" | tee -a "${LOGFILE}"; }
success() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[OK]${NC}    $*" | tee -a "${LOGFILE}"; }
warn()    { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${NC}  $*" | tee -a "${LOGFILE}"; }
error()   { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ERROR]${NC} $*" | tee -a "${LOGFILE}"; exit 1; }
step()    { echo -e "\n${CYAN}${BOLD}==========================================${NC}"; \
            echo -e "${CYAN}${BOLD}  STEP $*${NC}"; \
            echo -e "${CYAN}${BOLD}==========================================${NC}" | tee -a "${LOGFILE}"; }

run_sqlplus_tm() {
    # Run SQL against the Test Master DB
    ORACLE_SID="${TM_ORACLE_SID}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba <<EOF
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET TRIMSPOOL ON
$1
EXIT
EOF
}

run_sqlplus_snap() {
    # Run SQL against the Snapshot DB
    ORACLE_SID="${SNAP_ORACLE_SID}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba <<EOF
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET TRIMSPOOL ON
$1
EXIT
EOF
}

run_sqlplus_snap_verbose() {
    ORACLE_SID="${SNAP_ORACLE_SID}" "${ORACLE_HOME}/bin/sqlplus" / as sysdba <<EOF
$1
EXIT
EOF
}

# Run an asmcmd command as the grid OS user.
# On Exadata, ASM runs under the 'grid' user; running asmcmd as 'oracle'
# causes ASMCMD-8102 (no ASM instance connection).
# Usage: run_asmcmd "mkdir -p +SPARSE/SNAPTEST/DATAFILE"
# ---------------------------------------------------------------------------
# run_as_grid CMD
#   Executes CMD in a shell under the grid OS user.
#   Method is controlled by ASM_EXEC_METHOD (sudo | ssh | direct).
# ---------------------------------------------------------------------------
run_as_grid() {
    local cmd="$1"
    case "${ASM_EXEC_METHOD}" in
        sudo)
            # Requires sudoers: oracle ALL=(grid) NOPASSWD: /bin/bash
            # Or the broader Exadata default allowing sudo to grid
            sudo -u "${GRID_USER}" bash -c "${cmd}"
            ;;
        ssh)
            # Requires passwordless SSH: oracle -> grid@localhost
            # Setup once: ssh-copy-id -i ${ASM_SSH_KEY} ${GRID_USER}@${ASM_SSH_HOST}
            ssh -n -i "${ASM_SSH_KEY}" \
                -o BatchMode=yes \
                -o StrictHostKeyChecking=no \
                "${GRID_USER}@${ASM_SSH_HOST}" "${cmd}"
            ;;
        direct)
            # Script is already running as grid user
            bash -c "${cmd}"
            ;;
        *)
            error "Unknown ASM_EXEC_METHOD: '${ASM_EXEC_METHOD}'. Use: sudo | ssh | direct"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# asmcmd_mkdir PATH
#   Creates an ASM directory path level by level.
#   asmcmd does NOT support mkdir -p; each level must exist before the next.
#   Silently skips levels that already exist (ASMCMD-9456 / -8016).
# ---------------------------------------------------------------------------
asmcmd_mkdir() {
    local full_path="$1"
    local asmcmd_bin="${GRID_HOME}/bin/asmcmd"
    [[ -x "${asmcmd_bin}" ]] || asmcmd_bin="${ORACLE_HOME}/bin/asmcmd"

    # Strip leading + and split on /
    local stripped="${full_path#+}"
    local IFS='/'
    local parts=( ${stripped} )
    unset IFS

    local current_path=""
    local part rc output tmpf

    for part in "${parts[@]}"; do
        [[ -z "${part}" ]] && continue
        if [[ -z "${current_path}" ]]; then
            current_path="+${part}"
        else
            current_path="${current_path}/${part}"
        fi

        tmpf=$(mktemp /tmp/asmcmd_XXXXXX.cmd)
        printf 'mkdir %s
' "${current_path}" > "${tmpf}"
        chmod 644 "${tmpf}"

        log "  asmcmd mkdir ${current_path}"
        output=$(run_as_grid "ORACLE_SID=${ASM_SID} ${asmcmd_bin} < ${tmpf}" 2>&1)
        rc=$?
        rm -f "${tmpf}"

        # asmcmd exits 0 even on errors -- check output for error codes
        if echo "${output}" | grep -qE "ASMCMD-[0-9]+"; then
            # ASMCMD-9456 = directory already exists -> OK to ignore
            # ASMCMD-8016 = object already exists   -> OK to ignore
            if echo "${output}" | grep -qE "ASMCMD-(9456|8016)"; then
                log "  ${current_path} already exists -- skipping"
            else
                echo "${output}" | tee -a "${LOGFILE}"
                error "asmcmd mkdir failed for ${current_path}. See error above."
            fi
        else
            log "  ${current_path} created OK"
        fi
    done
}

# ---------------------------------------------------------------------------
# run_asmcmd COMMAND
#   Runs a single asmcmd command as the grid user and validates output.
#   Fails hard on any ASMCMD- error in the output.
# ---------------------------------------------------------------------------
run_asmcmd() {
    local asmcmd_cmd="$1"
    local asmcmd_bin="${GRID_HOME}/bin/asmcmd"

    if [[ ! -x "${asmcmd_bin}" ]]; then
        warn "asmcmd not found at ${GRID_HOME}/bin/asmcmd -- trying ${ORACLE_HOME}/bin/asmcmd"
        asmcmd_bin="${ORACLE_HOME}/bin/asmcmd"
        [[ -x "${asmcmd_bin}" ]] || error "asmcmd not found in GRID_HOME or ORACLE_HOME"
    fi

    log "run_asmcmd [${ASM_EXEC_METHOD}]: ${asmcmd_cmd}"

    local tmpf output rc
    tmpf=$(mktemp /tmp/asmcmd_XXXXXX.cmd)
    printf '%s\n' "${asmcmd_cmd}" > "${tmpf}"
    chmod 644 "${tmpf}"

    output=$(run_as_grid "ORACLE_SID=${ASM_SID} ${asmcmd_bin} < ${tmpf}" 2>&1)
    rc=$?
    rm -f "${tmpf}"

    # Always print output to log
    [[ -n "${output}" ]] && echo "${output}" | tee -a "${LOGFILE}"

    # asmcmd returns 0 even on errors -- check output for ASMCMD- codes
    if echo "${output}" | grep -qE "ASMCMD-[0-9]+"; then
        error "asmcmd command failed: ${asmcmd_cmd}\nSee ASMCMD error above."
    fi

    if [[ ${rc} -ne 0 ]]; then
        error "asmcmd exited with code ${rc} for command: ${asmcmd_cmd}"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# run_sqlplus_asm SQL
#   Runs SQL as sysasm (grid user) for ALTER DISKGROUP statements.
# ---------------------------------------------------------------------------
run_sqlplus_asm() {
    local sql="$1"
    local sqlplus_bin="${GRID_HOME}/bin/sqlplus"

    if [[ ! -x "${sqlplus_bin}" ]]; then
        sqlplus_bin="${ORACLE_HOME}/bin/sqlplus"
    fi

    local tmpf
    tmpf=$(mktemp /tmp/sysasm_XXXXXX.sql)
    printf '%s\nEXIT\n' "${sql}" > "${tmpf}"
    chmod 644 "${tmpf}"

    log "run_sqlplus_asm [${ASM_EXEC_METHOD}]: executing SQL as sysasm"
    local asm_out asm_rc
    asm_out=$(run_as_grid "ORACLE_SID=${ASM_SID} ${sqlplus_bin} -S / as sysasm @${tmpf}" 2>&1)
    asm_rc=$?
    rm -f "${tmpf}"
    [[ -n "${asm_out}" ]] && echo "${asm_out}" | tee -a "${LOGFILE}"
    if [[ ${asm_rc} -ne 0 ]]; then
        error "run_sqlplus_asm: sqlplus sysasm exited with code ${asm_rc}"
    fi
    if echo "${asm_out}" | grep -qE "^ORA-[0-9]+|^SP2-[0-9]+"; then
        error "run_sqlplus_asm: Oracle error detected in sysasm output. See above."
    fi
    return 0
}


# ---------------------------------------------------------------------------
# sqlplus_check SID SQL [LABEL]
#   Runs SQL silently, captures all output, fails on ORA-/SP2- in output.
#   Echoes output to log and returns it for callers that need to parse it.
# ---------------------------------------------------------------------------
sqlplus_check() {
    local sid="$1" sql="$2" label="${3:-sqlplus}"
    local out rc
    out=$(ORACLE_SID="${sid}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba 2>&1 <<EOF
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET TRIMSPOOL ON
SET WRAP OFF
${sql}
EXIT
EOF
)
    rc=$?
    [[ -n "${out}" ]] && echo "${out}" | tee -a "${LOGFILE}"
    if [[ ${rc} -ne 0 ]]; then
        error "[${label}] sqlplus exited with code ${rc}"
    fi
    if echo "${out}" | grep -qE "^ORA-[0-9]+|^SP2-[0-9]+|^ERROR at line [0-9]"; then
        error "[${label}] Oracle error detected in sqlplus output. See above."
    fi
    echo "${out}"
}

# ---------------------------------------------------------------------------
# sqlplus_verbose_check SID SQL [LABEL]
#   Like sqlplus_check but with ECHO/FEEDBACK ON for DDL/STARTUP/SHUTDOWN.
# ---------------------------------------------------------------------------
sqlplus_verbose_check() {
    local sid="$1" sql="$2" label="${3:-sqlplus}"
    local out rc
    out=$(ORACLE_SID="${sid}" "${ORACLE_HOME}/bin/sqlplus" / as sysdba 2>&1 <<EOF
${sql}
EXIT
EOF
)
    rc=$?
    [[ -n "${out}" ]] && echo "${out}" | tee -a "${LOGFILE}"
    if [[ ${rc} -ne 0 ]]; then
        error "[${label}] sqlplus exited with code ${rc}"
    fi
    if echo "${out}" | grep -qE "^ORA-[0-9]+|^SP2-[0-9]+|^ERROR at line [0-9]"; then
        error "[${label}] Oracle error detected. See above."
    fi
    echo "${out}"
}

# ---------------------------------------------------------------------------
# rman_check SID CMDS [LABEL]
#   Runs RMAN commands, captures output, fails hard on RMAN-/ORA- errors.
# ---------------------------------------------------------------------------
rman_check() {
    local sid="$1" cmds="$2" label="${3:-rman}"
    local out rc
    out=$(ORACLE_SID="${sid}" "${ORACLE_HOME}/bin/rman" target / 2>&1 <<EOF
${cmds}
EOF
)
    rc=$?
    [[ -n "${out}" ]] && echo "${out}" | tee -a "${LOGFILE}"
    if [[ ${rc} -ne 0 ]]; then
        error "[${label}] RMAN exited with code ${rc}"
    fi
    if echo "${out}" | grep -qE "^RMAN-[0-9]+|^ORA-[0-9]+"; then
        error "[${label}] RMAN/Oracle error detected. See above."
    fi
    echo "${out}"
}

# ---------------------------------------------------------------------------
# dgmgrl_check CMDS [LABEL]
#   Runs DGMGRL commands, captures output, fails hard on ORA-/DGM- errors.
# ---------------------------------------------------------------------------
dgmgrl_check() {
    local cmds="$1" label="${2:-dgmgrl}"
    local out rc
    out=$("${ORACLE_HOME}/bin/dgmgrl" / 2>&1 <<EOF
CONNECT /;
${cmds}
EXIT;
EOF
)
    rc=$?
    [[ -n "${out}" ]] && echo "${out}" | tee -a "${LOGFILE}"
    if [[ ${rc} -ne 0 ]]; then
        error "[${label}] dgmgrl exited with code ${rc}"
    fi
    if echo "${out}" | grep -qiE "^ORA-[0-9]+|^DGM-[0-9]+|^Error:"; then
        error "[${label}] DGMGRL error detected. See above."
    fi
    echo "${out}"
}

# ---------------------------------------------------------------------------
# verify_db_status SID EXPECTED [LABEL]
#   Queries V$INSTANCE STATUS and asserts it matches EXPECTED. Fails hard if not.
# ---------------------------------------------------------------------------
verify_db_status() {
    local sid="$1" expected="$2" label="${3:-db}"
    local actual
    actual=$(ORACLE_SID="${sid}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba 2>/dev/null <<EOF | tr -d ' \n\r'
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SELECT STATUS FROM V\$INSTANCE;
EXIT
EOF
)
    if [[ "${actual}" != "${expected}" ]]; then
        error "[${label}] Expected DB status '${expected}' but found '${actual}'"
    fi
    log "[${label}] DB status confirmed: ${actual}"
}

check_prerequisites() {
    step "0 - Checking Prerequisites"

    # Check Oracle binaries
    [[ -x "${ORACLE_HOME}/bin/sqlplus" ]] || error "sqlplus not found at ${ORACLE_HOME}/bin/sqlplus"
    # Check asmcmd binary
    if [[ ! -x "${GRID_HOME}/bin/asmcmd" ]] && [[ ! -x "${ORACLE_HOME}/bin/asmcmd" ]]; then
        error "asmcmd not found in GRID_HOME (${GRID_HOME}/bin) or ORACLE_HOME (${ORACLE_HOME}/bin)"
    fi
    [[ ! -x "${GRID_HOME}/bin/asmcmd" ]] &&         warn "GRID_HOME/bin/asmcmd not found -- will fall back to ORACLE_HOME/bin/asmcmd"

    # Validate the chosen ASM execution method
    log "ASM execution method: ${ASM_EXEC_METHOD}"
    case "${ASM_EXEC_METHOD}" in
        sudo)
            if ! sudo -u "${GRID_USER}" -n true 2>/dev/null; then
                error "sudo -u ${GRID_USER} failed. Add sudoers entry:\n  $(whoami) ALL=(${GRID_USER}) NOPASSWD: /bin/bash"
            fi
            success "sudo access to ${GRID_USER}: OK"
            ;;
        ssh)
            if ! ssh -n -i "${ASM_SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=5                     -o StrictHostKeyChecking=no "${GRID_USER}@${ASM_SSH_HOST}" true 2>/dev/null; then
                error "SSH to ${GRID_USER}@${ASM_SSH_HOST} failed. Run:\n  ssh-copy-id -i ${ASM_SSH_KEY} ${GRID_USER}@${ASM_SSH_HOST}"
            fi
            success "SSH to ${GRID_USER}@${ASM_SSH_HOST}: OK"
            ;;
        direct)
            if [[ "$(whoami)" != "${GRID_USER}" ]]; then
                warn "ASM_EXEC_METHOD=direct but running as $(whoami), not ${GRID_USER}. asmcmd may fail."
            fi
            ;;
    esac

    # Check running as oracle user
    [[ "$(whoami)" == "${ORACLE_USER}" ]] || warn "Script not running as ${ORACLE_USER} -- ensure SYSDBA access is available"

    # Create work directory
    mkdir -p "${WORK_DIR}" "${ADUMP_DIR}"
    log "Working directory : ${WORK_DIR}"
    log "Audit directory   : ${ADUMP_DIR}"

    # Verify Test Master DB is accessible and OPEN
    local tm_status
    tm_status=$(ORACLE_SID="${TM_ORACLE_SID}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba 2>/dev/null <<EOF | tr -d ' \n\r'
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SELECT STATUS FROM V\$INSTANCE;
EXIT
EOF
) || error "Cannot connect to Test Master (${TM_ORACLE_SID}). Is it running?"
    [[ -n "${tm_status}" ]] || error "No output from V\$INSTANCE on ${TM_ORACLE_SID} -- DB may be down"
    log "Test Master status: ${tm_status}"
    [[ "${tm_status}" == "OPEN" ]] || error "Test Master is not OPEN. Status: '${tm_status}'"

    success "Prerequisites passed"
}

# -----------------------------------------------------------------------------
# SECTION 3 - STEP 1: Backup Control File to Trace (Test Master)
# -----------------------------------------------------------------------------

step1_backup_controlfile_trace() {
    step "1 - Backup Control File to Trace (Test Master)"

    log "Triggering ALTER DATABASE BACKUP CONTROLFILE TO TRACE on ${TM_ORACLE_SID}..."
    local step1_out trace_file
    step1_out=$(sqlplus_check "${TM_ORACLE_SID}" "
ALTER DATABASE BACKUP CONTROLFILE TO TRACE;
SELECT value FROM v\$diag_info WHERE name = 'Default Trace File';" "step1-backup-ctlfile")

    # Extract trace path: last non-blank line of output
    trace_file=$(echo "${step1_out}" | grep -v '^$' | tail -1 | tr -d ' ')
    [[ -n "${trace_file}" ]] || error "step1: Could not parse trace file path from sqlplus output"
    [[ -f "${trace_file}" ]] || error "step1: Trace file does not exist: '${trace_file}'"
    log "Trace file: ${trace_file}"

    cp "${trace_file}" "${WORK_DIR}/controlfile_trace.trc"
    [[ -s "${WORK_DIR}/controlfile_trace.trc" ]] || error "step1: Copied trace file is empty"
    success "Control file backup to trace: ${WORK_DIR}/controlfile_trace.trc"
}

# -----------------------------------------------------------------------------
# SECTION 4 - STEP 2: Generate rename_files.sql (Test Master)
# -----------------------------------------------------------------------------

step2_generate_rename_script() {
    step "2 - Generate rename_files.sql (Test Master Datafile Mapping)"

    # SNAP_INDEX tracks which clone number this is within the current Test Master
    # generation.  T0 = first clone off this TM, T1 = second clone off the same TM,
    # etc.  When the TM is refreshed the index resets to 0 (new generation).
    # Auto-increment happens in the creation path; refresh resets via R6.
    log "Snapshot clone index : T${SNAP_INDEX}"
    log "  Source  DG : ${TM_DATA_DG}"
    log "  Dest    DG : ${SNAP_SPARSE_DG}"
    log "  Suffix     : _T${SNAP_INDEX}"

    local rename_sql="${WORK_DIR}/rename_files.sql"
    log "Generating ${rename_sql} ..."

    # Strip the leading '+' from both disk group names for the REPLACE() calls,
    # because v$datafile paths look like: +DATA/DBNAME/DATAFILE/...
    # We match on the bare group name followed by '/', e.g. 'DATA/'
    local src_dg_bare dst_dg_bare
    src_dg_bare="${TM_DATA_DG#+}/"       # e.g. "DATA/"
    dst_dg_bare="${SNAP_SPARSE_DG#+}/"   # e.g. "SPARSE/"

    sqlplus_check "${TM_ORACLE_SID}" "
SET NEWPAGE 0
SET LINESIZE 999
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET ECHO OFF
SET SPACE 0
SET TAB OFF
SET TRIMSPOOL ON
SPOOL ${rename_sql}
SELECT 'EXECUTE dbms_dnfs.clonedb_renamefile(' ||
       '''' || name || '''' || ',' ||
       '''' || REPLACE(
                 REPLACE(name, '.', '_'),
                 '${src_dg_bare}', '${dst_dg_bare}') ||
       '_T${SNAP_INDEX}' || ''');'
FROM v\$datafile;
SPOOL OFF" "step2-spool" > /dev/null

    # Remove blank lines and any sqlplus prompt lines that crept into the spool
    sed -i '/^[[:space:]]*$/d;/^SQL>/d;/^Disconnected/d' "${rename_sql}" 2>/dev/null || true

    [[ -f "${rename_sql}" ]] || error "step2: rename_files.sql was not created by SPOOL"
    # Fail if spool contains ORA- errors (sqlplus writes them into the spool file too)
    if grep -qE "^ORA-[0-9]+" "${rename_sql}" 2>/dev/null; then
        grep -E "^ORA-[0-9]+" "${rename_sql}" | tee -a "${LOGFILE}"
        error "step2: ORA- error found in rename_files.sql spool. See above."
    fi
    local rename_count
    rename_count=$(grep -c "clonedb_renamefile" "${rename_sql}" 2>/dev/null || echo 0)
    [[ "${rename_count}" -gt 0 ]] || error "step2: rename_files.sql has no entries -- v\$datafile empty?"
    log "Generated ${rename_count} CLONEDB_RENAMEFILE entries (suffix _T${SNAP_INDEX})"
    head -3 "${rename_sql}" | tee -a "${LOGFILE}"
    success "rename_files.sql generated: ${rename_sql}"

    # Persist the index so downstream verification steps and summaries can read it
    RENAME_SQL="${rename_sql}"
}

# -----------------------------------------------------------------------------
# SECTION 5 - STEP 3: Create init.ora from Test Master SPFILE
# -----------------------------------------------------------------------------

step3_create_tm_initora() {
    step "3 - Export Test Master SPFILE to init.ora"

    TM_INIT="${WORK_DIR}/init_${TM_DB_NAME}.ora"
    log "Creating ${TM_INIT} from SPFILE..."

    sqlplus_check "${TM_ORACLE_SID}" "CREATE PFILE = '${TM_INIT}' FROM SPFILE;" "step3-pfile" > /dev/null
    [[ -f "${TM_INIT}" ]] || error "step3: PFILE not created: ${TM_INIT}"
    [[ -s "${TM_INIT}" ]] || error "step3: PFILE is empty: ${TM_INIT}"
    success "Test Master init.ora: ${TM_INIT}"
}

# -----------------------------------------------------------------------------
# SECTION 6 - STEP 4: Shut Down Test Master
# -----------------------------------------------------------------------------

step4_shutdown_testmaster() {
    step "4 - Shut Down Test Master Database"

    log "Shutting down Test Master (${TM_ORACLE_SID})..."
    sqlplus_verbose_check "${TM_ORACLE_SID}" "SHUTDOWN IMMEDIATE;" "step4-shutdown" > /dev/null
    # Confirm the instance is actually down
    local post_status
    post_status=$(ORACLE_SID="${TM_ORACLE_SID}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba 2>/dev/null <<EOF | tr -d ' \n\r'
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SELECT STATUS FROM V\$INSTANCE;
EXIT
EOF
) || post_status="DOWN"
    if [[ "${post_status}" == "OPEN" ]]; then
        error "step4: Test Master still OPEN after SHUTDOWN IMMEDIATE"
    fi
    log "Test Master down (post-shutdown status: '${post_status}')"
    success "Test Master shutdown complete"
}

# -----------------------------------------------------------------------------
# SECTION 7 - STEP 5: Create snap_init.ora for Snapshot Database
# -----------------------------------------------------------------------------

step5_create_snap_initora() {
    step "5 - Create snap_init.ora for Snapshot Database"

    TM_INIT="${WORK_DIR}/init_${TM_DB_NAME}.ora"
    SNAP_INIT="${WORK_DIR}/snap_init.ora"

    [[ -f "${TM_INIT}" ]] || error "Test Master init.ora not found: ${TM_INIT}"

    log "Copying ${TM_INIT} -> ${SNAP_INIT}"
    cp "${TM_INIT}" "${SNAP_INIT}"

    log "Patching snap_init.ora with snapshot-specific parameters..."

    # Replace / add key parameters for the snapshot DB
    python3 - <<PYEOF
import re, sys

params = {
    'db_name':              "'${SNAP_DB_NAME}'",
    'db_unique_name':       "'${SNAP_DB_UNIQUE_NAME}'",
    'control_files':        "'${SNAP_CONTROL_FILE}'",
    'audit_file_dest':      "'${ADUMP_DIR}'",
    'log_archive_dest_1':   "'LOCATION=${SNAP_DATA_DG}'",
}

with open("${SNAP_INIT}", 'r') as f:
    content = f.read()

for key, value in params.items():
    pattern = re.compile(r'^\s*\*?\.' + key + r'\s*=.*$', re.IGNORECASE | re.MULTILINE)
    replacement = f'*.{key}={value}'
    if pattern.search(content):
        content = pattern.sub(replacement, content)
    else:
        content += f'\n{replacement}'

# Remove parameters that must NOT be carried over
for remove_key in ['db_recovery_file_dest', 'fal_server', 'fal_client',
                   'log_archive_dest_2', 'log_archive_dest_3',
                   'standby_file_management', 'dg_broker_start']:
    content = re.sub(
        r'^\s*\*?\.' + remove_key + r'\s*=.*$', '',
        content, flags=re.IGNORECASE | re.MULTILINE)

with open("${SNAP_INIT}", 'w') as f:
    f.write(content)

# Validate required keys are present with non-empty values
missing = []
for k in params:
    if not re.search(r'^\\*?\\.' + k + r'\\s*=\\s*.+', content, re.IGNORECASE | re.MULTILINE):
        missing.append(k)
if missing:
    print(f"ERROR: snap_init.ora missing required params after patching: {missing}", file=sys.stderr)
    sys.exit(1)

print("snap_init.ora patched successfully")
PYEOF

    local py_rc=$?
    if [[ ${py_rc} -ne 0 ]]; then
        error "step5: snap_init.ora patch failed (exit ${py_rc})"
    fi
    [[ -s "${SNAP_INIT}" ]] || error "step5: snap_init.ora is empty after patching"
    log "--- snap_init.ora key parameters ---"
    grep -E "db_name|db_unique_name|control_files|audit_file_dest" "${SNAP_INIT}" | tee -a "${LOGFILE}"
    success "snap_init.ora created: ${SNAP_INIT}"
}

# -----------------------------------------------------------------------------
# SECTION 8 - STEP 6: Build CREATE CONTROLFILE script
# -----------------------------------------------------------------------------

step6_build_controlfile_script() {
    step "6 - Build CREATE CONTROLFILE Script for Snapshot DB"

    TRACE="${WORK_DIR}/controlfile_trace.trc"
    CTL_SQL="${WORK_DIR}/crt_ctlfile.sql"

    [[ -f "${TRACE}" ]] || error "Trace file not found: ${TRACE}. Did step 1 complete?"

    log "Trace file: ${TRACE}  ($(wc -l < "${TRACE}") lines)"
    log "Extracting RESETLOGS CREATE CONTROLFILE from trace file..."
    log "--- CREATE CONTROLFILE / RESETLOGS occurrences in trace ---"
    grep -in "create controlfile\|resetlogs\|set #2" "${TRACE}" | head -20 | tee -a "${LOGFILE}" || true

    # Write Python to a temp file so bash variables expand before Python runs.
    # Do NOT use single-quoted heredoc here -- we need bash to expand ${VAR}.
    PYFILE=$(mktemp /tmp/step6_XXXXXX.py)

    cat > "${PYFILE}" << PYEOF
import re, sys

TRACE     = "${TRACE}"
CTL_SQL   = "${CTL_SQL}"
TM_NAME   = "${TM_DB_NAME}"
SNAP_NAME = "${SNAP_DB_NAME}"
SNAP_DG   = "${SNAP_DATA_DG}"
REDO_GRP  = ${REDO_GROUPS}
REDO_SZ   = "${REDO_SIZE}"
REDO_BS   = "${REDO_BLOCKSIZE}"

with open(TRACE, "r", errors="replace") as f:
    raw = f.read()

resetlogs_block = None
strategy = None

# Strategy 1 -- Set #2 marker
m = re.search(r"Set\s+[#]2\b[^\n]*\n", raw, re.IGNORECASE)
if m:
    after = raw[m.end():]
    bm = re.search(
        r"(CREATE\s+CONTROLFILE\b.+?(?:CHARACTER\s+SET\s+\w+[^\n]*\n\s*;?\s*\n|;\s*\n))",
        after, re.DOTALL | re.IGNORECASE)
    if bm and re.search(r"\bRESETLOGS\b", bm.group(1), re.IGNORECASE):
        resetlogs_block = bm.group(1).strip()
        strategy = "Set#2 marker"

# Strategy 2 -- scan all CREATE CONTROLFILE blocks
if not resetlogs_block:
    for blk in re.findall(
            r"(CREATE\s+CONTROLFILE\b.+?(?:CHARACTER\s+SET\s+\w+[^\n]*\n\s*;?\s*\n|;\s*\n))",
            raw, re.DOTALL | re.IGNORECASE):
        if re.search(r"\bRESETLOGS\b", blk, re.IGNORECASE):
            resetlogs_block = blk.strip()
            strategy = "block scan"
            break

# Strategy 3 -- greedy RESETLOGS to semicolon
if not resetlogs_block:
    m3 = re.search(
        r"(CREATE\s+CONTROLFILE\b[^;]*\bRESETLOGS\b[^;]*;)",
        raw, re.DOTALL | re.IGNORECASE)
    if m3:
        resetlogs_block = m3.group(1).strip()
        strategy = "greedy RESETLOGS scan"

if not resetlogs_block:
    print("ERROR: Could not find RESETLOGS CREATE CONTROLFILE in trace.")
    for i, ln in enumerate(raw.splitlines(), 1):
        if "CREATE CONTROLFILE" in ln.upper():
            print(f"  L{i}: {ln.rstrip()}")
    sys.exit(1)

print(f"[INFO] Matched via strategy: {strategy}")

cmd = resetlogs_block.strip().rstrip(";").strip() + ";"

# Replace TM DB name -- handles both:
#   CREATE CONTROLFILE REUSE DATABASE "MOMTCD1" ...
#   CREATE CONTROLFILE REUSE SET DATABASE "MOMTCD1" ...
cmd = re.sub(
    r'(?i)((?:SET\s+)?DATABASE\s+)"?' + re.escape(TM_NAME) + r'"?',
    r'\g<1>' + SNAP_NAME,
    cmd)

log_lines = [
    f"    GROUP {i} '{SNAP_DG}/{SNAP_NAME}/t_log{i}.f' SIZE {REDO_SZ} BLOCKSIZE {REDO_BS}"
    for i in range(1, REDO_GRP + 1)
]
new_logfile = "  LOGFILE\n" + ",\n".join(log_lines)

cmd = re.sub(
    r"\bLOGFILE\b.*?(?=\bDATAFILE\b)",
    new_logfile + "\n  ",
    cmd, flags=re.DOTALL | re.IGNORECASE)

with open(CTL_SQL, "w") as f:
    f.write("-- Auto-generated by exadata_snapclone_create.sh\n")
    f.write(f"-- Snapshot DB : {SNAP_NAME}\n")
    f.write(f"-- Test Master : {TM_NAME}\n\n")
    f.write(cmd + "\n")

print("crt_ctlfile.sql generated successfully")
PYEOF

    python3 "${PYFILE}"
    rc=$?
    rm -f "${PYFILE}"

    if [[ ${rc} -ne 0 ]]; then
        error "step6: failed to build controlfile script (exit ${rc}). Trace: ${TRACE}"
    fi

    [[ -f "${CTL_SQL}" ]] || error "crt_ctlfile.sql not created. Check trace: ${TRACE}"

    log "--- crt_ctlfile.sql preview ---"
    head -35 "${CTL_SQL}" | tee -a "${LOGFILE}"
    success "Control file script created: ${CTL_SQL}"
}

# -----------------------------------------------------------------------------
# SECTION 9 - STEP 7: Create audit directory on OS
# -----------------------------------------------------------------------------

step7_create_audit_dir() {
    step "7 - Create Audit File Destination Directory"

    log "Creating: ${ADUMP_DIR}"
    mkdir -p "${ADUMP_DIR}"
    success "Audit directory ready: ${ADUMP_DIR}"
}

# -----------------------------------------------------------------------------
# SECTION 10 - STEP 8: Create ASM directories for snapshot datafiles
# -----------------------------------------------------------------------------

step8_create_asm_dirs() {
    step "8 - Create Oracle ASM Directories in ${SNAP_SPARSE_DG}"

    log "Grid user        : ${GRID_USER}"
    log "Grid home        : ${GRID_HOME}"
    log "ASM SID          : ${ASM_SID}"
    log "ASM exec method  : ${ASM_EXEC_METHOD}"

    # asmcmd does NOT support mkdir -p -- asmcmd_mkdir() creates each level
    log "Creating ${SNAP_SPARSE_DG}/${SNAP_DB_NAME}/DATAFILE ..."
    asmcmd_mkdir "${SNAP_SPARSE_DG}/${SNAP_DB_NAME}/DATAFILE"
    success "ASM directory ready: ${SNAP_SPARSE_DG}/${SNAP_DB_NAME}/DATAFILE"

    log "Creating ${SNAP_DATA_DG}/${SNAP_DB_NAME} ..."
    asmcmd_mkdir "${SNAP_DATA_DG}/${SNAP_DB_NAME}"
    success "ASM directory ready: ${SNAP_DATA_DG}/${SNAP_DB_NAME}"

    # Verify the directories actually exist
    log "Verifying ASM directories..."
    run_asmcmd "ls ${SNAP_SPARSE_DG}/${SNAP_DB_NAME}"
    run_asmcmd "ls ${SNAP_DATA_DG}/${SNAP_DB_NAME}"
    success "ASM directory verification passed"

    # If CDB: create subdirectories for each PDB using their GUIDs
    if [[ "${IS_CDB}" == "true" ]]; then
        log "CDB detected -- querying PDB GUIDs from Test Master..."

        sqlplus_verbose_check "${TM_ORACLE_SID}" "STARTUP MOUNT;
ALTER DATABASE OPEN READ ONLY;" "step8-tm-open-ro" > /dev/null
        verify_db_status "${TM_ORACLE_SID}" "OPEN" "step8-CDB-open"

        local pdb_guids
        pdb_guids=$(sqlplus_check "${TM_ORACLE_SID}" "
SELECT guid FROM cdb_pdbs WHERE con_id > 2;" "step8-pdb-guids" | tr -d ' ' | grep -v '^$')

        sqlplus_verbose_check "${TM_ORACLE_SID}" "SHUTDOWN IMMEDIATE;" "step8-tm-shutdown" > /dev/null

        for GUID in ${pdb_guids}; do
            log "Creating ASM dir for PDB GUID: ${GUID}"
            asmcmd_mkdir "${SNAP_SPARSE_DG}/${SNAP_DB_NAME}/${GUID}/DATAFILE"
            success "  Created: ${SNAP_SPARSE_DG}/${SNAP_DB_NAME}/${GUID}/DATAFILE"
        done
    fi
}

# -----------------------------------------------------------------------------
# SECTION 11 - STEP 9: Start Snapshot Instance (NOMOUNT)
# -----------------------------------------------------------------------------

step9_startup_nomount() {
    step "9 - Start Snapshot Instance in NOMOUNT"

    SNAP_INIT="${WORK_DIR}/snap_init.ora"
    [[ -f "${SNAP_INIT}" ]] || error "snap_init.ora not found: ${SNAP_INIT}"

    log "Starting ${SNAP_ORACLE_SID} NOMOUNT with pfile=${SNAP_INIT}..."
    sqlplus_verbose_check "${SNAP_ORACLE_SID}" "STARTUP NOMOUNT PFILE='${SNAP_INIT}';" "step9-nomount" > /dev/null
    # STARTUP NOMOUNT leaves V$INSTANCE.STATUS = STARTED
    verify_db_status "${SNAP_ORACLE_SID}" "STARTED" "step9"
    success "Snapshot instance in NOMOUNT (STATUS=STARTED)"
}

# -----------------------------------------------------------------------------
# SECTION 12 - STEP 10: Create Snapshot Control File
# -----------------------------------------------------------------------------

step10_create_controlfile() {
    step "10 - Create Snapshot Control File"

    CTL_SQL="${WORK_DIR}/crt_ctlfile.sql"
    [[ -f "${CTL_SQL}" ]] || error "Control file script not found: ${CTL_SQL}"

    log "Running ${CTL_SQL} on ${SNAP_ORACLE_SID}..."
    sqlplus_verbose_check "${SNAP_ORACLE_SID}" "@${CTL_SQL}" "step10-create-ctlfile" > /dev/null
    # Successful CREATE CONTROLFILE leaves the instance in MOUNTED state
    verify_db_status "${SNAP_ORACLE_SID}" "MOUNTED" "step10"
    success "Snapshot control file created (STATUS=MOUNTED)"
}

# -----------------------------------------------------------------------------
# SECTION 13 - STEP 11: Run rename_files.sql (CLONEDB_RENAMEFILE)
# -----------------------------------------------------------------------------

step11_rename_files() {
    step "11 - Run DBMS_DNFS.CLONEDB_RENAMEFILE for All Datafiles"

    local rename_sql="${WORK_DIR}/rename_files.sql"
    [[ -f "${rename_sql}" ]] || error "rename_files.sql not found: ${rename_sql}  (did step 2 run?)"

    log "Running rename_files.sql on ${SNAP_ORACLE_SID} (index T${SNAP_INDEX})..."
    log "This sets parent-child relationships and marks TM files read-only in ASM"
    local rename_out
    rename_out=$(sqlplus_verbose_check "${SNAP_ORACLE_SID}" "@${rename_sql}" "step11-rename")
    # sqlplus_verbose_check catches ORA-; also check PLS- from EXECUTE statements
    if echo "${rename_out}" | grep -qE "^PLS-[0-9]+"; then
        error "step11: PL/SQL error in rename_files.sql. See above."
    fi
    success "CLONEDB_RENAMEFILE complete (T${SNAP_INDEX}) -- parent-child relationships established"
}

# -----------------------------------------------------------------------------
# SECTION 14 - STEP 12: Open Snapshot Database with RESETLOGS
# -----------------------------------------------------------------------------

step12_open_resetlogs() {
    step "12 - Open Snapshot Database with RESETLOGS"

    log "Opening ${SNAP_ORACLE_SID} with RESETLOGS..."
    sqlplus_verbose_check "${SNAP_ORACLE_SID}" "ALTER DATABASE OPEN RESETLOGS;" "step12-open-resetlogs" > /dev/null
    verify_db_status "${SNAP_ORACLE_SID}" "OPEN" "step12"
    success "Snapshot database is OPEN (RESETLOGS complete)"
}

# -----------------------------------------------------------------------------
# SECTION 15 - STEP 13: Verify Clone File Relationships
# -----------------------------------------------------------------------------

step13_verify_cloned_files() {
    step "13 - Verify Snapshot Parent-Child File Relationships"

    log "Querying V\$CLONEDFILE on ${SNAP_ORACLE_SID}..."
    local CLONE_OUTPUT
    CLONE_OUTPUT=$(run_sqlplus_snap "
SET LINESIZE 200
SET PAGESIZE 100
COLUMN num     FORMAT 9999  HEADING 'File#'
COLUMN child   FORMAT A60   HEADING 'Child (Snapshot)'
COLUMN parent  FORMAT A60   HEADING 'Parent (Test Master)'
SELECT filenumber num, clonefilename child, snapshotfilename parent
FROM V\$CLONEDFILE
ORDER BY filenumber;
")

    echo "${CLONE_OUTPUT}" | tee -a "${LOGFILE}"

    local clone_count
    clone_count=$(echo "${CLONE_OUTPUT}" | grep -cF "${SNAP_SPARSE_DG}" || true)
    # Empty V$CLONEDFILE means CLONEDB_RENAMEFILE completely failed -- hard stop
    [[ "${clone_count}" -gt 0 ]] ||         error "step13: V\$CLONEDFILE is empty -- CLONEDB_RENAMEFILE failed or dNFS not configured"
    success "${clone_count} cloned file(s) verified in V\$CLONEDFILE"
}

# -----------------------------------------------------------------------------
# SECTION 16 - STEP 14: Add Tempfile to TEMP Tablespace
# -----------------------------------------------------------------------------

step14_add_tempfile() {
    step "14 - Add Tempfile to TEMP Tablespace"

    log "Adding ${TEMP_SIZE} tempfile in ${SNAP_DATA_DG} to TEMP tablespace..."
    sqlplus_verbose_check "${SNAP_ORACLE_SID}"         "ALTER TABLESPACE temp ADD TEMPFILE '${SNAP_DATA_DG}' SIZE ${TEMP_SIZE};"         "step14-tempfile" > /dev/null
    success "Tempfile added to TEMP tablespace"

    # If CDB: add tempfile to each PDB's TEMP tablespace
    if [[ "${IS_CDB}" == "true" ]]; then
        log "CDB mode: adding tempfiles to each PDB..."
        local pdb_names
        pdb_names=$(sqlplus_check "${SNAP_ORACLE_SID}"             "SELECT name FROM v\$pdbs WHERE con_id > 2;" "step14-pdb-list" | tr -d ' ' | grep -v '^$')
        for PDB in ${pdb_names}; do
            log "  Adding tempfile to PDB: ${PDB}"
            sqlplus_verbose_check "${SNAP_ORACLE_SID}" "
ALTER SESSION SET CONTAINER=${PDB};
ALTER TABLESPACE temp ADD TEMPFILE '${SNAP_DATA_DG}' SIZE ${TEMP_SIZE};"                 "step14-pdb-${PDB}" > /dev/null
            success "  Tempfile added to ${PDB}"
        done
    fi
}

# -----------------------------------------------------------------------------
# SECTION 17 - FINAL SUMMARY
# -----------------------------------------------------------------------------

print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}+======================================================+${NC}"
    echo -e "${GREEN}${BOLD}|       Exadata SnapClone Creation COMPLETE            |${NC}"
    echo -e "${GREEN}${BOLD}+======================================================+${NC}"
    echo ""
    echo -e "  Test Master DB   : ${BOLD}${TM_DB_NAME}${NC}  (SID: ${TM_ORACLE_SID})"
    echo -e "  Snapshot DB      : ${BOLD}${SNAP_DB_NAME}${NC}  (SID: ${SNAP_ORACLE_SID})"
    echo -e "  Sparse Disk Group: ${BOLD}${SNAP_SPARSE_DG}${NC}"
    echo -e "  Data Disk Group  : ${BOLD}${SNAP_DATA_DG}${NC}"
    echo -e "  Snapshot Index   : ${BOLD}T${SNAP_INDEX}${NC}  (sparse files end in _T${SNAP_INDEX})"
    echo -e "  Working Dir      : ${BOLD}${WORK_DIR}${NC}"
    echo -e "  Log File         : ${BOLD}${LOGFILE}${NC}"
    echo ""
    echo -e "  Generated Files:"
    echo -e "    ${WORK_DIR}/snap_init.ora"
    echo -e "    ${WORK_DIR}/crt_ctlfile.sql"
    echo -e "    ${WORK_DIR}/rename_files.sql"
    echo -e "    ${WORK_DIR}/controlfile_trace.trc"
    echo ""
    echo -e "  ${YELLOW}NOTE:${NC} Test Master DB is currently SHUTDOWN."
    echo -e "  To restart it: ORACLE_SID=${TM_ORACLE_SID} sqlplus / as sysdba"
    echo -e "                 SQL> STARTUP"
    echo ""
    echo -e "  ${YELLOW}NEXT CLONE${NC} from this same Test Master: run again without --refresh"
    echo -e "  -- index will auto-advance to T$(( SNAP_INDEX + 1 ))."
    echo -e "  ${YELLOW}REFRESH${NC} the Test Master: run with --refresh"
    echo -e "  -- index will RESET to T0 for the new TM generation."
    echo ""
}

# =============================================================================
#  PART B -- REFRESHING THE TEST MASTER DATABASE
#  Based on Oracle Documentation Section 9.7.5.4:
#  "Refreshing the (Read-only) Test Master Database"
#  https://docs.oracle.com/en/engineered-systems/exadata-database-machine/
#         sagug/update-test-master-database.html
#
#  Refresh lifecycle:
#    R1) Drop all snapshot child databases (RMAN)
#    R2) Reset TM datafile permissions (read-write) via ASM ALTER DISKGROUP
#    R3) Convert TM back to Data Guard replica (re-enable log ship + apply)
#    R4) Choose refresh method:
#         Option A -- Data Guard redo apply (short gap, archive logs available)
#         Option B -- RMAN RECOVER...FROM SERVICE network incremental (long gap)
#    R5) Disable log shipping / redo apply again
#    R6) Re-run snapshot creation cycle (calls Part A functions)
# =============================================================================

# -----------------------------------------------------------------------------
# REFRESH CONFIGURATION  (add to your config file or edit here)
# -----------------------------------------------------------------------------

# Source (primary) database name -- used by RMAN FROM SERVICE
SOURCE_DB_NAME="${SOURCE_DB_NAME:-SOURCEMASTER}"

# Test Master host -- needed for TNS/listener entries (RMAN method)
TM_HOST="${TM_HOST:-standbydb01.example.com}"
TM_PORT="${TM_PORT:-1521}"

# Oracle listener name on TM host
TM_LISTENER="${TM_LISTENER:-LISTENER}"

# Refresh method: "dataguard" | "rman"
# Override via config: REFRESH_METHOD="rman"
REFRESH_METHOD="${REFRESH_METHOD:-dataguard}"

# List of snapshot SIDs to drop before refresh (space-separated)
# Override via config: SNAP_SID_LIST="SNAPTEST1 SNAPTEST2 SNAPTEST3"
SNAP_SID_LIST="${SNAP_SID_LIST:-${SNAP_ORACLE_SID}}"

# -----------------------------------------------------------------------------
# REFRESH STEP R1: Drop All Snapshot Databases (children of Test Master)
# -----------------------------------------------------------------------------

refresh_r1_drop_snapshots() {
    step "R1 - Drop All Snapshot Databases (Children of Test Master)"

    warn "This will DROP all snapshot databases listed in SNAP_SID_LIST."
    warn "Snapshots: ${SNAP_SID_LIST}"

    if [[ "${FORCE:-false}" != "true" ]]; then
        read -r -p "  Type YES to confirm drop of all snapshots: " CONFIRM
        [[ "${CONFIRM}" == "YES" ]] || { log "Aborted by user."; exit 0; }
    fi

    for SNAP_SID in ${SNAP_SID_LIST}; do
        log "Dropping snapshot database: ${SNAP_SID}"

        # Shutdown abort to ensure clean RMAN connect
        ORACLE_SID="${SNAP_SID}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba <<EOF 2>/dev/null || true
SHUTDOWN ABORT;
EXIT
EOF

        # Use RMAN to drop the snapshot database and all its files
        rman_check "${SNAP_SID}" "STARTUP MOUNT FORCE;
DROP DATABASE INCLUDING BACKUPS NOPROMPT;" "R1-drop-${SNAP_SID}" > /dev/null
        success "Snapshot ${SNAP_SID} dropped"
    done

    success "R1 complete -- all snapshots dropped"
}

# -----------------------------------------------------------------------------
# REFRESH STEP R2: Reset Test Master Datafile Permissions to Read-Write
# -----------------------------------------------------------------------------

refresh_r2_reset_tm_permissions() {
    step "R2 - Reset Test Master Datafile Permissions (Read-Only -> Read-Write)"

    log "Generating change_perm.sql to restore read-write on ${TM_DATA_DG} files..."

    PERM_SQL="${WORK_DIR}/change_perm.sql"

    # Start TM in MOUNT to query v$datafile
    sqlplus_verbose_check "${TM_ORACLE_SID}" "STARTUP MOUNT;" "R2-mount" > /dev/null
    verify_db_status "${TM_ORACLE_SID}" "MOUNTED" "R2"

    sqlplus_check "${TM_ORACLE_SID}" "
SET NEWPAGE 0
SET LINESIZE 999
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET ECHO OFF
SET SPACE 0
SET TAB OFF
SET TRIMSPOOL ON
SPOOL ${PERM_SQL}
SELECT 'ALTER DISKGROUP ${TM_DATA_DG##\+} SET PERMISSION OWNER=READ WRITE, GROUP=READ WRITE, OTHER=NONE FOR FILE ''' || name || ''';'
FROM v\$datafile;
SPOOL OFF" "R2-gen-perm-sql" > /dev/null

    sed -i '/^[[:space:]]*$/d;/^SQL>/d' "${PERM_SQL}" 2>/dev/null || true

    [[ -f "${PERM_SQL}" ]] || error "R2: change_perm.sql was not created"
    if grep -qE "^ORA-[0-9]+" "${PERM_SQL}" 2>/dev/null; then
        grep -E "^ORA-[0-9]+" "${PERM_SQL}" | tee -a "${LOGFILE}"
        error "R2: ORA- error found in change_perm.sql spool. See above."
    fi
    local perm_count
    perm_count=$(grep -c "ALTER DISKGROUP" "${PERM_SQL}" 2>/dev/null || echo 0)
    [[ "${perm_count}" -gt 0 ]] || error "R2: change_perm.sql is empty -- no datafiles in v\$datafile"
    log "R2: Generated ${perm_count} ALTER DISKGROUP permission statements"

    log "Executing permission reset as sysasm..."
    run_sqlplus_asm "@${PERM_SQL}"

    success "R2 complete -- TM datafile permissions restored to read-write"
}

# -----------------------------------------------------------------------------
# REFRESH STEP R3: Convert Test Master Back to Data Guard Replica
# -----------------------------------------------------------------------------

refresh_r3_convert_back_to_standby() {
    step "R3 - Convert Test Master Back to Data Guard Replica (MOUNT mode)"

    log "Shutting down TM instance (if open)..."
    run_sqlplus_tm "SHUTDOWN IMMEDIATE;" 2>/dev/null || true

    log "Restarting TM in MOUNT mode (standby role)..."
    sqlplus_verbose_check "${TM_ORACLE_SID}" "STARTUP MOUNT;" "R3-mount" > /dev/null
    verify_db_status "${TM_ORACLE_SID}" "MOUNTED" "R3"
    success "R3 complete -- Test Master is MOUNTED"
}

# -----------------------------------------------------------------------------
# REFRESH STEP R4A: Refresh via Oracle Data Guard (short gap / archives on disk)
# -----------------------------------------------------------------------------

refresh_r4a_dataguard_refresh() {
    step "R4A - Refresh Test Master via Oracle Data Guard Redo Apply"

    log "Enabling log shipping to ${TM_DB_UNIQUE_NAME} via DGMGRL..."
    dgmgrl_check "EDIT DATABASE ${TM_DB_UNIQUE_NAME} SET PROPERTY LOGSHIPPING=ON;
EDIT DATABASE ${TM_DB_UNIQUE_NAME} SET STATE=APPLY-ON;" "R4A-apply-on"

    log ""
    log "Data Guard redo apply started. Monitor apply lag with:"
    log "  DGMGRL> SHOW DATABASE VERBOSE ${TM_DB_UNIQUE_NAME};"
    log "  SQL>    SELECT NAME, VALUE, DATUM_TIME FROM V\$DATAGUARD_STATS;"
    log ""
    warn "When the Test Master is as current as required, run:"
    warn "  $0 --refresh --step R4A-stop"
    warn "  OR manually stop apply: DGMGRL> EDIT DATABASE ${TM_DB_UNIQUE_NAME} SET STATE=APPLY-OFF;"
    warn "  Then continue with: $0 --refresh --step R5"

    success "R4A complete -- Data Guard redo apply active"
}

refresh_r4a_stop_apply() {
    step "R4A-STOP - Stop Data Guard Redo Apply on Test Master"

    log "Disabling log shipping and stopping redo apply on ${TM_DB_UNIQUE_NAME}..."
    dgmgrl_check "EDIT DATABASE ${TM_DB_UNIQUE_NAME} SET STATE=APPLY-OFF;
EDIT DATABASE ${TM_DB_UNIQUE_NAME} SET PROPERTY LOGSHIPPING=OFF;" "R4A-stop"
    success "R4A-STOP complete -- redo apply disabled"
}

# -----------------------------------------------------------------------------
# REFRESH STEP R4B: Refresh via RMAN RECOVER...FROM SERVICE (long gap / no archives)
# -----------------------------------------------------------------------------

refresh_r4b_prepare_net_services() {
    step "R4B-PREP - Prepare Oracle Net Services for RMAN Network Incrementals"

    log "NOTE: This step only needs to be performed ONCE per environment."
    log ""

    LISTENER_ORA="${ORACLE_HOME}/network/admin/listener.ora"
    TNSNAMES_ORA="${ORACLE_HOME}/network/admin/tnsnames.ora"

    # --- listener.ora entry ---
    log "Checking listener.ora for ${TM_ORACLE_SID} static entry..."
    if grep -q "SID_NAME = ${TM_ORACLE_SID}" "${LISTENER_ORA}" 2>/dev/null; then
        log "Listener entry for ${TM_ORACLE_SID} already exists -- skipping"
    else
        log "Appending static SID entry to ${LISTENER_ORA}..."
        cat >> "${LISTENER_ORA}" <<LSNR

# Added by exadata_snapclone_create.sh for RMAN network refresh
SID_LIST_${TM_LISTENER} =
  (SID_LIST =
    (SID_DESC =
      (SID_NAME = ${TM_ORACLE_SID})
      (ORACLE_HOME = ${ORACLE_HOME})
    )
  )
LSNR
        log "Reloading listener ${TM_LISTENER}..."
        "${ORACLE_HOME}/bin/lsnrctl" reload "${TM_LISTENER}"
        success "Listener entry added and reloaded"
    fi

    # --- tnsnames.ora entry ---
    log "Checking tnsnames.ora for ${TM_ORACLE_SID} entry..."
    if grep -q "^${TM_ORACLE_SID}" "${TNSNAMES_ORA}" 2>/dev/null; then
        log "TNS entry for ${TM_ORACLE_SID} already exists -- skipping"
    else
        log "Appending TNS alias to ${TNSNAMES_ORA}..."
        cat >> "${TNSNAMES_ORA}" <<TNS

# Added by exadata_snapclone_create.sh for RMAN network refresh
${TM_ORACLE_SID} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${TM_HOST})(PORT = ${TM_PORT}))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SID = ${TM_ORACLE_SID})
      (UR=A)
    )
  )
TNS
        success "TNS alias added: ${TM_ORACLE_SID}"
    fi

    success "R4B-PREP complete -- Net Services ready"
}

refresh_r4b_rman_recover() {
    step "R4B - Refresh Test Master via RMAN RECOVER...FROM SERVICE"

    log "Step 1/6 -- Recording current SCN from Test Master (MOUNT)..."
    local current_scn
    current_scn=$(sqlplus_check "${TM_ORACLE_SID}"         "SELECT current_scn FROM v\$database;" "R4B-get-scn" | tr -d ' ' | grep -E '^[0-9]+$' | tail -1)
    [[ -n "${current_scn}" ]] || error "R4B: Could not determine current SCN from v\$database"
    log "Current SCN: ${current_scn}"

    log "Step 2/6 -- Recording redo log file names and group IDs..."
    local logfile_info
    logfile_info=$(sqlplus_check "${TM_ORACLE_SID}"         "SELECT type, group#, member FROM v\$logfile;" "R4B-logfiles")
    log "Logfile info captured"
    echo "${logfile_info}" > "${WORK_DIR}/logfile_info.txt"

    log "Step 3/6 -- Restoring standby control file from SOURCE (${SOURCE_DB_NAME})..."
    rman_check "${TM_ORACLE_SID}" "STARTUP NOMOUNT FORCE;
RESTORE STANDBY CONTROLFILE FROM SERVICE ${SOURCE_DB_NAME};
ALTER DATABASE MOUNT;" "R4B-restore-ctlfile" > /dev/null
    verify_db_status "${TM_ORACLE_SID}" "MOUNTED" "R4B-after-mount"

    log "Step 4/6 -- Cataloging TM datafiles (CATALOG START WITH)..."
    local tm_datafile_path="${TM_DATA_DG}/${TM_DB_NAME}/DATAFILE/"
    rman_check "${TM_ORACLE_SID}" "CATALOG START WITH '${tm_datafile_path}' NOPROMPT;" \
        "R4B-catalog" > /dev/null

    log "Step 5/6 -- Checking for new datafiles created since SCN ${current_scn}..."
    local new_files
    new_files=$(sqlplus_check "${TM_ORACLE_SID}" "
SELECT file# FROM v\$datafile WHERE creation_change# >= ${current_scn};" "R4B-new-files" \
        | tr -d ' ' | grep -E '^[0-9]+$' | tr '\n' ',' | sed 's/,$//')

    if [[ -n "${new_files}" ]]; then
        log "New files found (FILE#: ${new_files}) -- restoring from ${SOURCE_DB_NAME}..."
        rman_check "${TM_ORACLE_SID}" "RUN {
  SET NEWNAME FOR DATABASE TO '${TM_DATA_DG}';
  RESTORE DATAFILE ${new_files} FROM SERVICE ${SOURCE_DB_NAME};
}
SWITCH DATABASE TO COPY;" "R4B-restore-new" > /dev/null
    else
        log "No new datafiles since SCN ${current_scn} -- switching to cataloged copies..."
        rman_check "${TM_ORACLE_SID}" "SWITCH DATABASE TO COPY;" "R4B-switch" > /dev/null
    fi

    log "Step 6/6 -- Clearing redo log groups to reset standby/online redo logs..."
    # Read group numbers from saved logfile info
    local groups
    groups=$(grep -oE 'GROUP#[[:space:]]+[0-9]+' "${WORK_DIR}/logfile_info.txt" 2>/dev/null | \
             grep -oE '[0-9]+$' | sort -u || echo "")

    if [[ -n "${groups}" ]]; then
        for grp in ${groups}; do
            log "  Clearing redo log group ${grp}..."
            sqlplus_check "${TM_ORACLE_SID}"                 "ALTER DATABASE CLEAR LOGFILE GROUP ${grp};" "R4B-clear-grp${grp}" > /dev/null || \
                warn "Could not clear group ${grp} -- may need manual intervention"
        done
    else
        warn "Could not determine log group numbers -- check ${WORK_DIR}/logfile_info.txt"
        warn "Manually run: SQL> ALTER DATABASE CLEAR LOGFILE GROUP <N>; for each group"
    fi

    log "Running RMAN RECOVER DATABASE NOREDO FROM SERVICE ${SOURCE_DB_NAME}..."
    log "(This rolls forward all changed blocks from primary -- no extra disk space needed)"
    rman_check "${TM_ORACLE_SID}"         "RECOVER DATABASE NOREDO FROM SERVICE ${SOURCE_DB_NAME};" "R4B-recover" > /dev/null
    success "R4B complete -- RMAN network incremental recovery done"
}

# -----------------------------------------------------------------------------
# REFRESH STEP R5: Enable Redo Shipping to Finalise Control File + Then Disable
# -----------------------------------------------------------------------------

refresh_r5_enable_then_disable_apply() {
    step "R5 - Briefly Enable Redo Shipping to Sync Control File, Then Disable"

    log "Enabling log shipping + redo apply to sync control file..."
    dgmgrl_check "EDIT DATABASE ${TM_DB_UNIQUE_NAME} SET PROPERTY LOGSHIPPING=ON;
EDIT DATABASE ${TM_DB_UNIQUE_NAME} SET STATE=APPLY-ON;" "R5-apply-on"

    log "Waiting 60 seconds for redo apply to update control file..."
    sleep 60

    log "Disabling log shipping and redo apply..."
    dgmgrl_check "EDIT DATABASE ${TM_DB_UNIQUE_NAME} SET STATE=APPLY-OFF;
EDIT DATABASE ${TM_DB_UNIQUE_NAME} SET PROPERTY LOGSHIPPING=OFF;" "R5-apply-off"

    success "R5 complete -- control file synced, Data Guard transport stopped"
}

# -----------------------------------------------------------------------------
# REFRESH STEP R6: Re-run SnapClone Creation Cycle
# -----------------------------------------------------------------------------

refresh_r6_recreate_snapclone() {
    step "R6 - Re-create Exadata SnapClone (Running Part A Creation Cycle)"

    # ---------------------------------------------------------------------------
    # Reset SNAP_INDEX to 0 on every refresh.
    #
    # A refresh produces a new generation of the Test Master.  The first clone
    # off the freshly refreshed TM is always T0, the second T1, etc.  Resetting
    # here means the creation-mode counter logic will start from 0 again.
    #
    # The counter file is written with value 0 after all 14 creation steps
    # succeed so that the *next* plain creation run reads 0 and uses T0.
    # If --snap-index N was explicitly given, that value is used instead and
    # the counter file is not touched.
    # ---------------------------------------------------------------------------
    local counter_file="${WORK_DIR}/.snap_index_counter"

    if [[ -n "${_SNAP_INDEX_EXPLICIT:-}" ]]; then
        log "Using explicit SNAP_INDEX: T${SNAP_INDEX}  (counter file not modified)"
    else
        SNAP_INDEX=0
        log "SNAP_INDEX reset to T0 for new Test Master generation"
    fi

    log "Re-running all 14 snapshot creation steps against refreshed Test Master..."
    log "Snapshot DB    : ${SNAP_DB_NAME} (${SNAP_ORACLE_SID})"
    log "Snapshot Index : T${SNAP_INDEX}  (sparse files will end in _T${SNAP_INDEX})"

    # The TM should be OPEN at this point; start it if not
    local tm_status_r6
    tm_status_r6=$(ORACLE_SID="${TM_ORACLE_SID}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba \
        2>/dev/null <<EOF | tr -d ' \n\r'
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SELECT STATUS FROM V\$INSTANCE;
EXIT
EOF
) || tm_status_r6="DOWN"
    if [[ "${tm_status_r6}" != "OPEN" ]]; then
        log "Starting Test Master (current: ${tm_status_r6})..."
        sqlplus_verbose_check "${TM_ORACLE_SID}" "STARTUP;" "R6-startup" > /dev/null
        verify_db_status "${TM_ORACLE_SID}" "OPEN" "R6"
    fi

    check_prerequisites
    step1_backup_controlfile_trace
    step2_generate_rename_script
    step3_create_tm_initora
    step4_shutdown_testmaster
    step5_create_snap_initora
    step6_build_controlfile_script
    step7_create_audit_dir
    step8_create_asm_dirs
    step9_startup_nomount
    step10_create_controlfile
    step11_rename_files
    step12_open_resetlogs
    step13_verify_cloned_files
    step14_add_tempfile

    # All 14 steps succeeded.  Write 1 to the counter so that the next plain
    # creation run from this refreshed TM generation uses T1.
    # (R6 itself just created T0, so the next clone should be T1.)
    if [[ -z "${_SNAP_INDEX_EXPLICIT:-}" ]]; then
        echo "1" > "${counter_file}"
        log "Counter file reset: ${counter_file} -> 1  (next creation from this TM will be T1)"
    fi

    success "R6 complete -- fresh SnapClone T${SNAP_INDEX} created from refreshed Test Master"
}

# -----------------------------------------------------------------------------
# REFRESH SUMMARY
# -----------------------------------------------------------------------------

print_refresh_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}+======================================================+${NC}"
    echo -e "${GREEN}${BOLD}|     Test Master REFRESH + SnapClone COMPLETE         |${NC}"
    echo -e "${GREEN}${BOLD}+======================================================+${NC}"
    echo ""
    echo -e "  Test Master DB   : ${BOLD}${TM_DB_NAME}${NC}  (SID: ${TM_ORACLE_SID})"
    echo -e "  Source (Primary) : ${BOLD}${SOURCE_DB_NAME}${NC}"
    echo -e "  Refresh Method   : ${BOLD}${REFRESH_METHOD}${NC}"
    echo -e "  New Snapshot DB  : ${BOLD}${SNAP_DB_NAME}${NC}  (SID: ${SNAP_ORACLE_SID})"
    echo -e "  Snapshot Index   : ${BOLD}T${SNAP_INDEX}${NC}  (reset to T0 for this new TM generation)"
    echo -e "  Counter File     : ${BOLD}${WORK_DIR}/.snap_index_counter${NC}  (next plain creation = T1)"
    echo -e "  Log File         : ${BOLD}${LOGFILE}${NC}"
    echo ""
    echo -e "  ${YELLOW}REMINDER:${NC} If data was masked/scrubbed on the Test Master"
    echo -e "  before the previous snapshot cycle, you must re-apply"
    echo -e "  masking now before creating new snapshots for distribution."
    echo ""
}

# =============================================================================
# SECTION 18 - ARGUMENT PARSING & MAIN ENTRY POINT
# =============================================================================

usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
    echo ""
    echo -e "${BOLD}MODES:${NC}"
    echo "  (default)           Full SnapClone creation (Steps 1-14)"
    echo "  --refresh           Full Test Master refresh + new SnapClone creation"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --config <file>     Source a config file to override default variables"
    echo "  --skip-shutdown     Skip Test Master shutdown step (use if already down)"
    echo "  --cdb               Enable CDB mode (PDB temp files, ASM subdirs by GUID)"
    echo "  --force             Skip interactive confirmation prompts"
    echo "  --snap-index <N>    Override the clone index for this run (default: auto from"
    echo "                      counter file for creation; always 0 after --refresh)"
    echo "  --step <ID>         Run a single step only"
    echo "  --help              Show this help message"
    echo ""
    echo -e "${BOLD}Creation steps (--step N):${NC}"
    echo "  0  Prerequisites check"
    echo "  1  Backup control file to trace"
    echo "  2  Generate rename_files.sql"
    echo "  3  Export TM SPFILE to init.ora"
    echo "  4  Shutdown Test Master"
    echo "  5  Create snap_init.ora"
    echo "  6  Build CREATE CONTROLFILE script"
    echo "  7  Create OS audit directory"
    echo "  8  Create ASM directories"
    echo "  9  Startup snapshot NOMOUNT"
    echo "  10 Create snapshot control file"
    echo "  11 Run rename_files.sql (CLONEDB_RENAMEFILE)"
    echo "  12 Open snapshot RESETLOGS"
    echo "  13 Verify V\$CLONEDFILE"
    echo "  14 Add tempfile to TEMP"
    echo ""
    echo -e "${BOLD}Refresh steps (--refresh --step RN):${NC}"
    echo "  R1        Drop all snapshot child databases"
    echo "  R2        Reset TM datafile permissions to read-write"
    echo "  R3        Convert TM back to standby (MOUNT mode)"
    echo "  R4A       Enable Data Guard redo apply (short gap)"
    echo "  R4A-stop  Stop Data Guard redo apply"
    echo "  R4B-prep  Prepare Oracle Net Services for RMAN method (one-time)"
    echo "  R4B       RMAN RECOVER...FROM SERVICE (long gap)"
    echo "  R5        Brief redo apply to sync control file, then stop"
    echo "  R6        Re-run SnapClone creation cycle"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                              # First clone from current TM: T0"
    echo "  $0                              # Second clone from same TM: T1 (auto)"
    echo "  $0 --snap-index 3              # Force clone index to T3"
    echo "  $0 --cdb                        # Full creation, CDB mode"
    echo "  $0 --step 13                    # Run only verification step"
    echo "  $0 --refresh                    # Refresh TM, create T0 (index resets)"
    echo "  $0 --refresh --snap-index 5    # Refresh TM, force clone index to T5"
    echo "  $0 --refresh --rman-refresh     # Full refresh (RMAN method)"
    echo "  $0 --refresh --step R1          # Drop snapshots only"
    echo "  $0 --refresh --step R4B-prep    # Prepare Net Services (one-time)"
    echo ""
}

SKIP_SHUTDOWN=false
RUN_STEP=""
MODE="create"          # create | refresh
RMAN_REFRESH=false
FORCE=false
_SNAP_INDEX_EXPLICIT=""   # set when --snap-index is given; prevents R6 auto-increment

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)       source "$2"; shift 2 ;;
        --skip-shutdown) SKIP_SHUTDOWN=true; shift ;;
        --cdb)          IS_CDB="true"; shift ;;
        --force)        FORCE=true; shift ;;
        --refresh)      MODE="refresh"; shift ;;
        --rman-refresh) RMAN_REFRESH=true; REFRESH_METHOD="rman"; shift ;;
        --snap-index)
            [[ "$2" =~ ^[0-9]+$ ]] || { echo "ERROR: --snap-index requires a non-negative integer" >&2; exit 1; }
            SNAP_INDEX="$2"
            _SNAP_INDEX_EXPLICIT="yes"
            shift 2 ;;
        --step)         RUN_STEP="$2"; shift 2 ;;
        --help)         usage; exit 0 ;;
        *)              echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Ensure WORK_DIR exists before logging starts
mkdir -p "${WORK_DIR}"

export ORACLE_HOME PATH="${ORACLE_HOME}/bin:${PATH}" ORACLE_BASE FORCE

if [[ "${MODE}" == "refresh" ]]; then
    echo -e "${BOLD}"
    echo "+===========================================================+"
    echo "|   Exadata SnapClone -- Refresh Test Master Database       |"
    echo "|   Ref: Oracle Doc Section 9.7.5.4                        |"
    echo "+===========================================================+"
    echo -e "${NC}"
    log "REFRESH mode started. Log: ${LOGFILE}"
    log "Test Master: ${TM_DB_NAME} | Source Primary: ${SOURCE_DB_NAME}"
    log "Refresh method: ${REFRESH_METHOD}"
    log "Snapshots to drop: ${SNAP_SID_LIST}"
    if [[ -n "${_SNAP_INDEX_EXPLICIT:-}" ]]; then
        log "Snapshot index: T${SNAP_INDEX} (explicit -- auto-reset suppressed)"
    else
        log "Snapshot index: will RESET to T0 in R6 (new Test Master generation)"
    fi

    # Single refresh step if requested
    if [[ -n "${RUN_STEP}" ]]; then
        case "${RUN_STEP}" in
            R1)        refresh_r1_drop_snapshots ;;
            R2)        refresh_r2_reset_tm_permissions ;;
            R3)        refresh_r3_convert_back_to_standby ;;
            R4A)       refresh_r4a_dataguard_refresh ;;
            R4A-stop)  refresh_r4a_stop_apply ;;
            R4B-prep)  refresh_r4b_prepare_net_services ;;
            R4B)       refresh_r4b_rman_recover ;;
            R5)        refresh_r5_enable_then_disable_apply ;;
            R6)        refresh_r6_recreate_snapclone ;;
            *)         error "Unknown refresh step: ${RUN_STEP}. See --help for valid steps." ;;
        esac
        exit 0
    fi

    # Full refresh sequence
    refresh_r1_drop_snapshots
    refresh_r2_reset_tm_permissions
    refresh_r3_convert_back_to_standby

    if [[ "${REFRESH_METHOD}" == "rman" ]]; then
        refresh_r4b_prepare_net_services
        refresh_r4b_rman_recover
        refresh_r5_enable_then_disable_apply
    else
        # Data Guard method -- user must manually call R4A-stop when ready
        refresh_r4a_dataguard_refresh
        warn "========================================================="
        warn " Data Guard apply is now running. Monitor progress, then"
        warn " when ready to freeze the Test Master, run:"
        warn "   $0 --refresh --step R4A-stop"
        warn "   $0 --refresh --step R5"
        warn "   $0 --refresh --step R6"
        warn "========================================================="
        exit 0
    fi

    refresh_r6_recreate_snapclone
    print_refresh_summary
    exit 0
fi

# -----------------------------------------------------------------------------
# DEFAULT MODE: Full SnapClone Creation
# -----------------------------------------------------------------------------

echo -e "${BOLD}"
echo "+===========================================================+"
echo "|   Exadata SnapClone Automation -- Full Database Snapshot   |"
echo "|   Ref: Oracle Doc Section 9.7.4.2                        |"
echo "+===========================================================+"
echo -e "${NC}"
log "Script started. Log: ${LOGFILE}"
log "Test Master: ${TM_DB_NAME} (${TM_ORACLE_SID}) -> Snapshot: ${SNAP_DB_NAME} (${SNAP_ORACLE_SID})"

# ---------------------------------------------------------------------------
# Resolve SNAP_INDEX for this creation run.
#
# The index tracks which clone number this is within the current Test Master
# generation -- T0 for the first clone, T1 for the second from the same TM,
# etc.  When --refresh is run the counter resets to 0 (new generation).
#
# Counter file: ${WORK_DIR}/.snap_index_counter
#   - Holds the index that the NEXT creation run should use.
#   - Written at the end of a successful creation run (incremented by 1).
#   - Reset to 0 by R6 after a successful refresh.
#   - If --snap-index N was given on the CLI, the counter file is not read
#     or written; the explicit value is used as-is.
# ---------------------------------------------------------------------------
_SNAP_INDEX_COUNTER_FILE="${WORK_DIR}/.snap_index_counter"

if [[ -n "${_SNAP_INDEX_EXPLICIT:-}" ]]; then
    log "Snapshot clone index: T${SNAP_INDEX}  (explicit -- counter file not used)"
else
    # Read next index from counter file; default to 0 if file absent or corrupt
    if [[ -f "${_SNAP_INDEX_COUNTER_FILE}" ]]; then
        _ctr=$(cat "${_SNAP_INDEX_COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]')
        if [[ "${_ctr}" =~ ^[0-9]+$ ]]; then
            SNAP_INDEX="${_ctr}"
        else
            warn "Counter file '${_SNAP_INDEX_COUNTER_FILE}' is corrupt ('${_ctr}') -- defaulting to T0"
            SNAP_INDEX=0
        fi
    else
        SNAP_INDEX=0
    fi
    log "Snapshot clone index: T${SNAP_INDEX}  (from counter file -- next creation will be T$(( SNAP_INDEX + 1 )))"
fi

log "Sparse datafiles will end in _T${SNAP_INDEX}"

# Single creation step if requested
if [[ -n "${RUN_STEP}" ]]; then
    case "${RUN_STEP}" in
        0)  check_prerequisites ;;
        1)  step1_backup_controlfile_trace ;;
        2)  step2_generate_rename_script ;;
        3)  step3_create_tm_initora ;;
        4)  step4_shutdown_testmaster ;;
        5)  step5_create_snap_initora ;;
        6)  step6_build_controlfile_script ;;
        7)  step7_create_audit_dir ;;
        8)  step8_create_asm_dirs ;;
        9)  step9_startup_nomount ;;
        10) step10_create_controlfile ;;
        11) step11_rename_files ;;
        12) step12_open_resetlogs ;;
        13) step13_verify_cloned_files ;;
        14) step14_add_tempfile ;;
        *)  error "Invalid step: ${RUN_STEP}. Valid range: 0-14 (or R1-R6 with --refresh)" ;;
    esac
    exit 0
fi

# Run all creation steps in sequence
check_prerequisites
step1_backup_controlfile_trace
step2_generate_rename_script
step3_create_tm_initora
[[ "${SKIP_SHUTDOWN}" == "true" ]] && log "Skipping shutdown (--skip-shutdown specified)" || step4_shutdown_testmaster
step5_create_snap_initora
step6_build_controlfile_script
step7_create_audit_dir
step8_create_asm_dirs
step9_startup_nomount
step10_create_controlfile
step11_rename_files
step12_open_resetlogs
step13_verify_cloned_files
step14_add_tempfile

# All 14 steps succeeded.  Advance the counter so the next creation run from
# this same Test Master generation automatically uses the next index.
# (Only when not using an explicit --snap-index override.)
if [[ -z "${_SNAP_INDEX_EXPLICIT:-}" ]]; then
    _next_idx=$(( SNAP_INDEX + 1 ))
    echo "${_next_idx}" > "${_SNAP_INDEX_COUNTER_FILE}"
    log "Counter file updated: ${_SNAP_INDEX_COUNTER_FILE} -> ${_next_idx}  (next clone from this TM will be T${_next_idx})"
fi

print_summary