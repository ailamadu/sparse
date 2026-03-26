#!/bin/bash
# =============================================================================
#  Exadata Sparse Standby Automation Script
#  Version : v1.1
#
#  Reference : https://blogs.oracle.com/exadata/exadata-sparse-standby
#              Oracle Exadata System Software User Guide, Chapter 9
#
#  Description:
#    Enterprise-grade automation for the full Exadata Sparse Standby lifecycle:
#
#    PART A -- Sparse Standby Snapshot (Steps S1-S14)
#      Takes a point-in-time sparse snapshot of a live Active Data Guard
#      physical standby database. Stops redo apply, sets datafile ACLs to
#      READ ONLY, creates sparse child datafiles in the SPARSE diskgroup,
#      then restarts the standby and resumes redo apply.
#
#    PART B -- Hierarchical Sparse Clone Creation (Steps 1-14)
#      Creates read/write sparse clone databases from any Sparse Test Master
#      (including Sparse Standby databases created by Part A). Inherits the
#      full v10 creation cycle: backup control file trace, generate rename
#      SQL, init.ora patching, ASM directory creation, NOMOUNT startup,
#      controlfile creation, CLONEDB_RENAMEFILE, OPEN RESETLOGS, verification.
#
#    PART C -- Refresh / New Snapshot Cycle
#      Drops existing snapshot children, re-runs Part A to take the next
#      periodic sparse standby snapshot (advancing the _Tx chain index),
#      then re-runs Part B to create fresh clones from the new Test Master.
#
#  RAC Support:
#    Full RAC support via srvctl for standby database start/stop operations.
#
#  Cascaded Data Guard Support:
#    When CASCADED_STANDBY=true the script validates that the standby
#    receives redo from an upstream standby (not directly from primary)
#    and adjusts DGMGRL commands accordingly.
#
#  Usage:
#    ./exadata_sparse_standby_v3_dryrun_safe.sh [OPTIONS]
#    ./exadata_sparse_standby_v3_dryrun_safe.sh --config <config_file> [OPTIONS]
#
#  Pre-requisites:
#    - Exadata with SPARSE ASM disk group configured and ACL enabled
#    - Active Data Guard physical standby configured (stbydb)
#    - Oracle environment variables set (ORACLE_HOME, PATH, etc.)
#    - Run as oracle OS user with SYSDBA privileges
#    - grid OS user accessible via sudo or SSH for SYSASM/asmcmd operations
#    - python3 in PATH (used for init.ora patching)
#    - srvctl in PATH (used for RAC start/stop operations)
#
#  Security Standards:
#    - All config variables validated against strict allow-lists before use
#    - No hardcoded credentials; OS authentication (/ as sysdba/sysasm) only
#    - Execution lock prevents concurrent runs against same standby
#    - safe_exec wrapper enforces timeouts and records full audit trail
#    - Chain depth guard prevents exceeding Oracle's 10-link sparse limit
#    - ASM ACL pre-flight check before any permission changes
#    - All file paths checked for traversal; no shell metacharacters in vars
#
#  Logging:
#    Every step writes timestamped entries to:
#      ${WORK_DIR}/sparse_standby_YYYYMMDD_HHMMSS.log   (main log)
#      ${WORK_DIR}/safe_exec_audit.log                   (JSON audit trail)
#      ${WORK_DIR}/sparse_standby_chain.log              (chain depth history)
#    Structured step banners clearly delimit every operation.
#    All sqlplus/rman/dgmgrl/asmcmd output is captured and tee'd to the log.
# =============================================================================

# -----------------------------------------------------------------------------
# EARLY ARGUMENT PARSE: --config sourced BEFORE set -euo pipefail
# Runs in a plain loop with no strict mode so config files can use
# simple assignments without triggering unbound-variable errors.
# -----------------------------------------------------------------------------
for (( _ci=1; _ci<=$#; _ci++ )); do
    if [[ "${!_ci}" == "--config" ]]; then
        _cf_idx=$(( _ci + 1 ))
        _cf="${!_cf_idx}"
        if [[ ! -f "${_cf}" ]]; then
            echo "ERROR: Config file not found: ${_cf}" >&2
            exit 1
        fi
        source "${_cf}"
        echo "[INFO]  Config loaded: ${_cf}"
        unset _cf _cf_idx
        break
    fi
done
unset _ci

set -euo pipefail

# =============================================================================
# SECTION 1 -- CONFIGURATION
# All variables support override via --config file or environment.
# =============================================================================

# ---------------------------------------------------------------------------
# Standby Database (the DG Standby for Sparse Clones -- NOT your DR standby)
# ---------------------------------------------------------------------------
STBY_DB_NAME="${STBY_DB_NAME:-cdb19}"               # db_name (same as primary)
STBY_DB_UNIQUE_NAME="${STBY_DB_UNIQUE_NAME:-stbydb}" # db_unique_name
STBY_ORACLE_SID="${STBY_ORACLE_SID:-stbydb1}"        # First instance SID

# RAC: space-separated list of ALL instance SIDs.
# Single-instance: set this to just the one SID.
# e.g. "stbydb1 stbydb2"  or  "stbydb1"
STBY_INSTANCES="${STBY_INSTANCES:-stbydb1 stbydb2}"

# Primary database db_unique_name (used for DGMGRL verification)
PRIMARY_DB_UNIQUE_NAME="${PRIMARY_DB_UNIQUE_NAME:-pridb}"

# ---------------------------------------------------------------------------
# Cascaded Data Guard topology
# Set CASCADED_STANDBY=true when stbydb receives redo from another standby
# (not directly from primary). Script will validate the cascade chain.
# ---------------------------------------------------------------------------
CASCADED_STANDBY="${CASCADED_STANDBY:-false}"
CASCADE_SOURCE_DB_UNIQUE_NAME="${CASCADE_SOURCE_DB_UNIQUE_NAME:-}"  # upstream standby

# ---------------------------------------------------------------------------
# Test Master / Snapshot Database (the sparse clone created from the standby)
# ---------------------------------------------------------------------------
TM_DB_NAME="${TM_DB_NAME:-STBYDB}"
TM_DB_UNIQUE_NAME="${TM_DB_UNIQUE_NAME:-STBYDB}"
TM_ORACLE_SID="${TM_ORACLE_SID:-STBYDB1}"
TM_DATA_DG="${TM_DATA_DG:-+DATA}"

SNAP_DB_NAME="${SNAP_DB_NAME:-SNAPDEV}"
SNAP_DB_UNIQUE_NAME="${SNAP_DB_UNIQUE_NAME:-SNAPDEV}"
SNAP_ORACLE_SID="${SNAP_ORACLE_SID:-SNAPDEV1}"
SNAP_SPARSE_DG="${SNAP_SPARSE_DG:-+SPARSE}"
SNAP_DATA_DG="${SNAP_DATA_DG:-+DATA}"

# ---------------------------------------------------------------------------
# Oracle environment
# ---------------------------------------------------------------------------
ORACLE_HOME="${ORACLE_HOME:-/u01/app/oracle/product/19.0.0/dbhome_1}"
ORACLE_BASE="${ORACLE_BASE:-/u01/app/oracle}"
ORACLE_USER="${ORACLE_USER:-oracle}"

# Grid Infrastructure (ASM)
GRID_HOME="${GRID_HOME:-/u01/app/grid/product/19.0.0/grid}"
GRID_USER="${GRID_USER:-grid}"
ASM_SID="${ASM_SID:-+ASM1}"

# How to run commands as the grid OS user.
# Options: sudo | ssh | direct
ASM_EXEC_METHOD="${ASM_EXEC_METHOD:-sudo}"
ASM_SSH_KEY="${ASM_SSH_KEY:-/home/oracle/.ssh/id_rsa}"
ASM_SSH_HOST="${ASM_SSH_HOST:-localhost}"

SRVCTL_TIMEOUT="${SRVCTL_TIMEOUT:-600}"       # seconds for srvctl operations

# ---------------------------------------------------------------------------
# Data Guard / DGMGRL
# ---------------------------------------------------------------------------
DGMGRL_APPLY_WAIT_SECS="${DGMGRL_APPLY_WAIT_SECS:-120}"  # wait for apply lag
DGMGRL_APPLY_LAG_THRESHOLD="${DGMGRL_APPLY_LAG_THRESHOLD:-30}" # acceptable lag (seconds)

# ---------------------------------------------------------------------------
# Sparse chain depth guard
# Oracle's hard limit is 10 links in a sparse chain. We default to warning
# at 7 and aborting at 8 to leave headroom. Override via config.
# ---------------------------------------------------------------------------
SPARSE_CHAIN_WARN_DEPTH="${SPARSE_CHAIN_WARN_DEPTH:-7}"
SPARSE_CHAIN_MAX_DEPTH="${SPARSE_CHAIN_MAX_DEPTH:-8}"

# ---------------------------------------------------------------------------
# Working directories and log files
# ---------------------------------------------------------------------------
WORK_DIR="${WORK_DIR:-${ORACLE_BASE}/admin/${STBY_DB_UNIQUE_NAME}/sparse_standby}"
ADUMP_DIR="${ADUMP_DIR:-${ORACLE_BASE}/admin/${SNAP_DB_NAME,,}/adump}"

# Log file paths (LOGFILE is the main per-run log; CHAIN_LOG persists across runs)
LOGFILE="${LOGFILE:-${WORK_DIR}/sparse_standby_$(date +%Y%m%d_%H%M%S).log}"
CHAIN_LOG="${CHAIN_LOG:-${WORK_DIR}/sparse_standby_chain.log}"

# ---------------------------------------------------------------------------
# Snapshot creation parameters (Part B -- clone creation)
# ---------------------------------------------------------------------------
REDO_SIZE="${REDO_SIZE:-100M}"
REDO_BLOCKSIZE="${REDO_BLOCKSIZE:-512}"
REDO_GROUPS="${REDO_GROUPS:-2}"
TEMP_SIZE="${TEMP_SIZE:-10G}"
IS_CDB="${IS_CDB:-false}"
FORCE_SHUTDOWN="${FORCE_SHUTDOWN:-false}"
SNAP_CONTROL_FILE="${SNAP_CONTROL_FILE:-${SNAP_DATA_DG}/${SNAP_DB_NAME}/control1.f}"
SNAP_INDEX="${SNAP_INDEX:-0}"

# ---------------------------------------------------------------------------
# Refresh -- list of snapshot SIDs to drop before taking a new snapshot
# ---------------------------------------------------------------------------
SOURCE_DB_NAME="${SOURCE_DB_NAME:-${PRIMARY_DB_UNIQUE_NAME}}"
SNAP_SID_LIST="${SNAP_SID_LIST:-${SNAP_ORACLE_SID}}"
REFRESH_METHOD="${REFRESH_METHOD:-dataguard}"

# ---------------------------------------------------------------------------
# safe_exec tuning
# ---------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-false}"
SAFE_EXEC_TIMEOUT="${SAFE_EXEC_TIMEOUT:-300}"

# ---------------------------------------------------------------------------
# ASM disk group free-space thresholds (MB)
# ---------------------------------------------------------------------------
ASM_SPARSE_MIN_FREE_MB="${ASM_SPARSE_MIN_FREE_MB:-10240}"
ASM_DATA_MIN_FREE_MB="${ASM_DATA_MIN_FREE_MB:-5120}"

# Script version
SCRIPT_VERSION="v3"


# --- Runtime Safety Controls ---
ENABLE_RUNTIME_CHECKS="${ENABLE_RUNTIME_CHECKS:-true}"
FORCE_RUNTIME_OVERRIDE="${FORCE_RUNTIME_OVERRIDE:-false}"
SESSION_THRESHOLD="${SESSION_THRESHOLD:-0}"

# =============================================================================
# SECTION 2 -- LOGGING FRAMEWORK
# Every function writes timestamped, colour-coded, levelled entries.
# All output goes to both stdout and the LOGFILE.
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; NC='\033[0m'

# Ensure log directory exists before first write
_init_logdir() {
    mkdir -p "$(dirname "${LOGFILE}")" 2>/dev/null || true
    mkdir -p "$(dirname "${CHAIN_LOG}")" 2>/dev/null || true
}

log()     { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [INFO]    $*" | tee -a "${LOGFILE}"; }
success() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[OK]${NC}      $*" | tee -a "${LOGFILE}"; }
warn()    { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${NC}    $*" | tee -a "${LOGFILE}"; }
error() {
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    { echo -e "\n${RED}${BOLD}======================================================${NC}";
      echo -e "${RED}${BOLD}  FATAL ERROR${NC}";
      echo -e "${RED}${BOLD}======================================================${NC}";
      echo -e "${RED}${BOLD}  ${msg}${NC}";
      echo -e "${RED}${BOLD}======================================================${NC}\n"; } >&2
    printf '%s [ERROR]   %s\n' "${ts}" "${msg}" >> "${LOGFILE}" 2>/dev/null || true
    _FAILED_STEP="${_CURRENT_STEP:-unknown}"
    _SCRIPT_EXIT_CODE=1
    exit 1
}
debug()   { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG]   $*" | tee -a "${LOGFILE}"; }

# Step banner -- printed at the start of every major step
step() {
    local banner_text="  STEP $*"
    local sep="============================================================"
    echo -e "\n${CYAN}${BOLD}${sep}${NC}" | tee -a "${LOGFILE}"
    echo -e "${CYAN}${BOLD}${banner_text}${NC}"                             | tee -a "${LOGFILE}"
    echo -e "${CYAN}${BOLD}${sep}${NC}"                                     | tee -a "${LOGFILE}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [STEP]    ${banner_text}" >> "${LOGFILE}"
    _CURRENT_STEP="$*"
}

# Sub-step banner -- lighter visual for sub-operations within a step
substep() {
    echo -e "\n${MAGENTA}${BOLD}  >>> $*${NC}" | tee -a "${LOGFILE}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SUBSTEP] $*" >> "${LOGFILE}"
}

# Log a section divider (used between major parts)
section() {
    local txt="$*"
    echo -e "\n${BOLD}################################################################${NC}" | tee -a "${LOGFILE}"
    echo -e "${BOLD}##  ${txt}${NC}"                                                        | tee -a "${LOGFILE}"
    echo -e "${BOLD}################################################################${NC}"   | tee -a "${LOGFILE}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [SECTION] ${txt}" >> "${LOGFILE}"
}

# Log a command output block verbatim (with a label)
log_output() {
    local label="$1"
    local content="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [OUTPUT]  --- BEGIN ${label} ---" >> "${LOGFILE}"
    echo "${content}"                                                      >> "${LOGFILE}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [OUTPUT]  --- END ${label} ---"   >> "${LOGFILE}"
}

# Write an entry to the persistent chain log (survives across runs)
log_chain_event() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "${CHAIN_LOG}"
}

# =============================================================================
# SECTION 2b -- ROLLBACK REGISTRY
# Steps that mutate live state push a compensating command here immediately
# after the mutation succeeds.  On any unexpected exit, run_rollbacks executes
# them in LIFO order so the standby is returned to a known, safe state.
#
# Design rules enforced throughout this script:
#   1. Register the rollback AFTER the mutation succeeds (not before).
#   2. Pre-generate any SQL or data the rollback needs while the DB is live.
#      Save those artifacts to WORK_DIR.  The rollback command must be
#      self-contained -- it cannot rely on the DB being reachable.
#   3. If a rollback step itself needs the DB, account for that explicitly
#      (e.g. the S4 rollback restarts the standby before doing anything else).
#   4. Rollbacks only fire when _SCRIPT_EXIT_CODE != 0.  A clean successful
#      run never triggers any rollback action.
# =============================================================================

_ROLLBACK_LABELS=()
_ROLLBACK_CMDS=()

register_rollback() {
    local label="$1" cmd="$2"
    _ROLLBACK_LABELS+=( "${label}" )
    _ROLLBACK_CMDS+=( "${cmd}" )
    debug "[rollback] registered: ${label}"
}

run_rollbacks() {
    local n="${#_ROLLBACK_CMDS[@]}"
    [[ "${n}" -eq 0 ]] && return 0

    { echo -e "\n${YELLOW}${BOLD}======================================================${NC}";
      echo -e "${YELLOW}${BOLD}  ROLLBACK SEQUENCE (${n} action(s), LIFO order)${NC}";
      echo -e "${YELLOW}${BOLD}======================================================${NC}"; } >&2
    printf '%s [ROLLBACK] Initiating %d rollback action(s)\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${n}" >> "${LOGFILE}" 2>/dev/null || true

    # Run in the CURRENT shell via eval so all script functions are in scope.
    # set +e around each action so one failure does not abort the rest.
    local i rc _rb_any_failed=0
    for (( i = n-1; i >= 0; i-- )); do
        local lbl="${_ROLLBACK_LABELS[$i]}"
        local cmd="${_ROLLBACK_CMDS[$i]}"
        echo -e "${YELLOW}  [ROLLBACK] ${lbl}${NC}" >&2
        printf '%s [ROLLBACK] START label=%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "${lbl}" >> "${LOGFILE}" 2>/dev/null || true
        rc=0
        set +e
        { eval "${cmd}"; } >> "${LOGFILE}" 2>&1
        rc=$?
        set -e
        if [[ ${rc} -ne 0 ]]; then
            echo -e "${RED}  [ROLLBACK] ${lbl}: FAILED (rc=${rc}) -- manual intervention required${NC}" >&2
            printf '%s [ROLLBACK] FAILED rc=%d label=%s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "${rc}" "${lbl}" >> "${LOGFILE}" 2>/dev/null || true
            _rb_any_failed=1
        else
            echo -e "${GREEN}  [ROLLBACK] ${lbl}: OK${NC}" >&2
            printf '%s [ROLLBACK] OK label=%s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "${lbl}" >> "${LOGFILE}" 2>/dev/null || true
        fi
    done

    { echo -e "${YELLOW}${BOLD}  Review rollback results in: ${LOGFILE}${NC}";
      echo -e "${YELLOW}${BOLD}======================================================${NC}\n"; } >&2
}

clear_rollbacks() {
    _ROLLBACK_LABELS=()
    _ROLLBACK_CMDS=()
}


# Provides dry-run, timeout, retry, and structured JSON audit logging
# for every destructive or external command in this script.
# =============================================================================

_SAFE_EXEC_AUDIT_LOG_RESOLVED=""

_safe_exec_audit_log() {
    if [[ -z "${_SAFE_EXEC_AUDIT_LOG_RESOLVED}" ]]; then
        local alog="${SAFE_EXEC_AUDIT_LOG:-${WORK_DIR}/safe_exec_audit.log}"
        mkdir -p "$(dirname "${alog}")" 2>/dev/null || true
        _SAFE_EXEC_AUDIT_LOG_RESOLVED="${alog}"
    fi
    echo "${_SAFE_EXEC_AUDIT_LOG_RESOLVED}"
}

_safe_exec_write_audit() {
    local status="$1" duration="$2" label="$3" cmd="$4"
    local alog ts
    alog="$(_safe_exec_audit_log)"
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '{"ts":"%s","pid":%d,"label":"%s","status":"%s","duration_s":%s,"command":"%s"}\n' \
        "${ts}" "$$" \
        "${label//\"/\\\"}" \
        "${status}" \
        "${duration}" \
        "${cmd//\"/\\\"}" \
        >> "${alog}" 2>/dev/null || true
}

# safe_exec [-l LABEL] [-t TIMEOUT] [-r RETRIES] [-w WAIT] -- CMD [ARGS]
safe_exec() {
    local label="" timeout="${SAFE_EXEC_TIMEOUT}" retries=0 wait_secs=5
    local opt OPTIND=1

    while getopts ":l:t:r:w:" opt; do
        case "${opt}" in
            l) label="${OPTARG}" ;;
            t) timeout="${OPTARG}" ;;
            r) retries="${OPTARG}" ;;
            w) wait_secs="${OPTARG}" ;;
            :) error "safe_exec: option -${OPTARG} requires an argument" ;;
            ?) error "safe_exec: unknown option -${OPTARG}" ;;
        esac
    done
    shift $(( OPTIND - 1 ))
    [[ "${1:-}" == "--" ]] && shift
    [[ $# -eq 0 ]] && error "safe_exec: no command supplied"

    local cmd_display="$*"
    [[ -z "${label}" ]] && label="${1}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log  "[DRY-RUN] ${label}: ${cmd_display}"
        _safe_exec_write_audit "DRY-RUN" "0" "${label}" "${cmd_display}"
        return 0
    fi

    local attempt=0 rc=0 t_start t_end elapsed
    local max_attempts=$(( retries + 1 ))

    while (( attempt < max_attempts )); do
        attempt=$(( attempt + 1 ))
        if (( attempt > 1 )); then
            warn "[safe_exec] ${label}: retry ${attempt}/${max_attempts} (sleeping ${wait_secs}s)..."
            sleep "${wait_secs}"
        fi

        log "[safe_exec] ${label} (attempt ${attempt}/${max_attempts}, timeout ${timeout}s)"
        debug "[safe_exec] command: ${cmd_display}"
        t_start=$(date +%s)

        rc=0
        timeout "${timeout}" bash -c "$*" || rc=$?

        t_end=$(date +%s)
        elapsed=$(( t_end - t_start ))

        if [[ ${rc} -eq 124 ]]; then
            _safe_exec_write_audit "TIMEOUT" "${elapsed}" "${label}" "${cmd_display}"
            error "[safe_exec] ${label}: command timed out after ${timeout}s\n  Command: ${cmd_display}"
        fi

        if [[ ${rc} -ne 0 ]]; then
            _safe_exec_write_audit "FAILED(rc=${rc})" "${elapsed}" "${label}" "${cmd_display}"
            if (( attempt < max_attempts )); then
                warn "[safe_exec] ${label}: failed (rc=${rc}) after ${elapsed}s -- will retry"
                continue
            else
                error "[safe_exec] ${label}: failed (rc=${rc}) after ${elapsed}s (${attempt}/${max_attempts} attempts)\n  Command: ${cmd_display}"
            fi
        fi

        _safe_exec_write_audit "OK" "${elapsed}" "${label}" "${cmd_display}"
        log "[safe_exec] ${label}: completed in ${elapsed}s"
        return 0
    done
}

_safe_exec_banner() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${YELLOW}${BOLD}"
        echo "  ╔══════════════════════════════════════════════════════╗"
        echo "  ║   DRY-RUN MODE ACTIVE -- no commands will execute   ║"
        echo "  ╚══════════════════════════════════════════════════════╝"
        echo -e "${NC}"
    fi
    log "safe_exec audit log : $(_safe_exec_audit_log)"
    log "safe_exec timeout   : ${SAFE_EXEC_TIMEOUT}s"
    log "Dry-run mode        : ${DRY_RUN}"
}

# =============================================================================
# SECTION 4 -- EXECUTION LOCK
# Prevents concurrent runs against the same standby / WORK_DIR.
# Lock is held on fd 201 for the full process lifetime; released on any exit.
# =============================================================================

_EXEC_LOCK_FILE=""
_EXEC_LOCK_FD=201

acquire_execution_lock() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "Execution lock: skipped (--dry-run mode)"
        return 0
    fi

    _EXEC_LOCK_FILE="${WORK_DIR}/.exec_lock_${STBY_DB_UNIQUE_NAME}"
    exec 201>"${_EXEC_LOCK_FILE}"

    if flock -n 201; then
        printf '%d mode=%s%s started=%s\n' \
            "$$" "${MODE}" "${RUN_STEP:+/step=${RUN_STEP}}" \
            "$(date '+%Y-%m-%dT%H:%M:%S')" \
            >"${_EXEC_LOCK_FILE}"
        log "Execution lock acquired: ${_EXEC_LOCK_FILE} (PID=$$, mode=${MODE})"
        return 0
    fi

    local lock_line stale_pid stale_mode stale_started
    lock_line=$(cat "${_EXEC_LOCK_FILE}" 2>/dev/null || true)
    stale_pid=$(echo "${lock_line}"     | grep -oE '^[0-9]+' || true)
    stale_mode=$(echo "${lock_line}"    | grep -oE 'mode=[^ ]+' | cut -d= -f2 || true)
    stale_started=$(echo "${lock_line}" | grep -oE 'started=[^ ]+' | cut -d= -f2 || true)

    if [[ -n "${stale_pid}" ]] && ! kill -0 "${stale_pid}" 2>/dev/null; then
        warn "Stale execution lock (PID ${stale_pid} dead) -- breaking and re-acquiring"
        : > "${_EXEC_LOCK_FILE}"
        exec 201>"${_EXEC_LOCK_FILE}"
        if ! flock -n 201; then
            error "Could not acquire execution lock after stale-PID cleanup. Retry in a moment."
        fi
        printf '%d mode=%s%s started=%s (recovered-stale-lock)\n' \
            "$$" "${MODE}" "${RUN_STEP:+/step=${RUN_STEP}}" \
            "$(date '+%Y-%m-%dT%H:%M:%S')" >"${_EXEC_LOCK_FILE}"
        log "Execution lock acquired (recovered from stale lock)"
        return 0
    fi

    echo "" >&2
    echo -e "${RED}${BOLD}ERROR: Concurrent execution blocked${NC}" >&2
    [[ -n "${stale_pid}"     ]] && echo -e "  Blocking PID   : ${BOLD}${stale_pid}${NC}" >&2
    [[ -n "${stale_mode}"    ]] && echo -e "  Blocking mode  : ${BOLD}${stale_mode}${NC}" >&2
    [[ -n "${stale_started}" ]] && echo -e "  Running since  : ${BOLD}${stale_started}${NC}" >&2
    echo -e "  Lock file      : ${BOLD}${_EXEC_LOCK_FILE}${NC}" >&2
    exit 1
}

release_execution_lock() {
    if [[ "${DRY_RUN}" == "true" ]] || [[ -z "${_EXEC_LOCK_FILE}" ]]; then
        return 0
    fi
    flock -u 201 2>/dev/null || true
    : > "${_EXEC_LOCK_FILE}"
    # Only log the release on a clean exit; on error exit the message
    # would print AFTER the error banner and visually bury the error.
    if [[ "${_SCRIPT_EXIT_CODE:-0}" -eq 0 ]]; then
        log "Execution lock released: ${_EXEC_LOCK_FILE}"
    fi
}

# =============================================================================
# SECTION 5 -- DATABASE HELPER FUNCTIONS
# All database interactions go through these helpers. Every helper:
#   - Captures full output and tee's to log
#   - Checks for ORA-/SP2-/RMAN-/DGM- errors in output
#   - Returns output for callers that need to parse results
# =============================================================================

# sqlplus_check SID SQL [LABEL]
sqlplus_check() {
    local sid="$1" sql="$2" label="${3:-sqlplus}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] sqlplus on SID=${sid}"
        echo "${sql}" >> "${LOGFILE}"
        return 0
    fi

    local out rc
    log "[${label}] Running SQL on SID=${sid}"
    debug "[${label}] SQL: $(echo "${sql}" | head -3 | tr '\n' ' ')..."
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
    [[ -n "${out}" ]] && log_output "${label}" "${out}"
    if [[ ${rc} -ne 0 ]]; then
        error "[${label}] sqlplus exited with code ${rc}\n${out}"
    fi
    local err_lines
    err_lines=$(echo "${out}" | grep -E "^ORA-[0-9]+|^SP2-[0-9]+|^ERROR at line [0-9]" || true)
    if [[ -n "${err_lines}" ]]; then
        error "[${label}] Oracle error detected:\n${err_lines}"
    fi
    echo "${out}"
}

# sqlplus_verbose_check SID SQL [LABEL]  -- for DDL/STARTUP/SHUTDOWN with ECHO ON
sqlplus_verbose_check() {
    local sid="$1" sql="$2" label="${3:-sqlplus}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] sqlplus verbose on SID=${sid}"
        echo "${sql}" >> "${LOGFILE}"
        return 0
    fi

    local out rc
    log "[${label}] Running verbose SQL on SID=${sid}"
    out=$(ORACLE_SID="${sid}" "${ORACLE_HOME}/bin/sqlplus" / as sysdba 2>&1 <<EOF
${sql}
EXIT
EOF
)
    rc=$?
    [[ -n "${out}" ]] && log_output "${label}" "${out}"
    if [[ ${rc} -ne 0 ]]; then
        error "[${label}] sqlplus exited with code ${rc}\n${out}"
    fi
    local err_lines
    err_lines=$(echo "${out}" | grep -E "^ORA-[0-9]+|^SP2-[0-9]+|^ERROR at line [0-9]" || true)
    if [[ -n "${err_lines}" ]]; then
        error "[${label}] Oracle error detected:\n${err_lines}"
    fi
    echo "${out}"
}

# spool_sql_from_query SID DEST_FILE SELECT_SQL [LABEL]
# Runs a SELECT that emits SQL statements, spools to DEST_FILE, cleans junk
# lines, validates for ORA- errors, and returns the count of output lines.
# Eliminates the repeated SET block + sed + ORA-check pattern in S2/S3/step2/R2.
spool_sql_from_query() {
    local sid="$1" dest="$2" select_sql="$3" label="${4:-spool}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] Would spool SQL to ${dest}"
        echo "-- DRY RUN" > "${dest}"
        return 0
    fi

    log "[${label}] Spooling query output to ${dest} from SID=${sid}"
    sqlplus_check "${sid}" "
SET NEWPAGE 0
SET LINESIZE 999
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET ECHO OFF
SET SPACE 0
SET TAB OFF
SET TRIMSPOOL ON
SPOOL ${dest}
${select_sql}
SPOOL OFF" "${label}" > /dev/null

    sed -i '/^[[:space:]]*$/d;/^SQL>/d;/^Disconnected/d' "${dest}" 2>/dev/null || true

    [[ -f "${dest}" ]] || error "[${label}] Spool file was not created: ${dest}"
    if grep -qE "^ORA-[0-9]+" "${dest}" 2>/dev/null; then
        local spool_err_lines
        spool_err_lines=$(grep -E "^ORA-[0-9]+" "${dest}")
        error "[${label}] ORA- error found in spool output:\n${spool_err_lines}"
    fi

    local line_count
    line_count=$(wc -l < "${dest}" 2>/dev/null || echo 0)
    echo "${line_count}"
}

# rman_check SID CMDS [LABEL]
rman_check() {
    local sid="$1" cmds="$2" label="${3:-rman}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] RMAN execution"
        echo "${cmds}" >> "${LOGFILE}"
        return 0
    fi

    local out rc
    log "[${label}] Running RMAN on SID=${sid}"
    out=$(ORACLE_SID="${sid}" "${ORACLE_HOME}/bin/rman" target / 2>&1 <<EOF
${cmds}
EOF
)
    rc=$?
    [[ -n "${out}" ]] && log_output "${label}" "${out}"
    if [[ ${rc} -ne 0 ]]; then
        error "[${label}] RMAN exited with code ${rc}\n${out}"
    fi
    local err_lines
    err_lines=$(echo "${out}" | grep -E "^RMAN-[0-9]+|^ORA-[0-9]+" || true)
    if [[ -n "${err_lines}" ]]; then
        error "[${label}] RMAN/Oracle error detected:\n${err_lines}"
    fi
    echo "${out}"
}

# dgmgrl_check CMDS [LABEL]
dgmgrl_check() {
    local cmds="$1" label="${2:-dgmgrl}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] DGMGRL execution"
        echo "${cmds}" >> "${LOGFILE}"
        return 0
    fi

    local out rc
    log "[${label}] Running DGMGRL commands"
    debug "[${label}] DGMGRL: $(echo "${cmds}" | head -3 | tr '\n' ' ')..."
    out=$("${ORACLE_HOME}/bin/dgmgrl" -silent / 2>&1 <<EOF
CONNECT /;
${cmds}
EXIT;
EOF
)
    rc=$?
    [[ -n "${out}" ]] && log_output "${label}" "${out}"
    if [[ ${rc} -ne 0 ]]; then
        error "[${label}] dgmgrl exited with code ${rc}\n${out}"
    fi
    local err_lines
    err_lines=$(echo "${out}" | grep -iE "^ORA-[0-9]+|^DGM-[0-9]+|^Error:" || true)
    if [[ -n "${err_lines}" ]]; then
        error "[${label}] DGMGRL error detected:\n${err_lines}"
    fi
    echo "${out}"
}

# verify_db_status SID EXPECTED [LABEL]
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
    log "[${label}] DB status check: expected='${expected}' actual='${actual}'"
    if [[ "${actual}" != "${expected}" ]]; then
        error "[${label}] Expected DB status '${expected}' but found '${actual}'"
    fi
    success "[${label}] DB status confirmed: ${actual}"
}

# get_db_status SID  -- returns status string without failing
# sqlplus exits 0 even when the instance is DOWN (ORA-01034), so we cannot
# rely on the exit code alone.  We validate the output against the known set
# of V$INSTANCE STATUS values; anything else (ORA- blob, empty, SP2-) is
# treated as DOWN.
get_db_status() {
    local sid="$1"
    local raw
    raw=$(ORACLE_SID="${sid}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba 2>/dev/null <<'EOF' | tr -d ' \n\r'
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SELECT STATUS FROM V$INSTANCE;
EXIT
EOF
) || raw=""

    case "${raw}" in
        STARTED|MOUNTED|OPEN|OPENMIGRATE)
            echo "${raw}" ;;
        *)
            # Covers: empty string, ORA-01034 blob, SP2- errors, or any
            # other unexpected output -- instance is not reachable.
            echo "DOWN" ;;
    esac
}

# =============================================================================
# SECTION 6 -- ASM / GRID HELPER FUNCTIONS
# =============================================================================

run_as_grid() {
    local cmd="$1"
																		
																	
    log "[grid-exec] Method=${ASM_EXEC_METHOD}: ${cmd}" >&2
    case "${ASM_EXEC_METHOD}" in
        sudo)
            sudo -u "${GRID_USER}" bash -c "${cmd}"
            ;;
        ssh)
            ssh -n -i "${ASM_SSH_KEY}" \
                -o BatchMode=yes \
                -o StrictHostKeyChecking=accept-new \
                "${GRID_USER}@${ASM_SSH_HOST}" "${cmd}"
            ;;
        direct)
            bash -c "${cmd}"
            ;;
        *)
            error "Unknown ASM_EXEC_METHOD: '${ASM_EXEC_METHOD}'. Use: sudo | ssh | direct"
            ;;
    esac
}

run_sqlplus_asm() {
    local sql="$1" label="${2:-sysasm}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] SYSASM SQL"
        echo "${sql}"
        return 0
    fi

    local sqlplus_bin="${GRID_HOME}/bin/sqlplus"
    [[ ! -x "${sqlplus_bin}" ]] && sqlplus_bin="${ORACLE_HOME}/bin/sqlplus"

    local tmpf asm_out asm_rc
    tmpf=$(mktemp /tmp/sysasm_XXXXXX.sql)
    printf '%s\nEXIT\n' "${sql}" > "${tmpf}"
    chmod 644 "${tmpf}"

    log "[${label}] Running SQL as SYSASM (ORACLE_SID=${ASM_SID})" >&2
    debug "[${label}] SQL: $(echo "${sql}" | head -3 | tr '\n' ' ')..." >&2
    asm_out=$(run_as_grid "ORACLE_SID=${ASM_SID} ${sqlplus_bin} -S / as sysasm @${tmpf}" 2>&1)
    asm_rc=$?
    rm -f "${tmpf}"
    [[ -n "${asm_out}" ]] && log_output "${label}" "${asm_out}"
    if [[ ${asm_rc} -ne 0 ]]; then
        error "[${label}]: sqlplus sysasm exited with code ${asm_rc}\n${asm_out}"
    fi
    local asm_err_lines
    asm_err_lines=$(echo "${asm_out}" | grep -E "^ORA-[0-9]+|^SP2-[0-9]+" || true)
    if [[ -n "${asm_err_lines}" ]]; then
        error "[${label}]: Oracle error detected in sysasm output:\n${asm_err_lines}"
    fi
    return 0
}

# run_sqlfile_asm FILEPATH [LABEL]
# Executes an existing SQL file via SYSASM using run_as_grid.
# Use this when the SQL is already on disk (e.g. generated by spool_sql_from_query).
# Use run_sqlplus_asm when passing an inline SQL string.
run_sqlfile_asm() {
    local filepath="$1" label="${2:-sysasm-file}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] SYSASM file execution: ${filepath}"
        return 0
    fi

    [[ -f "${filepath}" ]] || error "[${label}]: SQL file not found: ${filepath}"

    local sqlplus_bin="${GRID_HOME}/bin/sqlplus"
    [[ ! -x "${sqlplus_bin}" ]] && sqlplus_bin="${ORACLE_HOME}/bin/sqlplus"

    log "[${label}] Running SQL file as SYSASM: ${filepath} (ORACLE_SID=${ASM_SID})" >&2
    local asm_out asm_rc
    asm_out=$(run_as_grid "ORACLE_SID=${ASM_SID} ${sqlplus_bin} -S / as sysasm @${filepath}" 2>&1)
    asm_rc=$?
    [[ -n "${asm_out}" ]] && log_output "${label}" "${asm_out}"
    if [[ ${asm_rc} -ne 0 ]]; then
        error "[${label}]: sqlplus sysasm exited with code ${asm_rc}
${asm_out}"
    fi
    local asm_err_lines
    asm_err_lines=$(echo "${asm_out}" | grep -E "^ORA-[0-9]+|^SP2-[0-9]+" || true)
    if [[ -n "${asm_err_lines}" ]]; then
        error "[${label}]: Oracle error in sysasm output:
${asm_err_lines}"
    fi
    return 0
}

_resolve_asmcmd_bin() {
    local asmcmd_bin="${GRID_HOME}/bin/asmcmd"
    [[ ! -x "${asmcmd_bin}" ]] && asmcmd_bin="${ORACLE_HOME}/bin/asmcmd"
    [[ ! -x "${asmcmd_bin}" ]] && error "asmcmd not found in GRID_HOME or ORACLE_HOME"
    echo "${asmcmd_bin}"
}

run_asmcmd() {
    local asmcmd_cmd="$1"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] asmcmd: ${asmcmd_cmd}"
        return 0
    fi

    local asmcmd_bin
    asmcmd_bin="$(_resolve_asmcmd_bin)"

    local tmpf output rc
    tmpf=$(mktemp /tmp/asmcmd_XXXXXX.cmd)
    printf '%s\n' "${asmcmd_cmd}" > "${tmpf}"
    chmod 644 "${tmpf}"

    log "[asmcmd] ${asmcmd_cmd}" >&2
    output=$(run_as_grid "ORACLE_SID=${ASM_SID} ${asmcmd_bin} < ${tmpf}" 2>&1)
    rc=$?
    rm -f "${tmpf}"
    [[ -n "${output}" ]] && log_output "asmcmd" "${output}"

    if echo "${output}" | grep -qE "ASMCMD-[0-9]+"; then
        error "asmcmd command failed: ${asmcmd_cmd}. See error above."
    fi
    if [[ ${rc} -ne 0 ]]; then
        error "asmcmd exited with code ${rc} for: ${asmcmd_cmd}"
    fi
    return 0
}

asmcmd_mkdir() {
    # Creates a full ASM path one component at a time.
    # The disk group root (+DG) is never attempted -- asmcmd cannot create
    # a disk group and it always pre-exists.
    # Intermediate components that already exist are silently skipped
    # (ASMCMD-08542 / ASMCMD-8016 / ASMCMD-9456 all mean "already exists").
    local full_path="$1"
    local asmcmd_bin
    asmcmd_bin="$(_resolve_asmcmd_bin)"

    # Strip leading '+', split on '/'
    local stripped="${full_path#+}"
    local IFS='/'
    local parts=( ${stripped} )
    unset IFS

    # parts[0] is the disk group name (e.g. SPARSE) -- skip it, always pre-exists.
    # Start building the path from parts[1] onward.
    local dg_root="+${parts[0]}"
    local current_path="${dg_root}"

    local i
    for (( i=1; i<${#parts[@]}; i++ )); do
        local part="${parts[$i]}"
        [[ -z "${part}" ]] && continue
        current_path="${current_path}/${part}"

        if [[ "${DRY_RUN}" == "true" ]]; then
            log "[DRY-RUN] asmcmd mkdir ${current_path}"
            continue
        fi

        local tmpf output rc
        tmpf=$(mktemp /tmp/asmcmd_XXXXXX.cmd)
        printf 'mkdir %s\n' "${current_path}" > "${tmpf}"
        chmod 644 "${tmpf}"

        log "  asmcmd mkdir ${current_path}" >&2
        output=$(run_as_grid "ORACLE_SID=${ASM_SID} ${asmcmd_bin} < ${tmpf}" 2>&1)
        rc=$?
        rm -f "${tmpf}"

        [[ -n "${output}" ]] && log_output "asmcmd-mkdir" "${output}"

        # These codes all mean the directory already exists -- safe to skip
        if echo "${output}" | grep -qE "ASMCMD-(08542|8542|8016|9456)"; then
            log "  ${current_path} already exists -- skipping"
            continue
        fi

        if echo "${output}" | grep -qE "ASMCMD-[0-9]+"; then
            error "asmcmd mkdir failed for ${current_path} -- see output above"
        fi

        if [[ ${rc} -ne 0 ]]; then
            error "asmcmd mkdir exited with code ${rc} for ${current_path}"
        fi

        log "  ${current_path} created OK"
    done
}
# =============================================================================
# SECTION 7 -- SRVCTL HELPERS (RAC)
# All RAC start/stop operations use srvctl so Oracle Clusterware properly
# manages the instances.
# =============================================================================

# srvctl_stop_database DB_UNIQUE_NAME [STOP_OPTION]
srvctl_stop_database() {
    local db_uname="$1" stop_opt="${2:-normal}"
    log "[srvctl] Stopping database ${db_uname} with option=${stop_opt}"
    safe_exec -l "srvctl-stop-db-${db_uname}" -t "${SRVCTL_TIMEOUT}" -- \
        "'${ORACLE_HOME}/bin/srvctl' stop database -d '${db_uname}' -o '${stop_opt}'"
    success "[srvctl] Database ${db_uname} stopped"
}

# srvctl_start_instance DB_UNIQUE_NAME INSTANCE [START_OPTION]
srvctl_start_instance() {
    local db_uname="$1" instance="$2" start_opt="${3:-open}"
    log "[srvctl] Starting instance ${instance} of ${db_uname} with option=${start_opt}"
    safe_exec -l "srvctl-start-inst-${instance}" -t "${SRVCTL_TIMEOUT}" -- \
        "'${ORACLE_HOME}/bin/srvctl' start database -d '${db_uname}' -o '${start_opt}'"
        #"'${ORACLE_HOME}/bin/srvctl' start instance -d '${db_uname}' -i '${instance}' -o '${start_opt}'"
    success "[srvctl] Instance ${instance} started (${start_opt})"
}

# srvctl_start_database DB_UNIQUE_NAME [START_OPTION]
srvctl_start_database() {
    local db_uname="$1" start_opt="${2:-open}"
    log "[srvctl] Starting database ${db_uname} with option=${start_opt}"
    safe_exec -l "srvctl-start-db-${db_uname}" -t "${SRVCTL_TIMEOUT}" -- \
        "'${ORACLE_HOME}/bin/srvctl' start database -d '${db_uname}' -o '${start_opt}'"
    success "[srvctl] Database ${db_uname} started (${start_opt})"
}

# shutdown_standby_db -- RAC standby shutdown via srvctl
shutdown_standby_db() {
    local db_uname="${STBY_DB_UNIQUE_NAME}"
    substep "Shutting down standby database: ${db_uname}"

    log "RAC shutdown via srvctl (option=normal)"
    srvctl_stop_database "${db_uname}" "normal"
    success "Standby database shutdown complete"
}

# start_standby_first_instance_mount -- start only the first (apply) instance in MOUNT
start_standby_first_instance_mount() {
    local first_inst="${STBY_ORACLE_SID}"
    substep "Starting first standby instance in MOUNT: ${first_inst}"

    log "RAC: starting instance ${first_inst} in mount via srvctl"
    srvctl_start_instance "${STBY_DB_UNIQUE_NAME}" "${first_inst}" "mount"
    [[ "${DRY_RUN}" == "true" ]] || verify_db_status "${first_inst}" "MOUNTED" "start-mount"
    success "First standby instance in MOUNT: ${first_inst}"
}

# start_remaining_standby_instances -- start all other RAC instances
start_remaining_standby_instances() {
    substep "Starting remaining standby RAC instances"
    log "STBY_INSTANCES=${STBY_INSTANCES}"

    local started=0
    for inst in ${STBY_INSTANCES}; do
        [[ "${inst}" == "${STBY_ORACLE_SID}" ]] && continue   # already started in mount
        log "Starting instance: ${inst}"
        srvctl_start_instance "${STBY_DB_UNIQUE_NAME}" "${inst}" "open"
        (( started++ )) || true
    done
    log "Additional instances started: ${started}"
    success "All remaining standby instances started"
}

# =============================================================================
# SECTION 8 -- CONFIGURATION VALIDATION
# All externally-sourced config variables are validated against strict
# allow-lists before being used in shell commands, SQL, or file paths.
# Guards against command injection through malicious config files.
# =============================================================================

validate_config_vars() {
    local err=0

    _assert_safe_name() {
        local var="$1" val="$2"
        if [[ ! "${val}" =~ ^[A-Za-z0-9_]+$ ]]; then
            echo "ERROR: ${var}='${val}' -- only A-Z a-z 0-9 _ allowed" >&2; err=1
        fi
    }
    _assert_asm_dg() {
        local var="$1" val="$2"
        if [[ ! "${val}" =~ ^\+[A-Za-z0-9_]+$ ]]; then
            echo "ERROR: ${var}='${val}' -- expected +NAME" >&2; err=1
        fi
    }
    _assert_safe_path() {
        local var="$1" val="$2"
        if [[ ! "${val}" =~ ^[A-Za-z0-9/_.\\-]+$ ]] || [[ "${val}" == *".."* ]]; then
            echo "ERROR: ${var}='${val}' -- invalid path characters or traversal" >&2; err=1
        fi
    }
    _assert_safe_host() {
        local var="$1" val="$2"
        if [[ ! "${val}" =~ ^[A-Za-z0-9._-]+$ ]]; then
            echo "ERROR: ${var}='${val}' -- not a valid hostname/IP" >&2; err=1
        fi
    }
    _assert_uint() {
        local var="$1" val="$2"
        if [[ ! "${val}" =~ ^[0-9]+$ ]]; then
            echo "ERROR: ${var}='${val}' -- must be a non-negative integer" >&2; err=1
        fi
    }
    _assert_size() {
        local var="$1" val="$2"
        if [[ ! "${val}" =~ ^[0-9]+[KMGTkmgt]$ ]]; then
            echo "ERROR: ${var}='${val}' -- must be e.g. 100M or 10G" >&2; err=1
        fi
    }
    _assert_one_of() {
        local var="$1" val="$2"; shift 2
        local opt found=0
        for opt in "$@"; do [[ "${val}" == "${opt}" ]] && found=1 && break; done
        if [[ ${found} -eq 0 ]]; then
            echo "ERROR: ${var}='${val}' -- must be one of: $*" >&2; err=1
        fi
    }

    # Standby / primary names
    _assert_safe_name  STBY_DB_NAME               "${STBY_DB_NAME}"
    _assert_safe_name  STBY_DB_UNIQUE_NAME         "${STBY_DB_UNIQUE_NAME}"
    _assert_safe_name  STBY_ORACLE_SID             "${STBY_ORACLE_SID}"
    _assert_safe_name  PRIMARY_DB_UNIQUE_NAME      "${PRIMARY_DB_UNIQUE_NAME}"
    # Validate each instance SID in STBY_INSTANCES
    for _inst in ${STBY_INSTANCES}; do
        _assert_safe_name "STBY_INSTANCES[${_inst}]" "${_inst}"
    done
    # Snapshot names
    _assert_safe_name  TM_DB_NAME                  "${TM_DB_NAME}"
    _assert_safe_name  TM_DB_UNIQUE_NAME            "${TM_DB_UNIQUE_NAME}"
    _assert_safe_name  TM_ORACLE_SID                "${TM_ORACLE_SID}"
    _assert_safe_name  SNAP_DB_NAME                 "${SNAP_DB_NAME}"
    _assert_safe_name  SNAP_DB_UNIQUE_NAME           "${SNAP_DB_UNIQUE_NAME}"
    _assert_safe_name  SNAP_ORACLE_SID               "${SNAP_ORACLE_SID}"
    _assert_safe_name  ORACLE_USER                  "${ORACLE_USER}"
    _assert_safe_name  GRID_USER                    "${GRID_USER}"
    _assert_safe_name  ASM_SID                      "${ASM_SID//+/}"
    # Disk groups
    _assert_asm_dg     TM_DATA_DG                  "${TM_DATA_DG}"
    _assert_asm_dg     SNAP_SPARSE_DG               "${SNAP_SPARSE_DG}"
    _assert_asm_dg     SNAP_DATA_DG                 "${SNAP_DATA_DG}"
    # Paths
    _assert_safe_path  ORACLE_HOME                  "${ORACLE_HOME}"
    _assert_safe_path  ORACLE_BASE                  "${ORACLE_BASE}"
    _assert_safe_path  GRID_HOME                    "${GRID_HOME}"
    _assert_safe_path  WORK_DIR                     "${WORK_DIR}"
    _assert_safe_path  ADUMP_DIR                    "${ADUMP_DIR}"
    _assert_safe_path  ASM_SSH_KEY                  "${ASM_SSH_KEY}"
    # Host
    _assert_safe_host  ASM_SSH_HOST                 "${ASM_SSH_HOST}"
    # Enumerations
    _assert_one_of     ASM_EXEC_METHOD              "${ASM_EXEC_METHOD}" sudo ssh direct
    _assert_one_of     IS_CDB                       "${IS_CDB}" true false
    _assert_one_of     FORCE_SHUTDOWN               "${FORCE_SHUTDOWN}" true false
    _assert_one_of     CASCADED_STANDBY             "${CASCADED_STANDBY}" true false
    _assert_one_of     REFRESH_METHOD               "${REFRESH_METHOD}" dataguard rman
    # Integers
    _assert_uint       REDO_GROUPS                  "${REDO_GROUPS}"
    _assert_uint       REDO_BLOCKSIZE               "${REDO_BLOCKSIZE}"
    _assert_uint       SNAP_INDEX                   "${SNAP_INDEX}"
    _assert_uint       SPARSE_CHAIN_WARN_DEPTH      "${SPARSE_CHAIN_WARN_DEPTH}"
    _assert_uint       SPARSE_CHAIN_MAX_DEPTH        "${SPARSE_CHAIN_MAX_DEPTH}"
    _assert_uint       DGMGRL_APPLY_WAIT_SECS        "${DGMGRL_APPLY_WAIT_SECS}"
    _assert_uint       DGMGRL_APPLY_LAG_THRESHOLD    "${DGMGRL_APPLY_LAG_THRESHOLD}"
    # Sizes
    _assert_size       REDO_SIZE                    "${REDO_SIZE}"
    _assert_size       TEMP_SIZE                    "${TEMP_SIZE}"
    # Cascaded: if enabled, upstream name must be set and valid
    if [[ "${CASCADED_STANDBY}" == "true" ]]; then
        if [[ -z "${CASCADE_SOURCE_DB_UNIQUE_NAME}" ]]; then
            echo "ERROR: CASCADED_STANDBY=true requires CASCADE_SOURCE_DB_UNIQUE_NAME to be set" >&2
            err=1
        else
            _assert_safe_name CASCADE_SOURCE_DB_UNIQUE_NAME "${CASCADE_SOURCE_DB_UNIQUE_NAME}"
        fi
    fi

    unset -f _assert_safe_name _assert_asm_dg _assert_safe_path _assert_safe_host \
             _assert_uint _assert_size _assert_one_of

    if [[ ${err} -ne 0 ]]; then
        echo "ERROR: One or more configuration variables failed validation. Aborting." >&2
        exit 1
    fi
    log "Config variable validation: PASSED"
}

# =============================================================================
# SECTION 9 -- PRE-FLIGHT CHECKS
# Validates the environment is ready before any database operations begin.
# =============================================================================

check_prerequisites() {
    step "PRE-FLIGHT -- Environment and Connectivity Checks"

    # --- Binary checks ---
    substep "Checking required binaries"
    [[ -x "${ORACLE_HOME}/bin/sqlplus" ]]  || error "sqlplus not found at ${ORACLE_HOME}/bin/sqlplus"
    [[ -x "${ORACLE_HOME}/bin/dgmgrl" ]]   || error "dgmgrl not found at ${ORACLE_HOME}/bin/dgmgrl"
    [[ -x "${ORACLE_HOME}/bin/rman" ]]     || error "rman not found at ${ORACLE_HOME}/bin/rman"
    command -v python3 >/dev/null 2>&1     || error "python3 not found in PATH"
    log "python3: $(command -v python3) -- $(python3 --version 2>&1)"

    [[ -x "${ORACLE_HOME}/bin/srvctl" ]] || error "srvctl not found at ${ORACLE_HOME}/bin/srvctl"
    log "srvctl: ${ORACLE_HOME}/bin/srvctl"

    if [[ ! -x "${GRID_HOME}/bin/asmcmd" ]] && [[ ! -x "${ORACLE_HOME}/bin/asmcmd" ]]; then
        error "asmcmd not found in GRID_HOME (${GRID_HOME}/bin) or ORACLE_HOME (${ORACLE_HOME}/bin)"
    fi
    success "Required binaries: OK"

    # --- OS user check ---
    substep "Verifying OS user identity"
    local current_user
    current_user="$(whoami)"
    if [[ "${current_user}" != "${ORACLE_USER}" ]]; then
        error "Script must run as '${ORACLE_USER}' but running as '${current_user}'.\\n  Re-run: sudo -u ${ORACLE_USER} $0 $*"
    fi
    success "OS user: ${current_user} (matches ORACLE_USER)"

    # --- ASM execution method ---
    substep "Validating ASM execution method: ${ASM_EXEC_METHOD}"
    case "${ASM_EXEC_METHOD}" in
        sudo)
            if ! sudo -u "${GRID_USER}" -n true 2>/dev/null; then
                error "sudo -u ${GRID_USER} failed. Add sudoers entry:\\n  ${current_user} ALL=(${GRID_USER}) NOPASSWD: /bin/bash"
            fi
            success "sudo to ${GRID_USER}: OK"
            ;;
        ssh)
            if ! ssh -n -i "${ASM_SSH_KEY}" -o BatchMode=yes -o ConnectTimeout=5 \
                    -o StrictHostKeyChecking=accept-new "${GRID_USER}@${ASM_SSH_HOST}" true 2>/dev/null; then
                error "SSH to ${GRID_USER}@${ASM_SSH_HOST} failed.\\n  Run: ssh-copy-id -i ${ASM_SSH_KEY} ${GRID_USER}@${ASM_SSH_HOST}"
            fi
            success "SSH to ${GRID_USER}@${ASM_SSH_HOST}: OK"
            ;;
        direct)
            if [[ "$(whoami)" != "${GRID_USER}" ]]; then
                warn "ASM_EXEC_METHOD=direct but running as $(whoami), not ${GRID_USER}. asmcmd may fail."
            fi
            ;;
    esac

    # --- SYSDBA connectivity to standby ---
    substep "Verifying SYSDBA connectivity to standby: ${STBY_ORACLE_SID}"
    local sysdba_test
    sysdba_test=$(ORACLE_SID="${STBY_ORACLE_SID}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba 2>&1 <<'EOSQL'
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SELECT 'SYSDBA_OK' FROM dual;
EXIT
EOSQL
) || true
    if ! echo "${sysdba_test}" | grep -q "SYSDBA_OK"; then
        error "SYSDBA auth failed for SID ${STBY_ORACLE_SID}.\\n  Output: ${sysdba_test}\\n  Verify the instance is running and OS auth is configured."
    fi
    success "SYSDBA connectivity to ${STBY_ORACLE_SID}: OK"

    # --- Standby DB status ---
    substep "Checking standby database role and status"
    local db_role
    db_role=$(sqlplus_check "${STBY_ORACLE_SID}" \
        "SELECT TRIM(DATABASE_ROLE) FROM V\$DATABASE;" "preflight-role" | \
        grep -v '^$' | tail -1 )
    log "Standby database role: ${db_role}"
    if [[ "${db_role}" != "PHYSICAL STANDBY" ]]; then
        error "Expected 'PHYSICAL STANDBY' but database role is '${db_role}'. Wrong SID?"
    fi
    success "Database role confirmed: PHYSICAL STANDBY"

    # --- DGMGRL broker connectivity ---
    substep "Verifying DGMGRL broker connectivity"
    local dgmgrl_test
    dgmgrl_test=$(dgmgrl_check "SHOW CONFIGURATION;" "preflight-dgmgrl") || \
        error "DGMGRL SHOW CONFIGURATION failed. Is the Data Guard Broker running?"
    log_output "DGMGRL-CONFIGURATION" "${dgmgrl_test}"
    success "DGMGRL broker: OK"

    # --- Validate standby is known to the broker ---
    substep "Verifying standby '${STBY_DB_UNIQUE_NAME}' is registered in DG Broker"
    local dg_show
    dg_show=$(dgmgrl_check "SHOW DATABASE ${STBY_DB_UNIQUE_NAME};" "preflight-stby-show")
    if echo "${dg_show}" | grep -qiE "Error:|not found|ORA-"; then
        error "Standby '${STBY_DB_UNIQUE_NAME}' not found in DG Broker configuration."
    fi
    log_output "DGMGRL-STBY-SHOW" "${dg_show}"
    success "Standby '${STBY_DB_UNIQUE_NAME}' confirmed in DG Broker"

    # --- Cascaded standby validation ---
    if [[ "${CASCADED_STANDBY}" == "true" ]]; then
        substep "Cascaded DG: verifying upstream source '${CASCADE_SOURCE_DB_UNIQUE_NAME}'"
        local cascade_show
        cascade_show=$(dgmgrl_check "SHOW DATABASE ${CASCADE_SOURCE_DB_UNIQUE_NAME};" "preflight-cascade-show")
        if echo "${cascade_show}" | grep -qiE "Error:|not found|ORA-"; then
            error "Cascaded source '${CASCADE_SOURCE_DB_UNIQUE_NAME}' not found in DG Broker."
        fi
        log_output "DGMGRL-CASCADE-SHOW" "${cascade_show}"
        # Verify stbydb receives redo from cascade source, not directly from primary
        local stby_transport
        stby_transport=$(sqlplus_check "${STBY_ORACLE_SID}" \
            "SELECT TRIM(TRANSPORT_MODE) FROM V\$ARCHIVE_DEST_STATUS WHERE TARGET='STANDBY' AND STATUS='VALID';" \
            "preflight-cascade-transport" | grep -v '^$' | tail -1 | tr -d ' ')
        log "Cascaded standby transport mode: ${stby_transport}"
        success "Cascaded Data Guard topology verified: source='${CASCADE_SOURCE_DB_UNIQUE_NAME}'"
    fi

    # --- ASM disk group ACL check ---
    # MUST run via run_as_grid → grid OS user → SYSASM.
    # v$asm_attribute is only populated from the ASM instance (ORACLE_SID=+ASMn).
    # Querying it as SYSDBA from the DB instance always returns 0 rows, which
    # previously caused the check to be silently skipped.
    #
    # We also collect live diskgroup names from V$DATAFILE so we catch every
    # diskgroup in use, not just the three declared in config vars.
    substep "Checking ASM disk group ACL mode (via SYSASM)"

    # Collect live diskgroup names from the standby (best-effort; oracle user ok here)
    local live_dgs=""
    if [[ "${DRY_RUN}" != "true" ]]; then
        live_dgs=$(ORACLE_SID="${STBY_ORACLE_SID}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba \
            2>/dev/null <<'EOSQL' | tr -d ' \r' | grep -v '^$' || true
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SELECT DISTINCT UPPER(REGEXP_SUBSTR(name,'[A-Za-z0-9_]+',2)) FROM v$datafile;
EXIT
EOSQL
)
    fi

    # Merge live names with config-declared groups and de-duplicate
    local all_dg_names
    all_dg_names=$(printf '%s\n%s\n%s\n%s\n' \
        "${SNAP_SPARSE_DG#+}" "${SNAP_DATA_DG#+}" "${TM_DATA_DG#+}" \
        "${live_dgs}" \
        | tr '[:lower:]' '[:upper:]' | sort -u | grep -v '^$')

    log "Diskgroups to ACL-check: $(echo "${all_dg_names}" | tr '\n' ' ')"

    # Build SQL IN-list: 'DATA','SPARSE','RECO'
    local acl_in_list
    acl_in_list=$(echo "${all_dg_names}" | sed "s/^/'/;s/$/'/" | paste -sd ',' -)

    # Query SYSASM via run_as_grid (grid OS user, ASM instance)
    # Output: one row per diskgroup → "DISKGROUPNAME TRUE" or "DISKGROUPNAME FALSE"
    local acl_tmpf acl_raw=""
    acl_tmpf=$(mktemp /tmp/acl_check_XXXXXX.sql)
    printf 'SET ECHO OFF\nSET FEEDBACK OFF\nSET HEADING OFF\nSET PAGESIZE 0\nSET LINESIZE 200\n' > "${acl_tmpf}"
    printf "SELECT TRIM(g.name) || ' ' || TRIM(a.value)\n" >> "${acl_tmpf}"
    printf "FROM   v\$asm_diskgroup g\n" >> "${acl_tmpf}"
    printf "JOIN   v\$asm_attribute a ON g.group_number = a.group_number\n" >> "${acl_tmpf}"
    printf "WHERE  a.name = 'access_control.enabled'\n" >> "${acl_tmpf}"
    printf "AND    g.name IN (%s);\n" "${acl_in_list}" >> "${acl_tmpf}"
    printf 'EXIT\n' >> "${acl_tmpf}"
    chmod 644 "${acl_tmpf}"

    if [[ "${DRY_RUN}" != "true" ]]; then
        local sqlplus_bin="${GRID_HOME}/bin/sqlplus"
        [[ ! -x "${sqlplus_bin}" ]] && sqlplus_bin="${ORACLE_HOME}/bin/sqlplus"
        acl_raw=$(run_as_grid "ORACLE_SID=${ASM_SID} ${sqlplus_bin} -S / as sysasm @${acl_tmpf}" \
            2>/dev/null | grep -v '^$' | tr -d '\r') || acl_raw=""
    fi
    rm -f "${acl_tmpf}"

    log_output "ASM-ACL-STATUS" "${acl_raw}"

    if [[ -z "${acl_raw}" ]] && [[ "${DRY_RUN}" != "true" ]]; then
        error "ACL pre-flight FAILED: no rows returned from SYSASM for diskgroups: $(echo "${all_dg_names}" | tr '\n' ' ')\n  Check:\n    1) ASM_SID=${ASM_SID} is reachable via ASM_EXEC_METHOD=${ASM_EXEC_METHOD}\n    2) Diskgroup names are correct: ${acl_in_list}\n  Fix: ALTER DISKGROUP <dg> SET ATTRIBUTE 'ACCESS_CONTROL.ENABLED'='TRUE';"
    fi

    # Evaluate each returned row; also flag any expected diskgroup that is missing
    local acl_ok=true acl_fail_msg=""
    while IFS=' ' read -r dg_name dg_val; do
        [[ -z "${dg_name}" ]] && continue
        if [[ "${dg_val^^}" != "TRUE" ]]; then
            acl_ok=false
            acl_fail_msg+="  ${dg_name}: ACCESS_CONTROL.ENABLED=${dg_val:-MISSING}\n"
        else
            log "  ACL OK: ${dg_name}=TRUE"
        fi
    done <<< "${acl_raw}"

    # Also flag any diskgroup that did not appear in the output at all
    while IFS= read -r need_dg; do
        [[ -z "${need_dg}" ]] && continue
        if [[ "${DRY_RUN}" != "true" ]] && ! echo "${acl_raw}" | grep -qiE "^${need_dg} "; then
            acl_ok=false
            acl_fail_msg+="  ${need_dg}: NOT FOUND in SYSASM output (diskgroup absent or ACL attribute unset)\n"
        fi
    done <<< "${all_dg_names}"

    if [[ "${acl_ok}" != "true" ]]; then
        error "ACL pre-flight FAILED -- cannot proceed:\n${acl_fail_msg}\n  Fix each diskgroup as SYSASM:\n    ALTER DISKGROUP <dg> SET ATTRIBUTE 'ACCESS_CONTROL.ENABLED'='TRUE';\n  Then re-run this script."
    fi

    success "ASM ACL mode: ENABLED (TRUE) on all required disk groups"

    # --- ASM disk group space check ---
    # Must run via run_as_grid (grid OS user) against the ASM instance.
    # Direct invocation as the oracle OS user will fail OS authentication.
    substep "Checking ASM disk group free space (via SYSASM)"
    local asm_space_out="" sparse_free data_free
    local sparse_dg_bare="${SNAP_SPARSE_DG#+}"
    local data_dg_bare="${SNAP_DATA_DG#+}"

    local space_tmpf
    space_tmpf=$(mktemp /tmp/asm_space_XXXXXX.sql)
    printf 'SET ECHO OFF\nSET FEEDBACK OFF\nSET HEADING OFF\nSET PAGESIZE 0\n' > "${space_tmpf}"
    printf "SELECT name || '=' || free_mb FROM v\$asm_diskgroup\n" >> "${space_tmpf}"
    printf "WHERE name IN ('%s','%s');\n" "${sparse_dg_bare}" "${data_dg_bare}" >> "${space_tmpf}"
    printf 'EXIT\n' >> "${space_tmpf}"
    chmod 644 "${space_tmpf}"

    if [[ "${DRY_RUN}" != "true" ]]; then
        local sqlplus_bin="${GRID_HOME}/bin/sqlplus"
        [[ ! -x "${sqlplus_bin}" ]] && sqlplus_bin="${ORACLE_HOME}/bin/sqlplus"
        asm_space_out=$(run_as_grid \
            "ORACLE_SID=${ASM_SID} ${sqlplus_bin} -S / as sysasm @${space_tmpf}" \
            2>/dev/null | tr -d ' \r' | grep -v '^$') || asm_space_out=""
    fi
    rm -f "${space_tmpf}"

    if [[ -z "${asm_space_out}" ]]; then
        warn "Could not query V\$ASM_DISKGROUP free space via SYSASM -- skipping space check"
        warn "Verify ASM_SID=${ASM_SID} and ASM_EXEC_METHOD=${ASM_EXEC_METHOD} are correct"
    else
        sparse_free=$(echo "${asm_space_out}" | grep -i "^${sparse_dg_bare}=" | cut -d= -f2 | grep -oE '^[0-9]+' || echo 0)
        data_free=$(echo "${asm_space_out}"   | grep -i "^${data_dg_bare}="   | cut -d= -f2 | grep -oE '^[0-9]+' || echo 0)
        log "  ${SNAP_SPARSE_DG} free: ${sparse_free} MB  (min required: ${ASM_SPARSE_MIN_FREE_MB} MB)"
        log "  ${SNAP_DATA_DG}   free: ${data_free} MB  (min required: ${ASM_DATA_MIN_FREE_MB} MB)"
        [[ "${sparse_free:-0}" -gt 0 ]] || error "${SNAP_SPARSE_DG} not found in SYSASM or 0 MB free"
        [[ "${data_free:-0}"   -gt 0 ]] || error "${SNAP_DATA_DG} not found in SYSASM or 0 MB free"
        [[ "${sparse_free}" -ge "${ASM_SPARSE_MIN_FREE_MB}" ]] || \
            error "Insufficient space in ${SNAP_SPARSE_DG}: ${sparse_free} MB < ${ASM_SPARSE_MIN_FREE_MB} MB required"
        [[ "${data_free}" -ge "${ASM_DATA_MIN_FREE_MB}" ]] || \
            error "Insufficient space in ${SNAP_DATA_DG}: ${data_free} MB < ${ASM_DATA_MIN_FREE_MB} MB required"
        success "ASM space: ${SNAP_SPARSE_DG}=${sparse_free} MB, ${SNAP_DATA_DG}=${data_free} MB"
    fi

    # --- Work directory ---
    substep "Creating working directories"
    mkdir -p "${WORK_DIR}" "${ADUMP_DIR}"
    log "WORK_DIR  : ${WORK_DIR}"
    log "ADUMP_DIR : ${ADUMP_DIR}"
    success "Working directories ready"

    success "All pre-flight checks PASSED"
}


# =============================================================================
# RUNTIME CONFLICT CHECKS
# =============================================================================
check_runtime_conflicts() {

    [[ "${ENABLE_RUNTIME_CHECKS}" != "true" ]] && {
        log "Runtime checks disabled"
        return 0
    }

    step "PRE-RUNTIME -- Conflict Checks"

    substep "Checking active user sessions"
    local sess_count
    sess_count=$(sqlplus_check "${STBY_ORACLE_SID}" "
SELECT COUNT(*) FROM v\$session
WHERE status='ACTIVE' AND type='USER' AND username IS NOT NULL;
" "runtime-sessions" | tail -1 | tr -d ' ')

    log "Active sessions: ${sess_count}"

    if [[ "${sess_count}" -gt "${SESSION_THRESHOLD}" ]]; then
        warn "Active sessions detected"
        if [[ "${FORCE_RUNTIME_OVERRIDE}" != "true" ]]; then
            error "Active sessions present. Use FORCE_RUNTIME_OVERRIDE=true"
        fi
    fi

    substep "Checking RMAN jobs"
    local rman_running
    rman_running=$(sqlplus_check "${STBY_ORACLE_SID}" "
SELECT COUNT(*) FROM v\$rman_status WHERE status='RUNNING';
" "runtime-rman" | tail -1 | tr -d ' ')

    log "RMAN running: ${rman_running}"

    if [[ "${rman_running}" -gt 0 ]] && [[ "${FORCE_RUNTIME_OVERRIDE}" != "true" ]]; then
        error "RMAN job running"
    fi

    success "Runtime checks completed"
}

# =============================================================================
# SECTION 10 -- CHAIN DEPTH MANAGEMENT
# Counts the current depth of the sparse chain and enforces the
# SPARSE_CHAIN_MAX_DEPTH guard before any new snapshot is taken.
# Oracle's hard limit is 10 links; we default max to 8 for headroom.
# =============================================================================

# get_sparse_chain_depth  -- queries V$CLONEDFILE to count chain links
# Returns 0 if no sparse files exist yet (fresh standby, no snapshot taken).
get_sparse_chain_depth() {
    local depth_out depth
    depth_out=$(sqlplus_check "${STBY_ORACLE_SID}" "
SELECT NVL(MAX(depth),0) FROM (
  SELECT LEVEL AS depth
  FROM V\$CLONEDFILE
  CONNECT BY PRIOR SNAPSHOTFILENAME = CLONEFILENAME
  START WITH SNAPSHOTFILENAME IS NULL
);
" "chain-depth-query" | grep -v '^$' | tail -1 | tr -d ' ') || depth_out="0"
    depth="${depth_out:-0}"
    [[ "${depth}" =~ ^[0-9]+$ ]] || depth=0
    echo "${depth}"
}

check_chain_depth() {
    step "CHAIN DEPTH -- Checking Sparse Snapshot Chain Depth"

    local depth
    depth=$(get_sparse_chain_depth)
    log "Current sparse chain depth  : ${depth}"
    log "Warning threshold           : ${SPARSE_CHAIN_WARN_DEPTH}"
    log "Maximum allowed depth       : ${SPARSE_CHAIN_MAX_DEPTH}"
    log "Oracle hard limit           : 10"

    # Log to the persistent chain history file
    log_chain_event "DEPTH_CHECK depth=${depth} warn=${SPARSE_CHAIN_WARN_DEPTH} max=${SPARSE_CHAIN_MAX_DEPTH} stby=${STBY_DB_UNIQUE_NAME}"

    if [[ "${depth}" -ge "${SPARSE_CHAIN_MAX_DEPTH}" ]]; then
        error "Sparse chain depth ${depth} has reached the configured maximum ${SPARSE_CHAIN_MAX_DEPTH}.
  Oracle's hard limit is 10 links. Taking another snapshot would approach it.
  ACTION REQUIRED -- choose one of:
    1) Increase SPARSE_CHAIN_MAX_DEPTH in your config (up to 9 maximum).
    2) Drop all existing sparse clones and start a new baseline standby.
    3) Use RMAN to resync the standby to a full DATA copy and restart the chain.
  See Oracle Exadata System Software User Guide, Chapter 9, Refresh Considerations."
    elif [[ "${depth}" -ge "${SPARSE_CHAIN_WARN_DEPTH}" ]]; then
        warn "Sparse chain depth ${depth} is approaching the maximum (${SPARSE_CHAIN_MAX_DEPTH})."
        warn "Consider planning a new baseline standby or chain reset soon."
        log_chain_event "DEPTH_WARNING depth=${depth}"
    else
        success "Chain depth ${depth} is within safe limits"
    fi

    success "Chain depth check passed (depth=${depth})"
}

# verify_clonedfile SID SPARSE_DG LABEL
# Shared by ss_s12 (standby) and step13 (snapshot clone). Queries V$CLONEDFILE
# and errors if no entries exist for the given diskgroup (unless DRY_RUN=true).
verify_clonedfile() {
    local sid="$1" sparse_dg="$2" label="${3:-verify-clonedfile}"

    local clone_out
    clone_out=$(sqlplus_check "${sid}" "
SET LINESIZE 220
SET PAGESIZE 100
COLUMN num     FORMAT 9999  HEADING 'File#'
COLUMN child   FORMAT A80   HEADING 'Child (${sparse_dg})'
COLUMN parent  FORMAT A80   HEADING 'Parent'
SELECT filenumber num, clonefilename child, snapshotfilename parent
FROM V\$CLONEDFILE
ORDER BY filenumber;" "${label}-query")
    log_output "${label^^}-CLONEDFILE" "${clone_out}"

    local clone_count
    clone_count=$(echo "${clone_out}" | grep -cF "${sparse_dg}" || true)

    if [[ "${DRY_RUN}" != "true" ]] && [[ "${clone_count:-0}" -eq 0 ]]; then
        error "[${label}] V\$CLONEDFILE has no entries for ${sparse_dg}.
  CLONEDB_RENAMEFILE may have failed or dNFS is not configured."
    fi

    local with_parent
    with_parent=$(sqlplus_check "${sid}" \
        "SELECT COUNT(*) FROM V\$CLONEDFILE WHERE SNAPSHOTFILENAME IS NOT NULL;" \
        "${label}-with-parent" | grep -v '^$' | tail -1 | tr -d ' ')
    log "[${label}] Files with parent pointers (hierarchical chain): ${with_parent}"

    echo "${clone_count}"
}

# _generate_renamefile_sql SID DEST_FILE SRC_DG DST_DG SNAP_IDX LABEL
# Shared by ss_s2 (standby) and step2 (Test Master clone). Both produce an
# identical CLONEDB_RENAMEFILE spool from V$DATAFILE; only SID and label differ.
_generate_renamefile_sql() {
    local sid="$1" dest="$2" src_dg="$3" dst_dg="$4" snap_idx="$5" label="${6:-gen-rename-sql}"
    local src_dg_bare="${src_dg#+}/"
    local dst_dg_bare="${dst_dg#+}/"

    log "[${label}] Generating CLONEDB_RENAMEFILE SQL: SID=${sid} index=T${snap_idx}"
    log "[${label}] Source DG : ${src_dg}   Dest DG : ${dst_dg}"

    local count
    count=$(spool_sql_from_query "${sid}" "${dest}" \
"SELECT 'EXECUTE dbms_dnfs.clonedb_renamefile(' ||
       '''' || name || '''' || ',' ||
       '''' || REPLACE(
                 REPLACE(name, '.', '_'),
                 '${src_dg_bare}', '${dst_dg_bare}') ||
       '_T${snap_idx}' || ''');'
FROM v\$datafile;" "${label}")

    local rename_count
    rename_count=$(grep -c "clonedb_renamefile" "${dest}" 2>/dev/null || echo 0)
    [[ "${rename_count}" -gt 0 ]] || \
        error "[${label}] rename_files.sql has no entries -- V\$DATAFILE empty?"

    # Append EXIT so sqlplus terminates cleanly after the last EXECUTE statement.
    # Without this, sqlplus drops back to the interactive SQL> prompt after the
    # script file is exhausted and hangs until the safe_exec timeout kills it.
    # WHENEVER SQLERROR EXIT FAILURE ensures any PL/SQL error also exits non-zero.
    printf '\nWHENEVER SQLERROR EXIT FAILURE\nEXIT;\n' >> "${dest}"

    log "[${label}] Generated ${rename_count} CLONEDB_RENAMEFILE entries"
    head -5 "${dest}" >> "${LOGFILE}"
    echo "${rename_count}"
}

# =============================================================================
# SECTION 11 -- PART A: SPARSE STANDBY SNAPSHOT STEPS (S1 - S14)
# Implements the Oracle blog workflow for snapshotting a live Data Guard
# physical standby into sparse datafiles in the SPARSE diskgroup.
# =============================================================================

# ---------------------------------------------------------------------------
# S1: Stop Redo Apply on the Standby (DGMGRL)
# ---------------------------------------------------------------------------
ss_s1_stop_redo_apply() {
    step "S1 -- Stop Redo Apply on ${STBY_DB_UNIQUE_NAME}"
    log "Stopping redo apply to create a consistent standby state for snapshotting."
    log "RFS will continue receiving redo vectors into Standby Redo Logs."

    # --- Idempotency: check if apply is already stopped ---
    substep "Checking current Data Guard apply state"
    local dg_before
    dg_before=$(dgmgrl_check "SHOW DATABASE VERBOSE ${STBY_DB_UNIQUE_NAME};" "S1-show-before")
    log_output "S1-DG-STATE-BEFORE" "${dg_before}"

    local current_state
    current_state=$(echo "${dg_before}" | grep -i "Intended State" | head -1 || true)
    if echo "${current_state}" | grep -qi "APPLY-OFF"; then
        log "S1: Intended State is already APPLY-OFF -- redo apply already stopped, skipping"
        log_chain_event "S1_APPLY_OFF_SKIPPED stby=${STBY_DB_UNIQUE_NAME} snap_index=T${SNAP_INDEX} reason=already-off"
        success "S1: Redo apply already stopped (idempotent skip)"
        return 0
    fi

    substep "Issuing APPLY-OFF to DGMGRL"
    safe_exec -l "S1-dgmgrl-apply-off" -t 120 -- \
        "'${ORACLE_HOME}/bin/dgmgrl' -silent / <<'_EOF'
CONNECT /;
EDIT DATABASE ${STBY_DB_UNIQUE_NAME} SET STATE='APPLY-OFF';
EXIT;
_EOF"

    # Verify the state change took effect
    substep "Verifying apply state is now APPLY-OFF"
    local dg_after state_line
    dg_after=$(dgmgrl_check "SHOW DATABASE ${STBY_DB_UNIQUE_NAME};" "S1-show-after")
    log_output "S1-DG-STATE-AFTER" "${dg_after}"

    state_line=$(echo "${dg_after}" | grep -i "Intended State" | head -1 || true)
    log "DG Intended State after change: ${state_line}"
    if ! echo "${state_line}" | grep -qi "APPLY-OFF"; then
        error "S1: Redo apply did not stop. Expected 'APPLY-OFF' in: ${state_line}"
    fi

    log_chain_event "S1_APPLY_OFF stby=${STBY_DB_UNIQUE_NAME} snap_index=T${SNAP_INDEX}"

    # Register rollback: re-enable redo apply via DGMGRL if a later step fails.
    # DGMGRL communicates over the DG network stack -- no standby instance needed.
    register_rollback "S1-restore-apply-on" \
        "'${ORACLE_HOME}/bin/dgmgrl' -silent / 'CONNECT /; EDIT DATABASE ${STBY_DB_UNIQUE_NAME} SET STATE=''APPLY-ON''; EXIT;'"

    success "S1: Redo apply stopped on ${STBY_DB_UNIQUE_NAME}"
}

# ---------------------------------------------------------------------------
# S2: Generate rename_files.sql (DBMS_DNFS.CLONEDB_RENAMEFILE)
# Generates the SQL to create sparse child datafiles in the SPARSE diskgroup.
# Must be run BEFORE shutdown -- we need V$DATAFILE from the live instance.
# ---------------------------------------------------------------------------
ss_s2_generate_rename_sql() {
    step "S2 -- Generate rename_files.sql (CLONEDB_RENAMEFILE Statements)"
    log "Generating sparse clone rename SQL from V\$DATAFILE on ${STBY_ORACLE_SID}"
    log "Snapshot index : T${SNAP_INDEX}  (suffix appended to every sparse filename)"

    local rename_sql="${WORK_DIR}/rename_files.sql"
    local rename_count
    rename_count=$(_generate_renamefile_sql \
        "${STBY_ORACLE_SID}" "${rename_sql}" \
        "${TM_DATA_DG}" "${SNAP_SPARSE_DG}" "${SNAP_INDEX}" "S2-spool")

    log_chain_event "S2_RENAME_SQL generated lines=${rename_count} file=${rename_sql}"
    success "S2: rename_files.sql generated: ${rename_sql} (${rename_count} entries)"
}

# ---------------------------------------------------------------------------
# S3: Generate set_datafiles_read_only.sql (ALTER DISKGROUP permissions)
# Sets all current standby datafiles to READ ONLY in ASM ACL so they
# become the immutable parents for the new sparse sparse datafiles.
# ---------------------------------------------------------------------------
ss_s3_generate_set_readonly_sql() {
    step "S3 -- Generate set_datafiles_read_only.sql (ASM ACL Permissions)"
    log "Generating ALTER DISKGROUP SET PERMISSION READ ONLY statements"
    log "These will freeze the current standby datafiles as parent files."

    local readonly_sql="${WORK_DIR}/set_datafiles_read_only.sql"

    substep "Spooling set_datafiles_read_only.sql from V\$DATAFILE"
    spool_sql_from_query "${STBY_ORACLE_SID}" "${readonly_sql}" \
"SELECT DISTINCT 'ALTER DISKGROUP ' ||
       SUBSTR(name, 2, REGEXP_INSTR(name, '/') - 2) ||
       ' SET PERMISSION OWNER=READ ONLY, GROUP=READ ONLY, OTHER=NONE FOR FILE ''' ||
       name || ''';'
FROM v\$datafile;" "S3-spool" > /dev/null

    local perm_count
    perm_count=$(grep -c "ALTER DISKGROUP" "${readonly_sql}" 2>/dev/null || echo 0)
    [[ "${perm_count}" -gt 0 ]] || error "S3: set_datafiles_read_only.sql is empty -- no datafiles?"

    log "Generated ${perm_count} ALTER DISKGROUP permission statements"
    head -3 "${readonly_sql}" >> "${LOGFILE}"

    # Pre-generate the READ-WRITE restore script NOW, while V$DATAFILE is queryable.
    # The rollback registered at S6 will run this file as SYSASM with no DB dependency.
    local readwrite_sql="${WORK_DIR}/s6_rollback_readwrite.sql"
    substep "Pre-generating S6 rollback script: ${readwrite_sql}"
    spool_sql_from_query "${STBY_ORACLE_SID}" "${readwrite_sql}" \
"SELECT DISTINCT 'ALTER DISKGROUP ' ||
       SUBSTR(name, 2, REGEXP_INSTR(name, '/') - 2) ||
       ' SET PERMISSION OWNER=READ WRITE, GROUP=READ WRITE, OTHER=NONE FOR FILE ''' ||
       name || ''';'
FROM v\$datafile;" "S3-spool-rollback" > /dev/null
    local rw_count
    rw_count=$(grep -c "ALTER DISKGROUP" "${readwrite_sql}" 2>/dev/null || echo 0)
    log "S3: Rollback restore script pre-generated: ${readwrite_sql} (${rw_count} entries)"

    log_chain_event "S3_READONLY_SQL generated lines=${perm_count} file=${readonly_sql}"
    success "S3: set_datafiles_read_only.sql generated (${perm_count} entries)"
}

# ---------------------------------------------------------------------------
# S4: Create ASM directories in SPARSE diskgroup for the standby DB
# CLONEDB_RENAMEFILE (S8) writes sparse child files into
#   +SPARSE/<STBY_DB_UNIQUE_NAME>/datafile/           (non-CDB)
#   +SPARSE/<STBY_DB_UNIQUE_NAME>/<PDB_GUID>/datafile/ (each PDB in a CDB)
# Oracle will NOT auto-create these directories -- they must exist before S8.
# The standby is still OPEN at this point (shutdown happens at S5), so PDB
# GUIDs can be queried directly from the live instance without any extra
# startup/shutdown -- unlike Part B's step8 which may find the TM shut down.
# ---------------------------------------------------------------------------
ss_s4_create_sparse_asm_dirs() {
    step "S4 -- Create SPARSE ASM Directories for ${STBY_DB_UNIQUE_NAME}"
    log "CLONEDB_RENAMEFILE (S8) targets: ${SNAP_SPARSE_DG}/${STBY_DB_UNIQUE_NAME}/..."
    log "Grid user       : ${GRID_USER}"
    log "ASM SID         : ${ASM_SID}"
    log "ASM exec method : ${ASM_EXEC_METHOD}"

    substep "Creating ${SNAP_SPARSE_DG}/${STBY_DB_UNIQUE_NAME}/datafile"
    asmcmd_mkdir "${SNAP_SPARSE_DG}/${STBY_DB_UNIQUE_NAME}/datafile"
    success "Created: ${SNAP_SPARSE_DG}/${STBY_DB_UNIQUE_NAME}/datafile"

    if [[ "${IS_CDB}" == "true" ]]; then
        substep "CDB mode: querying PDB GUIDs from standby (still OPEN)"
        local pdb_guids
	pdb_guids=$(ORACLE_SID="${STBY_ORACLE_SID}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba 2>/dev/null <<'_EOF' | tr -d ' \r' | grep -E '^[0-9A-F]{32}$'
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET TRIMSPOOL ON
SELECT rawtohex(guid) FROM v$pdbs WHERE con_id > 1;
EXIT
_EOF
)
log "S4: PDB GUIDs found: ${pdb_guids}"
        if [[ -z "${pdb_guids}" ]] && [[ "${DRY_RUN}" != "true" ]]; then
            warn "S4: No PDB GUIDs returned from cdb_pdbs -- skipping PDB GUID directories"
        else
            for guid in ${pdb_guids}; do
                log "S4: Creating ASM dir for PDB GUID: ${guid}"
                asmcmd_mkdir "${SNAP_SPARSE_DG}/${STBY_DB_UNIQUE_NAME}/${guid}/datafile"
                success "  Created: ${SNAP_SPARSE_DG}/${STBY_DB_UNIQUE_NAME}/${guid}/datafile"
            done
        fi
    fi

    substep "Verifying SPARSE base directory"
    run_asmcmd "ls ${SNAP_SPARSE_DG}/${STBY_DB_UNIQUE_NAME}"
    success "S4: SPARSE ASM directories ready for CLONEDB_RENAMEFILE"
}

# ---------------------------------------------------------------------------
# S5: Shutdown the Standby Database
# Uses srvctl stop database -o normal
# ---------------------------------------------------------------------------
ss_s5_shutdown_standby() {
    step "S5 -- Shutdown Standby Database: ${STBY_DB_UNIQUE_NAME}"
    log "A clean shutdown is required to ensure consistent datafiles."
    log "This is non-trivial: corrupt datafiles will invalidate all sparse children."

    # Check current instance count (RAC awareness)
    local inst_count=0
    for _i in ${STBY_INSTANCES}; do (( inst_count++ )) || true; done
    log "Configured RAC instances : ${inst_count}  (${STBY_INSTANCES})"

    # --- Idempotency: check if all instances are already DOWN ---
    substep "Checking current instance state before shutdown"
    local all_already_down=true
    for inst in ${STBY_INSTANCES}; do
        local inst_status
        inst_status=$(get_db_status "${inst}")
        log "  Instance ${inst} current status: ${inst_status}"
        if [[ "${inst_status}" != "DOWN" ]]; then
            all_already_down=false
        fi
    done
    if [[ "${all_already_down}" == "true" ]] && [[ "${DRY_RUN}" != "true" ]]; then
        log "S4: All instances already DOWN -- shutdown not required, skipping"
        log_chain_event "S4_SHUTDOWN_SKIPPED stby=${STBY_DB_UNIQUE_NAME} reason=already-down"
        success "S4: Standby already down (idempotent skip)"
        return 0
    fi

    substep "Executing database shutdown"
    shutdown_standby_db

    # Post-shutdown verification: confirm all instances are DOWN
    substep "Verifying all instances are down"
    local all_down=true
    for inst in ${STBY_INSTANCES}; do
        local status
        status=$(get_db_status "${inst}")
        log "  Instance ${inst} status: ${status}"
        if [[ "${status}" != "DOWN" ]] && [[ "${DRY_RUN}" != "true" ]]; then
            warn "  Instance ${inst} reported status '${status}' -- expected DOWN"
            all_down=false
        fi
    done
    if [[ "${all_down}" == "false" ]]; then
        error "S4: Not all standby instances are DOWN after shutdown. Check srvctl/alert logs."
    fi

    log_chain_event "S4_SHUTDOWN stby=${STBY_DB_UNIQUE_NAME} instances=${STBY_INSTANCES}"

    # Register rollback: bring the standby back to OPEN READ ONLY and re-enable redo apply.
    # Since run_rollbacks uses eval in the current shell, all script functions are available.
    # _rb_s4_restore_standby is defined immediately below; it handles RAC/non-RAC and polls
    # for OPEN status before issuing APPLY-ON so S5's ACL restore always has a live DB.
    register_rollback "S5-restore-standby-open" "_rb_s5_restore_standby"

    success "S4: Standby database shutdown confirmed"
}

# Rollback function for S4: bring standby to OPEN READ ONLY -> APPLY-ON via DGMGRL.
# Called via eval inside run_rollbacks -- all script variables and functions are in scope.
#
# State machine before acting:
#   DOWN    -> srvctl start database -o open  (full cold start)
#   STARTED -> srvctl start database -o open  (instance started but not mounted yet)
#   MOUNTED -> ALTER DATABASE OPEN READ ONLY  (already mounted, just needs opening)
#   OPEN    -> no DB action needed            (already in the right state)
#
# After confirming OPEN, re-enables redo apply via DGMGRL.
_rb_s5_restore_standby() {
    local _poll_max=120 _poll_interval=10 _waited=0 _current_status

    # --- Check current state before taking any action ---
    _current_status=$(get_db_status "${STBY_ORACLE_SID}")
    log "[rollback:S5] Pre-rollback status of ${STBY_ORACLE_SID}: ${_current_status}"

    case "${_current_status}" in

        OPEN)
            log "[rollback:S5] Standby already OPEN -- skipping startup"
            ;;

        MOUNTED)
            log "[rollback:S5] Standby is MOUNTED -- issuing ALTER DATABASE OPEN READ ONLY"
            ORACLE_SID="${STBY_ORACLE_SID}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba \
                >> "${LOGFILE}" 2>&1 <<'_RBEOF'
ALTER DATABASE OPEN READ ONLY;
EXIT;
_RBEOF
            ;;

        DOWN|STARTED|*)
            # DOWN:    instance not running at all -- full start via srvctl
            # STARTED: instance process up but not yet mounted (pmon alive, no controlfile)
            # *:       any unexpected/unknown state -- attempt a full start and let srvctl report
            log "[rollback:S5] Standby is ${_current_status} -- starting database via srvctl (option=open)"
            timeout "${SRVCTL_TIMEOUT}" "${ORACLE_HOME}/bin/srvctl" start database \
                -d "${STBY_DB_UNIQUE_NAME}" -o open >> "${LOGFILE}" 2>&1
            ;;
    esac

    # --- Poll until OPEN (covers all paths including the already-OPEN fast path) ---
    log "[rollback:S5] Waiting for ${STBY_ORACLE_SID} to reach OPEN status..."
    local _status
    while (( _waited < _poll_max )); do
        _status=$(get_db_status "${STBY_ORACLE_SID}")
        log "[rollback:S5] Instance ${STBY_ORACLE_SID} status: ${_status} (waited ${_waited}s)"
        if [[ "${_status}" == "OPEN" ]]; then
            break
        fi
        sleep "${_poll_interval}"
        (( _waited += _poll_interval ))
    done

    if [[ "${_status}" != "OPEN" ]]; then
        log "[rollback:S5] ERROR: ${STBY_ORACLE_SID} did not reach OPEN after ${_poll_max}s (last status=${_status})"
        return 1
    fi

    # --- Re-enable redo apply ---
    log "[rollback:S5] Standby is OPEN -- re-enabling redo apply via DGMGRL"
    "${ORACLE_HOME}/bin/dgmgrl" -silent / >> "${LOGFILE}" 2>&1 <<_RBEOF
CONNECT /;
EDIT DATABASE ${STBY_DB_UNIQUE_NAME} SET STATE='APPLY-ON';
EXIT;
_RBEOF
    log "[rollback:S5] APPLY-ON issued successfully"
}

# ---------------------------------------------------------------------------
# S6: Set Standby Datafile ACLs to READ ONLY (via SYSASM)
# Runs set_datafiles_read_only.sql as the grid/SYSASM user in ASM.
# This prevents the old datafiles from being written to -- they become
# the immutable parent files for the new sparse layer.
# ---------------------------------------------------------------------------
ss_s6_set_datafiles_readonly() {
    step "S6 -- Set Standby Datafile ACLs to READ ONLY (SYSASM)"
    log "Running set_datafiles_read_only.sql as SYSASM"
    log "This makes current standby datafiles immutable parent files."

    local readonly_sql="${WORK_DIR}/set_datafiles_read_only.sql"
    [[ -f "${readonly_sql}" ]] || error "S5: set_datafiles_read_only.sql not found. Did S3 run?"

    local perm_count
    perm_count=$(grep -c "ALTER DISKGROUP" "${readonly_sql}" || echo 0)
    log "Permission statements to execute: ${perm_count}"

    # --- Idempotency: check if standby datafiles are already READ ONLY ---
    # Strategy: extract the diskgroup names from the generated readonly_sql
    # (e.g. "ALTER DISKGROUP DATA SET PERMISSION ... FOR FILE '...'"), then
    # query v$asm_file.permissions for those diskgroups via run_sqlfile_asm.
    #
    # v$asm_alias is NOT used (ASM filenames lack .dbf extension).
    # The tmpfile is written then read via run_sqlfile_asm so it works for
    # all three ASM_EXEC_METHOD modes (sudo / ssh / direct).
    #
    # If the query fails for any reason we warn and proceed -- ALTER DISKGROUP
    # SET PERMISSION is idempotent so re-running on already-READ-ONLY files
    # is safe and produces no error.
    substep "Checking current ASM file permissions (idempotency check)"
    local rw_count="UNKNOWN"

    if [[ "${DRY_RUN}" != "true" ]]; then
        # Extract unique diskgroup names from the generated SQL file
        local s6_dg_names s6_dg_in_list
        s6_dg_names=$(grep -oE 'DISKGROUP [A-Za-z0-9_]+' "${readonly_sql}" \
                      | awk '{print $2}' | sort -u)

        if [[ -n "${s6_dg_names}" ]]; then
            s6_dg_in_list=$(echo "${s6_dg_names}" \
                            | sed "s/^/'/;s/$/'/" | paste -sd ',' -)

            # Write the idempotency query to a tmpfile that run_sqlfile_asm
            # will execute.  run_sqlfile_asm uses run_as_grid internally, so
            # the file must be readable by the grid OS user.
            # For ssh method: ASM_SSH_HOST defaults to localhost, so /tmp is
            # shared.  chmod 644 ensures grid can read it regardless of method.
            local s6_idem_tmpf
            s6_idem_tmpf=$(mktemp /tmp/s6_idem_XXXXXX.sql)
            chmod 644 "${s6_idem_tmpf}"

            cat > "${s6_idem_tmpf}" <<EOSQL
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET TRIMSPOOL ON
SELECT COUNT(*)
FROM   v\$asm_file f
JOIN   v\$asm_diskgroup g ON f.group_number = g.group_number
WHERE  g.name IN (${s6_dg_in_list})
AND    f.permissions NOT LIKE 'r--r-----';
EXIT
EOSQL

            # Capture stdout only; run_as_grid log lines now go to stderr
            local s6_idem_out=""
            s6_idem_out=$(run_as_grid \
                "ORACLE_SID=${ASM_SID} ${GRID_HOME}/bin/sqlplus -S / as sysasm @${s6_idem_tmpf}" \
                2>/dev/null | tr -d ' \n\r') || s6_idem_out=""
            rm -f "${s6_idem_tmpf}"

            log "s6 idempotency raw result: '${s6_idem_out}'"

            if [[ "${s6_idem_out}" =~ ^[0-9]+$ ]]; then
                rw_count="${s6_idem_out}"
            else
                warn "s6: Idempotency query returned unexpected value: '${s6_idem_out}' -- proceeding"
            fi
        else
            warn "s6: Could not extract diskgroup names from ${readonly_sql} -- skipping idempotency check"
        fi
    fi

    if [[ "${rw_count}" == "UNKNOWN" ]]; then
        warn "s6: Could not determine current file permissions -- proceeding with SET PERMISSION (safe: idempotent)"
    elif [[ "${rw_count}" == "0" ]]; then
        log "S5: All datafiles already READ ONLY in ASM ACL (rw_count=0) -- skipping SET PERMISSION"
        log_chain_event "S5_READONLY_SKIPPED stby=${STBY_DB_UNIQUE_NAME} reason=already-readonly"
        success "S5: Datafile ACLs already READ ONLY (idempotent skip)"
        return 0
    else
        log "s6: ${rw_count} datafile(s) still have non-READ-ONLY permissions -- applying SET PERMISSION"
    fi

    substep "Executing permission changes as SYSASM"
    run_sqlfile_asm "${readonly_sql}" "s5-set-readonly"

    # Register rollback: restore datafiles to READ WRITE using the script pre-generated at S3.
    # run_sqlplus_asm talks directly to the ASM instance -- the standby DB does not need to be open.
    # LIFO order guarantees S5's rollback (restart standby) runs BEFORE this one, so any
    # subsequent operations that do require the DB will find it up.
    local _readwrite_sql="${WORK_DIR}/s6_rollback_readwrite.sql"
    if [[ -f "${_readwrite_sql}" ]]; then
        register_rollback "S6-restore-readwrite-acl" \
            "run_sqlfile_asm '${_readwrite_sql}' 'S6-rollback-readwrite'"
    else
        warn "S5: Rollback script ${_readwrite_sql} not found (S3 may not have run) -- ACL restore must be manual"
    fi

    log_chain_event "S5_READONLY_SET stby=${STBY_DB_UNIQUE_NAME} statements=${perm_count}"
    success "S5: ${perm_count} datafile(s) set to READ ONLY in ASM ACL"
}

# ---------------------------------------------------------------------------
# S7: Startup First Standby Instance in MOUNT
# Only the first (apply) instance is started at this stage.
# MOUNT is required so we can run rename_files.sql against the controlfile.
# ---------------------------------------------------------------------------
ss_s7_startup_first_instance_mount() {
    step "S7 -- Start First Standby Instance in MOUNT: ${STBY_ORACLE_SID}"
    log "Starting only the first instance in MOUNT mode."
    log "This is required before CLONEDB_RENAMEFILE can update the controlfile."

    # --- Idempotency: skip startup if already in MOUNT or beyond ---
    substep "Checking current instance status"
    local current_status
    current_status=$(get_db_status "${STBY_ORACLE_SID}")
    log "Current status: ${current_status}"

    if [[ "${current_status}" == "MOUNTED" ]]; then
        log "S6: ${STBY_ORACLE_SID} is already MOUNTED -- skipping STARTUP MOUNT"
        log_chain_event "S6_STARTUP_MOUNT_SKIPPED instance=${STBY_ORACLE_SID} reason=already-mounted"
        success "S6: Instance already MOUNTED (idempotent skip)"
        return 0
    elif [[ "${current_status}" == "OPEN" ]]; then
        log "S6: ${STBY_ORACLE_SID} is already OPEN -- skipping STARTUP MOUNT"
        log_chain_event "S6_STARTUP_MOUNT_SKIPPED instance=${STBY_ORACLE_SID} reason=already-open"
        success "S6: Instance already OPEN (idempotent skip)"
        return 0
    fi

    start_standby_first_instance_mount
    [[ "${DRY_RUN}" == "true" ]] || verify_db_status "${STBY_ORACLE_SID}" "MOUNTED" "S6"

    log_chain_event "S6_STARTUP_MOUNT instance=${STBY_ORACLE_SID}"
    success "S6: Instance ${STBY_ORACLE_SID} is MOUNTED"
}

# ---------------------------------------------------------------------------
# S8: Run rename_files.sql (DBMS_DNFS.CLONEDB_RENAMEFILE)
# Executed while the first instance is in MOUNT mode.
# This creates the sparse child datafiles and records parent-child
# relationships in the controlfile.
# ---------------------------------------------------------------------------
ss_s8_run_renamefile() {
    step "S8 -- Execute rename_files.sql (DBMS_DNFS.CLONEDB_RENAMEFILE)"
    log "Creating sparse child datafiles in ${SNAP_SPARSE_DG}"
    log "This updates the controlfile with parent-child relationships."
    log "Instance : ${STBY_ORACLE_SID}  (must be in MOUNT)"

    local rename_sql="${WORK_DIR}/rename_files.sql"
    [[ -f "${rename_sql}" ]] || error "S7: rename_files.sql not found. Did S2 run?"

    [[ "${DRY_RUN}" == "true" ]] || verify_db_status "${STBY_ORACLE_SID}" "MOUNTED" "S7-pre-check"

    # --- Idempotency: skip if sparse files for this index already exist ---
    substep "Checking V\$CLONEDFILE for existing T${SNAP_INDEX} entries"
    local existing_count
    existing_count=$(sqlplus_check "${STBY_ORACLE_SID}" \
        "SELECT COUNT(*) FROM V\$CLONEDFILE WHERE clonefilename LIKE '%_T${SNAP_INDEX}%';" \
        "S7-idempotency-check" | grep -v '^$' | tail -1 | tr -d ' ') || existing_count=0
    if [[ "${DRY_RUN}" != "true" ]] && [[ "${existing_count:-0}" -gt 0 ]]; then
        log "S7: V\$CLONEDFILE already has ${existing_count} entries for index T${SNAP_INDEX} -- skipping CLONEDB_RENAMEFILE"
        log_chain_event "S7_RENAMEFILE_SKIPPED index=T${SNAP_INDEX} existing=${existing_count} reason=already-renamed"
        success "S7: Sparse files for T${SNAP_INDEX} already registered (idempotent skip)"
        return 0
    fi

    substep "Executing CLONEDB_RENAMEFILE for all datafiles (index T${SNAP_INDEX})"

    # Save current STANDBY_FILE_MANAGEMENT value, set to MANUAL, then restore.
    # CLONEDB_RENAMEFILE requires MANUAL; AUTO would conflict with the rename.
    local sfm_prev
    sfm_prev=$(sqlplus_check "${STBY_ORACLE_SID}" \
        "SELECT VALUE FROM V\$PARAMETER WHERE NAME='standby_file_management';" \
        "S7-sfm-get" | grep -v '^$' | tail -1 | tr -d ' ') || sfm_prev="AUTO"
    sfm_prev="${sfm_prev:-AUTO}"
    log "S7: standby_file_management current value: ${sfm_prev} -- setting to MANUAL for CLONEDB_RENAMEFILE"
    sqlplus_check "${STBY_ORACLE_SID}" \
        "ALTER SYSTEM SET standby_file_management='MANUAL';" \
        "S7-sfm-set-manual" > /dev/null

    local _sfm_rc=0
    safe_exec -l "S7-clonedb-renamefile" -t 1800 -- \
        "ORACLE_SID='${STBY_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' / as sysdba @'${rename_sql}'" \
        || _sfm_rc=$?

    # Restore standby_file_management regardless of success/failure
    log "S7: Restoring standby_file_management to '${sfm_prev}'"
    sqlplus_check "${STBY_ORACLE_SID}" \
        "ALTER SYSTEM SET standby_file_management='${sfm_prev}';" \
        "S7-sfm-restore" > /dev/null || warn "S7: Failed to restore standby_file_management to '${sfm_prev}' -- check manually"

    [[ "${_sfm_rc}" -eq 0 ]] || error "S7: CLONEDB_RENAMEFILE failed (rc=${_sfm_rc})"

    # Verify that V$CLONEDFILE was populated
    substep "Verifying V\$CLONEDFILE was populated"
    local cloned_count
    cloned_count=$(sqlplus_check "${STBY_ORACLE_SID}" \
        "SELECT COUNT(*) FROM V\$CLONEDFILE;" "S7-clonedfile-count" | \
        grep -v '^$' | tail -1 | tr -d ' ')
    log "V\$CLONEDFILE row count: ${cloned_count}"
    if [[ "${DRY_RUN}" != "true" ]] && [[ "${cloned_count:-0}" -eq 0 ]]; then
        error "S7: V\$CLONEDFILE is empty after CLONEDB_RENAMEFILE. dNFS may not be configured."
    fi

    log_chain_event "S7_RENAMEFILE_DONE index=T${SNAP_INDEX} cloned_files=${cloned_count}"
    success "S7: CLONEDB_RENAMEFILE complete -- ${cloned_count} sparse file(s) created (T${SNAP_INDEX})"
}

# ---------------------------------------------------------------------------
# S9: Open Standby Database READ ONLY
# After creating sparse datafiles, the standby is opened READ ONLY.
# This is done only on the first instance; other RAC instances follow in S9.
# ---------------------------------------------------------------------------
ss_s9_open_standby_readonly() {
    step "S9 -- Open Standby Database READ ONLY"
    log "Opening standby as READ ONLY on first instance: ${STBY_ORACLE_SID}"
    log "Redo apply will resume after all instances are up (S10)."

    # --- Idempotency: skip if already OPEN ---
    substep "Checking current instance status"
    local current_status
    current_status=$(get_db_status "${STBY_ORACLE_SID}")
    log "Current status: ${current_status}"
    if [[ "${current_status}" == "OPEN" ]] && [[ "${DRY_RUN}" != "true" ]]; then
        log "S8: ${STBY_ORACLE_SID} is already OPEN -- skipping ALTER DATABASE OPEN READ ONLY"
        log_chain_event "S8_OPEN_READONLY_SKIPPED instance=${STBY_ORACLE_SID} reason=already-open"
        success "S8: Standby already OPEN (idempotent skip)"
        return 0
    fi

    substep "Executing ALTER DATABASE OPEN READ ONLY"
    safe_exec -l "S8-open-readonly" -t 180 -- \
        "ORACLE_SID='${STBY_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' / as sysdba <<'_EOF'
ALTER DATABASE OPEN READ ONLY;
EXIT
_EOF"

    [[ "${DRY_RUN}" == "true" ]] || verify_db_status "${STBY_ORACLE_SID}" "OPEN" "S8"

    log_chain_event "S8_OPEN_READONLY instance=${STBY_ORACLE_SID}"
    success "S8: Standby database OPEN READ ONLY on ${STBY_ORACLE_SID}"
}

# ---------------------------------------------------------------------------
# S10: Start Remaining RAC Instances
# In RAC mode, starts all instances except the first (which is already open).
# ---------------------------------------------------------------------------
ss_s10_start_remaining_instances() {
    step "S10 -- Start Remaining RAC Instances"

    log "Starting all RAC instances except first (${STBY_ORACLE_SID})"
    start_remaining_standby_instances

    # Verify each additional instance is OPEN
    substep "Verifying all additional instances are OPEN"
    for inst in ${STBY_INSTANCES}; do
        [[ "${inst}" == "${STBY_ORACLE_SID}" ]] && continue
        if [[ "${DRY_RUN}" != "true" ]]; then
            verify_db_status "${inst}" "OPEN" "S9-inst-${inst}"
        else
            log "[DRY-RUN] Would verify status of ${inst}"
        fi
    done

    log_chain_event "S9_REMAINING_INSTANCES_STARTED instances=${STBY_INSTANCES}"
    success "S9: All RAC instances started"
}

# ---------------------------------------------------------------------------
# S11: Restart Redo Apply (DGMGRL)
# Re-enables log shipping and redo apply so the standby continues to
# receive and apply redo from the primary (or cascade source).
# ---------------------------------------------------------------------------
ss_s11_restart_redo_apply() {
    step "S11 -- Restart Redo Apply on ${STBY_DB_UNIQUE_NAME}"
    log "Re-enabling redo apply via DGMGRL."
    log "The standby will now receive and apply redo to the NEW sparse datafiles."

    if [[ "${CASCADED_STANDBY}" == "true" ]]; then
        log "Cascaded topology: redo flows from ${CASCADE_SOURCE_DB_UNIQUE_NAME} -> ${STBY_DB_UNIQUE_NAME}"
    else
        log "Direct topology: redo flows from ${PRIMARY_DB_UNIQUE_NAME} -> ${STBY_DB_UNIQUE_NAME}"
    fi

    # --- Idempotency: check if apply is already ON ---
    substep "Checking current Data Guard apply state"
    local dg_before
    dg_before=$(dgmgrl_check "SHOW DATABASE ${STBY_DB_UNIQUE_NAME};" "S10-show-before")
    log_output "S10-DG-STATE-BEFORE" "${dg_before}"

    local current_state
    current_state=$(echo "${dg_before}" | grep -i "Intended State" | head -1 || true)
    if echo "${current_state}" | grep -qi "APPLY-ON"; then
        log "S10: Intended State is already APPLY-ON -- redo apply already running, skipping"
        log_chain_event "S10_APPLY_ON_SKIPPED stby=${STBY_DB_UNIQUE_NAME} reason=already-on"
        success "S10: Redo apply already running (idempotent skip)"
        return 0
    fi

    substep "Issuing APPLY-ON to DGMGRL"
    safe_exec -l "S10-dgmgrl-apply-on" -t 120 -- \
        "'${ORACLE_HOME}/bin/dgmgrl' -silent / <<'_EOF'
CONNECT /;
EDIT DATABASE ${STBY_DB_UNIQUE_NAME} SET STATE='APPLY-ON';
EXIT;
_EOF"

    # Verify the state change
    substep "Verifying DGMGRL state is now APPLY-ON"
    local dg_state state_line
    dg_state=$(dgmgrl_check "SHOW DATABASE ${STBY_DB_UNIQUE_NAME};" "S10-show-after")
    log_output "S10-DG-STATE-AFTER" "${dg_state}"
    state_line=$(echo "${dg_state}" | grep -i "Intended State" | head -1 || true)
    log "DG Intended State: ${state_line}"
    if ! echo "${state_line}" | grep -qi "APPLY-ON"; then
        error "S10: Redo apply did not restart. Expected 'APPLY-ON' in: ${state_line}"
    fi

    log_chain_event "S10_APPLY_ON stby=${STBY_DB_UNIQUE_NAME}"
    success "S10: Redo apply restarted on ${STBY_DB_UNIQUE_NAME}"
}

# ---------------------------------------------------------------------------
# S12: Verify Redo Apply is Catching Up
# Polls DGMGRL for Transport Lag and Apply Lag until they fall below
# DGMGRL_APPLY_LAG_THRESHOLD seconds, or until DGMGRL_APPLY_WAIT_SECS elapsed.
# ---------------------------------------------------------------------------
ss_s12_verify_apply_lag() {
    step "S12 -- Verify Redo Apply State and Lag"
    log "Polling Data Guard apply lag. Max wait: ${DGMGRL_APPLY_WAIT_SECS}s"
    log "Acceptable lag threshold: ${DGMGRL_APPLY_LAG_THRESHOLD}s"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] Skipping apply lag poll"
        success "S11: Skipped (dry-run)"
        return 0
    fi

    local waited=0 poll_interval=10
    local transport_lag apply_lag transport_ok=false apply_ok=false

    substep "Polling apply lag (interval=${poll_interval}s, max=${DGMGRL_APPLY_WAIT_SECS}s)"
    while [[ ${waited} -lt ${DGMGRL_APPLY_WAIT_SECS} ]]; do
        local dg_verbose_out
        dg_verbose_out=$(dgmgrl_check "SHOW DATABASE VERBOSE ${STBY_DB_UNIQUE_NAME};" "S11-poll") || true

        transport_lag=$(echo "${dg_verbose_out}" | grep -i "Transport Lag" | head -1 | \
            grep -oE '[0-9]+' | head -1 || echo "999")
        apply_lag=$(echo "${dg_verbose_out}" | grep -i "Apply Lag" | head -1 | \
            grep -oE '[0-9]+' | head -1 || echo "999")

        log "  [t=${waited}s] Transport Lag: ${transport_lag}s  Apply Lag: ${apply_lag}s  (threshold: ${DGMGRL_APPLY_LAG_THRESHOLD}s)"

        if [[ "${transport_lag:-999}" -le "${DGMGRL_APPLY_LAG_THRESHOLD}" ]]; then
            transport_ok=true
        fi
        if [[ "${apply_lag:-999}" -le "${DGMGRL_APPLY_LAG_THRESHOLD}" ]]; then
            apply_ok=true
        fi

        if [[ "${transport_ok}" == "true" ]] && [[ "${apply_ok}" == "true" ]]; then
            log "  Both lags within threshold after ${waited}s"
            break
        fi

        sleep "${poll_interval}"
        (( waited += poll_interval )) || true
    done

    # Final DG state summary
    substep "Final Data Guard status"
    local final_state
    final_state=$(dgmgrl_check "SHOW DATABASE VERBOSE ${STBY_DB_UNIQUE_NAME};" "S11-final")
    log_output "S11-FINAL-DG-STATE" "${final_state}"

    if [[ "${transport_ok}" == "false" ]] || [[ "${apply_ok}" == "false" ]]; then
        warn "S11: Apply lag did not reach threshold within ${DGMGRL_APPLY_WAIT_SECS}s"
        warn "     Transport Lag: ${transport_lag:-unknown}s  Apply Lag: ${apply_lag:-unknown}s"
        warn "     This may be normal for a large redo backlog -- monitor manually."
        warn "     SQL: SELECT NAME, VALUE FROM V\$DATAGUARD_STATS;"
    else
        success "S11: Transport Lag=${transport_lag}s, Apply Lag=${apply_lag}s -- within threshold"
    fi

    log_chain_event "S11_LAG_CHECK transport=${transport_lag} apply=${apply_lag} waited=${waited}s"
    success "S11: Redo apply verification complete"
}

# ---------------------------------------------------------------------------
# S13: Verify Sparse File Relationships (V$CLONEDFILE)
# Confirms the parent-child relationships are correctly recorded.
# ---------------------------------------------------------------------------
ss_s13_verify_sparse_files() {
    step "S13 -- Verify Sparse Parent-Child File Relationships (V\$CLONEDFILE)"
    log "Querying V\$CLONEDFILE on ${STBY_ORACLE_SID}"

    local clone_count
    clone_count=$(verify_clonedfile "${STBY_ORACLE_SID}" "${SNAP_SPARSE_DG}" "S12")

    log_chain_event "S12_VERIFY_OK cloned=${clone_count} index=T${SNAP_INDEX}"
    success "S12: ${clone_count} sparse file relationship(s) verified in V\$CLONEDFILE"
}

# ---------------------------------------------------------------------------
# S14: Final Chain Depth Check and Snapshot Summary
# Updates the chain log with the completed snapshot event.
# ---------------------------------------------------------------------------
ss_s14_chain_depth_post_check() {
    step "S14 -- Post-Snapshot Chain Depth Check and Audit"
    log "Performing final chain depth check after snapshot creation"

    local depth
    depth=$(get_sparse_chain_depth)
    log "Post-snapshot chain depth: ${depth}"
    log "Oracle hard limit: 10 links"

    substep "Logging snapshot event to chain history"
    log_chain_event "S13_SNAPSHOT_COMPLETE index=T${SNAP_INDEX} post_depth=${depth} stby=${STBY_DB_UNIQUE_NAME} sparse_dg=${SNAP_SPARSE_DG}"

    if [[ "${depth}" -ge "${SPARSE_CHAIN_WARN_DEPTH}" ]]; then
        warn "Chain depth ${depth} is approaching maximum (${SPARSE_CHAIN_MAX_DEPTH})"
        warn "Consider planning a new baseline standby. Chain history: ${CHAIN_LOG}"
    fi

    # Dump the current chain log tail to the log file for visibility
    tail -10 "${CHAIN_LOG}" 2>/dev/null >> "${LOGFILE}" || true

    success "S14: Sparse standby snapshot cycle complete. Chain depth: ${depth}"
}


# =============================================================================
# SECTION 12 -- PART B: HIERARCHICAL SPARSE CLONE CREATION (Steps 1-14)
# Creates a read/write sparse clone database from the Sparse Test Master
# (the standby after Part A). Inherits the full v10 creation cycle.
# =============================================================================

# ---------------------------------------------------------------------------
# Step 1: Backup Control File to Trace (Test Master / Standby)
# ---------------------------------------------------------------------------
step1_backup_controlfile_trace() {
    step "1 -- Backup Control File to Trace (${TM_ORACLE_SID})"
    log "Triggering ALTER DATABASE BACKUP CONTROLFILE TO TRACE"

    local step1_out trace_file
    step1_out=$(sqlplus_check "${TM_ORACLE_SID}" "
ALTER DATABASE BACKUP CONTROLFILE TO TRACE;
SELECT value FROM v\$diag_info WHERE name = 'Default Trace File';" "step1-backup-ctlfile")

    trace_file=$(echo "${step1_out}" | grep -v '^$' | tail -1 | tr -d ' ')
    [[ -n "${trace_file}" ]] || error "step1: Could not parse trace file path from sqlplus output"
    [[ -f "${trace_file}" ]] || error "step1: Trace file does not exist: '${trace_file}'"
    log "Trace file: ${trace_file}  ($(wc -l < "${trace_file}") lines)"

    substep "Copying trace file to work directory"
    cp "${trace_file}" "${WORK_DIR}/controlfile_trace.trc"
    [[ -s "${WORK_DIR}/controlfile_trace.trc" ]] || error "step1: Copied trace file is empty"

    success "Step 1: Control file trace: ${WORK_DIR}/controlfile_trace.trc"
}

# ---------------------------------------------------------------------------
# Step 2: Generate rename_files.sql (Test Master Datafile Mapping)
# ---------------------------------------------------------------------------
step2_generate_rename_script() {
    step "2 -- Generate rename_files.sql (Test Master Datafile Mapping)"

    local rename_sql="${WORK_DIR}/rename_files.sql"
    local rename_count
    rename_count=$(_generate_renamefile_sql \
        "${TM_ORACLE_SID}" "${rename_sql}" \
        "${TM_DATA_DG}" "${SNAP_SPARSE_DG}" "${SNAP_INDEX}" "step2-spool")

    RENAME_SQL="${rename_sql}"
    success "Step 2: rename_files.sql: ${rename_sql} (${rename_count} entries)"
}

# ---------------------------------------------------------------------------
# Step 3: Create init.ora from Test Master SPFILE
# ---------------------------------------------------------------------------
step3_create_tm_initora() {
    step "3 -- Export Test Master SPFILE to init.ora"
    TM_INIT="${WORK_DIR}/init_${TM_DB_NAME}.ora"
    log "Target init.ora : ${TM_INIT}"

    # --- Idempotency: skip if a valid PFILE already exists ---
    if [[ -s "${TM_INIT}" ]]; then
        log "step3: ${TM_INIT} already exists and is non-empty ($(wc -l < "${TM_INIT}") lines) -- skipping CREATE PFILE"
        success "Step 3: Test Master init.ora already present (idempotent skip)"
        return 0
    fi

    log "Creating ${TM_INIT} from SPFILE on ${TM_ORACLE_SID}"
    sqlplus_check "${TM_ORACLE_SID}" \
        "CREATE PFILE = '${TM_INIT}' FROM SPFILE;" "step3-pfile" > /dev/null

    [[ -f "${TM_INIT}" ]] || error "step3: PFILE not created: ${TM_INIT}"
    [[ -s "${TM_INIT}" ]] || error "step3: PFILE is empty: ${TM_INIT}"
    log "PFILE lines: $(wc -l < "${TM_INIT}")"
    success "Step 3: Test Master init.ora: ${TM_INIT}"
}

# ---------------------------------------------------------------------------
# Step 4: Shut Down Test Master
# ---------------------------------------------------------------------------
step4_shutdown_testmaster() {
    step "4 -- Shut Down Test Master Database: ${TM_ORACLE_SID}"

    if [[ "${FORCE_SHUTDOWN}" != "true" ]]; then
        error "step4: Refusing to shut down Test Master '${TM_ORACLE_SID}' without authorisation.
  Set FORCE_SHUTDOWN=true in config or pass --force-shutdown.
  Verify no sessions: SQL> SELECT count(*) FROM v\\\$session WHERE type='USER' AND status='ACTIVE';"
    fi

    # --- Idempotency: skip if TM is already down ---
    substep "Checking current Test Master status"
    local current_status
    current_status=$(get_db_status "${TM_ORACLE_SID}")
    log "Current status: ${current_status}"
    if [[ "${current_status}" == "DOWN" ]] && [[ "${DRY_RUN}" != "true" ]]; then
        log "step4: ${TM_ORACLE_SID} is already DOWN -- skipping shutdown"
        success "Step 4: Test Master already DOWN (idempotent skip)"
        return 0
    fi

    substep "Checking for active user sessions"
    local active_sessions
    active_sessions=$(ORACLE_SID="${TM_ORACLE_SID}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba 2>/dev/null <<'EOSQL' | tr -d ' \n\r'
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SELECT COUNT(*) FROM v$session WHERE type='USER' AND status='ACTIVE';
EXIT
EOSQL
) || active_sessions="UNKNOWN"
    log "Active user sessions: ${active_sessions}"
    if [[ "${active_sessions}" != "0" ]] && [[ "${active_sessions}" != "UNKNOWN" ]]; then
        warn "step4: ${active_sessions} active session(s) -- proceeding with SHUTDOWN IMMEDIATE (FORCE_SHUTDOWN=true)"
    fi

    substep "Executing SHUTDOWN IMMEDIATE"
    safe_exec -l "step4-shutdown-immediate" -t 600 -- \
        "ORACLE_SID='${TM_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' / as sysdba <<'_EOF'
SHUTDOWN IMMEDIATE;
EXIT
_EOF"

    substep "Confirming instance is DOWN"
    local post_status
    post_status=$(get_db_status "${TM_ORACLE_SID}")
    log "Post-shutdown status: '${post_status}'"
    if [[ "${DRY_RUN}" != "true" ]] && [[ "${post_status}" == "OPEN" ]]; then
        error "step4: Test Master still OPEN after SHUTDOWN IMMEDIATE"
    fi
    success "Step 4: Test Master ${TM_ORACLE_SID} is DOWN"
}

# ---------------------------------------------------------------------------
# Step 5: Create snap_init.ora for Snapshot Database
# ---------------------------------------------------------------------------
step5_create_snap_initora() {
    step "5 -- Create snap_init.ora for Snapshot Database: ${SNAP_DB_NAME}"
    # TM_INIT is set by step3_create_tm_initora; verify it is present
    : "${TM_INIT:="${WORK_DIR}/init_${TM_DB_NAME}.ora"}"
    SNAP_INIT="${WORK_DIR}/snap_init.ora"
    [[ -f "${TM_INIT}" ]] || error "Test Master init.ora not found: ${TM_INIT}"

    substep "Copying TM init.ora and patching for snapshot"
    cp "${TM_INIT}" "${SNAP_INIT}"

    log "Patching parameters: db_name, db_unique_name, control_files, audit_file_dest, log_archive_dest_1"

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
        print(f"[INFO] Replaced: {key}")
    else:
        content += f'\n{replacement}'
        print(f"[INFO] Added: {key}")

for remove_key in ['db_recovery_file_dest', 'fal_server', 'fal_client',
                   'log_archive_dest_2', 'log_archive_dest_3',
                   'standby_file_management', 'dg_broker_start']:
    before = content
    content = re.sub(r'^\s*\*?\.' + remove_key + r'\s*=.*$', '',
                     content, flags=re.IGNORECASE | re.MULTILINE)
    if content != before:
        print(f"[INFO] Removed: {remove_key}")

with open("${SNAP_INIT}", 'w') as f:
    f.write(content)

missing = []
for k in params:
    if not re.search(r'^\*?\.' + k + r'\s*=\s*.+', content, re.IGNORECASE | re.MULTILINE):
        missing.append(k)
if missing:
    print(f"ERROR: Missing required params after patching: {missing}", file=sys.stderr)
    sys.exit(1)

print("snap_init.ora patched successfully")
PYEOF

    local py_rc=$?
    [[ ${py_rc} -ne 0 ]] && error "step5: snap_init.ora patch failed (exit ${py_rc})"
    [[ -s "${SNAP_INIT}" ]] || error "step5: snap_init.ora is empty after patching"

    grep -E "db_name|db_unique_name|control_files|audit_file_dest" "${SNAP_INIT}" >> "${LOGFILE}"
    success "Step 5: snap_init.ora: ${SNAP_INIT}"
}

# ---------------------------------------------------------------------------
# Step 6: Build CREATE CONTROLFILE Script
# ---------------------------------------------------------------------------
step6_build_controlfile_script() {
    step "6 -- Build CREATE CONTROLFILE Script for Snapshot DB"
    TRACE="${WORK_DIR}/controlfile_trace.trc"
    CTL_SQL="${WORK_DIR}/crt_ctlfile.sql"
    [[ -f "${TRACE}" ]] || error "Trace file not found: ${TRACE}. Did step 1 complete?"
    log "Trace file: ${TRACE}  ($(wc -l < "${TRACE}") lines)"

    grep -in "create controlfile\|resetlogs" "${TRACE}" >> "${LOGFILE}" 2>/dev/null || true

    local PYFILE
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

# Strategy 1: Set #2 marker
m = re.search(r"Set\s+[#]2\b[^\n]*\n", raw, re.IGNORECASE)
if m:
    after = raw[m.end():]
    bm = re.search(
        r"(CREATE\s+CONTROLFILE\b.+?(?:CHARACTER\s+SET\s+\w+[^\n]*\n\s*;?\s*\n|;\s*\n))",
        after, re.DOTALL | re.IGNORECASE)
    if bm and re.search(r"\bRESETLOGS\b", bm.group(1), re.IGNORECASE):
        resetlogs_block = bm.group(1).strip()
        strategy = "Set#2 marker"

# Strategy 2: block scan
if not resetlogs_block:
    for blk in re.findall(
            r"(CREATE\s+CONTROLFILE\b.+?(?:CHARACTER\s+SET\s+\w+[^\n]*\n\s*;?\s*\n|;\s*\n))",
            raw, re.DOTALL | re.IGNORECASE):
        if re.search(r"\bRESETLOGS\b", blk, re.IGNORECASE):
            resetlogs_block = blk.strip()
            strategy = "block scan"
            break

# Strategy 3: greedy RESETLOGS to semicolon
if not resetlogs_block:
    m3 = re.search(r"(CREATE\s+CONTROLFILE\b[^;]*\bRESETLOGS\b[^;]*;)",
                   raw, re.DOTALL | re.IGNORECASE)
    if m3:
        resetlogs_block = m3.group(1).strip()
        strategy = "greedy scan"

if not resetlogs_block:
    print("ERROR: Could not find RESETLOGS CREATE CONTROLFILE in trace.", file=sys.stderr)
    for i, ln in enumerate(raw.splitlines(), 1):
        if "CREATE CONTROLFILE" in ln.upper():
            print(f"  L{i}: {ln.rstrip()}")
    sys.exit(1)

print(f"[INFO] Matched via strategy: {strategy}")
cmd = resetlogs_block.strip().rstrip(";").strip() + ";"
cmd = re.sub(r'(?i)((?:SET\s+)?DATABASE\s+)"?' + re.escape(TM_NAME) + r'"?',
             r'\g<1>' + SNAP_NAME, cmd)

log_lines = [
    f"    GROUP {i} '{SNAP_DG}/{SNAP_NAME}/t_log{i}.f' SIZE {REDO_SZ} BLOCKSIZE {REDO_BS}"
    for i in range(1, REDO_GRP + 1)
]
new_logfile = "  LOGFILE\n" + ",\n".join(log_lines)
cmd = re.sub(r"\bLOGFILE\b.*?(?=\bDATAFILE\b)", new_logfile + "\n  ",
             cmd, flags=re.DOTALL | re.IGNORECASE)

with open(CTL_SQL, "w") as f:
    f.write(f"-- Auto-generated by exadata_sparse_standby_v1.sh  ${SCRIPT_VERSION}\n")
    f.write(f"-- Snapshot DB : {SNAP_NAME}\n")
    f.write(f"-- Test Master : {TM_NAME}\n\n")
    f.write(cmd + "\n")

print("crt_ctlfile.sql generated successfully")
PYEOF

    python3 "${PYFILE}"; local py_rc=$?
    rm -f "${PYFILE}"
    [[ ${py_rc} -ne 0 ]] && error "step6: failed to build controlfile script (exit ${py_rc})"
    [[ -f "${CTL_SQL}" ]] || error "crt_ctlfile.sql not created"

    # Content validation
    grep -q  "CREATE CONTROLFILE" "${CTL_SQL}" || error "step6: missing CREATE CONTROLFILE"
    grep -qi "RESETLOGS"          "${CTL_SQL}" || error "step6: missing RESETLOGS"
    grep -qi "DATAFILE"           "${CTL_SQL}" || error "step6: missing DATAFILE clause"
    log "crt_ctlfile.sql content validation: PASSED"

    head -30 "${CTL_SQL}" >> "${LOGFILE}"
    success "Step 6: crt_ctlfile.sql: ${CTL_SQL}"
}

# ---------------------------------------------------------------------------
# Step 7: Create Audit Directory on OS
# ---------------------------------------------------------------------------
step7_create_audit_dir() {
    step "7 -- Create Audit File Destination Directory"
    log "Creating: ${ADUMP_DIR}"
    mkdir -p "${ADUMP_DIR}"
    success "Step 7: Audit directory ready: ${ADUMP_DIR}"
}

# ---------------------------------------------------------------------------
# Step 8: Create ASM Directories for Snapshot Datafiles
# ---------------------------------------------------------------------------
step8_create_asm_dirs() {
    step "8 -- Create Oracle ASM Directories in ${SNAP_SPARSE_DG}"
    log "Grid user       : ${GRID_USER}"
    log "ASM SID         : ${ASM_SID}"
    log "ASM exec method : ${ASM_EXEC_METHOD}"

    substep "Creating ${SNAP_SPARSE_DG}/${SNAP_DB_NAME}/DATAFILE"
    asmcmd_mkdir "${SNAP_SPARSE_DG}/${SNAP_DB_NAME}/DATAFILE"
    success "Created: ${SNAP_SPARSE_DG}/${SNAP_DB_NAME}/DATAFILE"

    substep "Creating ${SNAP_DATA_DG}/${SNAP_DB_NAME}"
    asmcmd_mkdir "${SNAP_DATA_DG}/${SNAP_DB_NAME}"
    success "Created: ${SNAP_DATA_DG}/${SNAP_DB_NAME}"

    substep "Verifying ASM directories"
    run_asmcmd "ls ${SNAP_SPARSE_DG}/${SNAP_DB_NAME}"
    run_asmcmd "ls ${SNAP_DATA_DG}/${SNAP_DB_NAME}"
    success "ASM directory verification passed"

    if [[ "${IS_CDB}" == "true" ]]; then
        substep "CDB mode: querying PDB GUIDs from Test Master"

        # --- Idempotency: only start TM if it is not already OPEN ---
        local tm_pre_status
        tm_pre_status=$(get_db_status "${TM_ORACLE_SID}")
        log "Test Master status before PDB GUID query: ${tm_pre_status}"

        if [[ "${tm_pre_status}" != "OPEN" ]] && [[ "${DRY_RUN}" != "true" ]]; then
            safe_exec -l "step8-tm-open-readonly" -t 180 -- \
                "ORACLE_SID='${TM_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' / as sysdba <<'_EOF'
STARTUP MOUNT;
ALTER DATABASE OPEN READ ONLY;
EXIT
_EOF"
            [[ "${DRY_RUN}" == "true" ]] || verify_db_status "${TM_ORACLE_SID}" "OPEN" "step8-CDB"
        else
            log "step8: TM already ${tm_pre_status} -- skipping STARTUP MOUNT for GUID query"
        fi

        local pdb_guids
	pdb_guids=$(ORACLE_SID="${TM_ORACLE_SID}" "${ORACLE_HOME}/bin/sqlplus" -S / as sysdba 2>/dev/null <<'_EOF' | tr -d ' \r' | grep -Ei '^[0-9A-F]{32}$'
SET ECHO OFF
SET FEEDBACK OFF
SET HEADING OFF
SET PAGESIZE 0
SET TRIMSPOOL ON
SELECT rawtohex(guid) FROM v$pdbs WHERE con_id > 1;
EXIT
_EOF
)
	log "step8: PDB GUIDs found: ${pdb_guids}"
        # Only shut down TM if we started it in this step
        if [[ "${tm_pre_status}" != "OPEN" ]] && [[ "${DRY_RUN}" != "true" ]]; then
            safe_exec -l "step8-tm-shutdown" -t 300 -- \
                "ORACLE_SID='${TM_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' -S / as sysdba <<'_EOF'
SHUTDOWN IMMEDIATE;
EXIT
_EOF"
        else
            log "step8: TM was already OPEN before this step -- leaving it running"
        fi

        for GUID in ${pdb_guids}; do
            log "Creating ASM dir for PDB GUID: ${GUID}"
            asmcmd_mkdir "${SNAP_SPARSE_DG}/${SNAP_DB_NAME}/${GUID}/DATAFILE"
            success "  Created: ${SNAP_SPARSE_DG}/${SNAP_DB_NAME}/${GUID}/DATAFILE"
        done
    fi

    success "Step 8: ASM directories ready"
}

# ---------------------------------------------------------------------------
# Step 9: Startup Snapshot Instance in NOMOUNT
# ---------------------------------------------------------------------------
step9_startup_nomount() {
    step "9 -- Start Snapshot Instance in NOMOUNT: ${SNAP_ORACLE_SID}"
    SNAP_INIT="${WORK_DIR}/snap_init.ora"
    [[ -f "${SNAP_INIT}" ]] || error "snap_init.ora not found: ${SNAP_INIT}"

    substep "Checking if instance is already started"
    local existing_status
    existing_status=$(get_db_status "${SNAP_ORACLE_SID}")
    log "Current status: ${existing_status}"

    if [[ "${existing_status}" == "STARTED" ]]; then
        log "step9: ${SNAP_ORACLE_SID} already in NOMOUNT (STATUS=STARTED) -- skipping STARTUP"
        success "Step 9: Snapshot instance already in NOMOUNT -- skipped"
        return 0
    elif [[ "${existing_status}" == "MOUNTED" || "${existing_status}" == "OPEN" ]]; then
        error "step9: ${SNAP_ORACLE_SID} is already ${existing_status}. Shutdown before re-running from step 9."
    fi

    substep "Executing STARTUP NOMOUNT"
    safe_exec -l "step9-startup-nomount" -t 120 -- \
        "ORACLE_SID='${SNAP_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' / as sysdba <<'_EOF'
STARTUP NOMOUNT PFILE='${SNAP_INIT}';
EXIT
_EOF"
    [[ "${DRY_RUN}" == "true" ]] || verify_db_status "${SNAP_ORACLE_SID}" "STARTED" "step9"
    success "Step 9: Snapshot instance in NOMOUNT (STATUS=STARTED)"
}

# ---------------------------------------------------------------------------
# Step 10: Create Snapshot Control File
# ---------------------------------------------------------------------------
step10_create_controlfile() {
    step "10 -- Create Snapshot Control File: ${SNAP_ORACLE_SID}"
    CTL_SQL="${WORK_DIR}/crt_ctlfile.sql"
    [[ -f "${CTL_SQL}" ]] || error "Control file script not found: ${CTL_SQL}"

    substep "Checking current snapshot instance status"
    local existing_status
    existing_status=$(get_db_status "${SNAP_ORACLE_SID}")
    log "Current status: ${existing_status}"

    if [[ "${existing_status}" == "MOUNTED" ]]; then
        log "step10: ${SNAP_ORACLE_SID} already MOUNTED -- controlfile already created, skipping"
        success "Step 10: Controlfile already exists (STATUS=MOUNTED) -- skipped"
        return 0
    elif [[ "${existing_status}" == "OPEN" ]]; then
        error "step10: ${SNAP_ORACLE_SID} already OPEN. Re-running would corrupt it."
    fi

    substep "Running crt_ctlfile.sql on ${SNAP_ORACLE_SID}"
    safe_exec -l "step10-create-controlfile" -t 300 -- \
        "ORACLE_SID='${SNAP_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' / as sysdba @'${CTL_SQL}'"
    [[ "${DRY_RUN}" == "true" ]] || verify_db_status "${SNAP_ORACLE_SID}" "MOUNTED" "step10"
    success "Step 10: Snapshot control file created (STATUS=MOUNTED)"
}

# ---------------------------------------------------------------------------
# Step 11: Run rename_files.sql (CLONEDB_RENAMEFILE)
# ---------------------------------------------------------------------------
step11_rename_files() {
    step "11 -- Run DBMS_DNFS.CLONEDB_RENAMEFILE for All Datafiles"
    local rename_sql="${WORK_DIR}/rename_files.sql"
    [[ -f "${rename_sql}" ]] || error "rename_files.sql not found. Did step 2 run?"
    log "Instance : ${SNAP_ORACLE_SID}  Index : T${SNAP_INDEX}"

    # --- Idempotency: skip if sparse files for this index already registered ---
    substep "Checking V\$CLONEDFILE for existing T${SNAP_INDEX} entries"
    local existing_count
    existing_count=$(sqlplus_check "${SNAP_ORACLE_SID}" \
        "SELECT COUNT(*) FROM V\$CLONEDFILE WHERE clonefilename LIKE '%_T${SNAP_INDEX}%';" \
        "step11-idempotency-check" | grep -v '^$' | tail -1 | tr -d ' ') || existing_count=0
    if [[ "${DRY_RUN}" != "true" ]] && [[ "${existing_count:-0}" -gt 0 ]]; then
        log "step11: V\$CLONEDFILE already has ${existing_count} entries for index T${SNAP_INDEX} -- skipping CLONEDB_RENAMEFILE"
        success "Step 11: CLONEDB_RENAMEFILE already done for T${SNAP_INDEX} (idempotent skip)"
        return 0
    fi

    substep "Executing CLONEDB_RENAMEFILE"

    # Save current STANDBY_FILE_MANAGEMENT value, set to MANUAL, then restore.
    # CLONEDB_RENAMEFILE requires MANUAL; AUTO would conflict with the rename.
    local sfm_prev
    sfm_prev=$(sqlplus_check "${SNAP_ORACLE_SID}" \
        "SELECT VALUE FROM V\$PARAMETER WHERE NAME='standby_file_management';" \
        "step11-sfm-get" | grep -v '^$' | tail -1 | tr -d ' ') || sfm_prev="AUTO"
    sfm_prev="${sfm_prev:-AUTO}"
    log "Step 11: standby_file_management current value: ${sfm_prev} -- setting to MANUAL for CLONEDB_RENAMEFILE"
    sqlplus_check "${SNAP_ORACLE_SID}" \
        "ALTER SYSTEM SET standby_file_management='MANUAL';" \
        "step11-sfm-set-manual" > /dev/null

    local _sfm_rc=0
    safe_exec -l "step11-clonedb-renamefile" -t 1800 -- \
        "ORACLE_SID='${SNAP_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' / as sysdba @'${rename_sql}'" \
        || _sfm_rc=$?

    # Restore standby_file_management regardless of success/failure
    log "Step 11: Restoring standby_file_management to '${sfm_prev}'"
    sqlplus_check "${SNAP_ORACLE_SID}" \
        "ALTER SYSTEM SET standby_file_management='${sfm_prev}';" \
        "step11-sfm-restore" > /dev/null || warn "Step 11: Failed to restore standby_file_management to '${sfm_prev}' -- check manually"

    [[ "${_sfm_rc}" -eq 0 ]] || error "Step 11: CLONEDB_RENAMEFILE failed (rc=${_sfm_rc})"

    success "Step 11: CLONEDB_RENAMEFILE complete (T${SNAP_INDEX})"
}

# ---------------------------------------------------------------------------
# Step 12: Open Snapshot Database with RESETLOGS
# ---------------------------------------------------------------------------
step12_open_resetlogs() {
    step "12 -- Open Snapshot Database with RESETLOGS: ${SNAP_ORACLE_SID}"

    substep "Checking current snapshot status"
    local existing_status
    existing_status=$(get_db_status "${SNAP_ORACLE_SID}")
    log "Current status: ${existing_status}"

    if [[ "${existing_status}" == "OPEN" ]]; then
        log "step12: ${SNAP_ORACLE_SID} already OPEN -- RESETLOGS already completed"
        success "Step 12: Snapshot already OPEN -- skipped"
        return 0
    fi

    substep "Executing ALTER DATABASE OPEN RESETLOGS"
    safe_exec -l "step12-open-resetlogs" -t 300 -- \
        "ORACLE_SID='${SNAP_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' / as sysdba <<'_EOF'
ALTER DATABASE OPEN RESETLOGS;
EXIT
_EOF"
    [[ "${DRY_RUN}" == "true" ]] || verify_db_status "${SNAP_ORACLE_SID}" "OPEN" "step12"
    success "Step 12: Snapshot database OPEN (RESETLOGS complete)"
}

# ---------------------------------------------------------------------------
# Step 13: Verify Clone File Relationships (V$CLONEDFILE)
# ---------------------------------------------------------------------------
step13_verify_cloned_files() {
    step "13 -- Verify Snapshot Parent-Child File Relationships (V\$CLONEDFILE)"
    log "Querying V\$CLONEDFILE on ${SNAP_ORACLE_SID}"

    local clone_count
    clone_count=$(verify_clonedfile "${SNAP_ORACLE_SID}" "${SNAP_SPARSE_DG}" "step13")

    success "Step 13: ${clone_count} cloned file(s) verified in V\$CLONEDFILE"
}

# ---------------------------------------------------------------------------
# Step 14: Add Tempfile to TEMP Tablespace
# ---------------------------------------------------------------------------
step14_add_tempfile() {
    step "14 -- Add Tempfile to TEMP Tablespace: ${SNAP_ORACLE_SID}"
    log "Adding ${TEMP_SIZE} tempfile in ${SNAP_DATA_DG}"

    # --- Idempotency: only add CDB-level tempfile if TEMP has none yet ---
    substep "Checking for existing CDB TEMP tempfiles"
    local cdb_tempfile_count
    cdb_tempfile_count=$(sqlplus_check "${SNAP_ORACLE_SID}" \
        "SELECT COUNT(*) FROM v\$tempfile tf JOIN dba_tablespaces ts
         ON tf.ts# = ts.ts# WHERE ts.contents='TEMPORARY' AND ts.con_id = 0;" \
        "step14-cdb-tempfile-check" | grep -v '^$' | tail -1 | tr -d ' ') || cdb_tempfile_count=0

    if [[ "${DRY_RUN}" != "true" ]] && [[ "${cdb_tempfile_count:-0}" -gt 0 ]]; then
        log "step14: CDB TEMP tablespace already has ${cdb_tempfile_count} tempfile(s) -- skipping ADD TEMPFILE"
    else
        substep "Adding tempfile to CDB TEMP tablespace"
        safe_exec -l "step14-add-tempfile" -t 120 -- \
            "ORACLE_SID='${SNAP_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' / as sysdba <<'_EOF'
ALTER TABLESPACE temp ADD TEMPFILE '${SNAP_DATA_DG}' SIZE ${TEMP_SIZE};
EXIT
_EOF"
        success "Tempfile added to CDB TEMP tablespace"
    fi

    if [[ "${IS_CDB}" == "true" ]]; then
        substep "CDB mode: adding tempfiles to each PDB"
        local pdb_names
        pdb_names=$(sqlplus_check "${SNAP_ORACLE_SID}" \
            "SELECT name FROM v\$pdbs WHERE con_id > 1;" "step14-pdb-list" | \
            tr -d ' ' | grep -v '^$')
        for PDB in ${pdb_names}; do
            # --- Idempotency: check each PDB's TEMP before adding ---
            local pdb_tempfile_count
            pdb_tempfile_count=$(sqlplus_check "${SNAP_ORACLE_SID}" \
                "SELECT COUNT(*) FROM cdb_temp_files WHERE con_id =
                 (SELECT con_id FROM v\$pdbs WHERE name = UPPER('${PDB}'));" \
                "step14-pdb-${PDB}-check" | grep -v '^$' | tail -1 | tr -d ' ') || pdb_tempfile_count=0

            if [[ "${DRY_RUN}" != "true" ]] && [[ "${pdb_tempfile_count:-0}" -gt 0 ]]; then
                log "  PDB ${PDB}: already has ${pdb_tempfile_count} tempfile(s) -- skipping"
                continue
            fi

            log "  Adding tempfile to PDB: ${PDB}"
            safe_exec -l "step14-pdb-${PDB}" -t 120 -- \
                "ORACLE_SID='${SNAP_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' / as sysdba <<'_EOF'
ALTER SESSION SET CONTAINER=${PDB};
ALTER TABLESPACE temp ADD TEMPFILE '${SNAP_DATA_DG}' SIZE ${TEMP_SIZE};
EXIT
_EOF"
            success "  Tempfile added to PDB: ${PDB}"
        done
    fi

    success "Step 14: Tempfile(s) added"
}


# =============================================================================
# SHARED ORCHESTRATION HELPERS
# run_part_a / run_part_b centralise the full step sequences so that
# sparse-standby mode, clone mode, refresh mode, and full mode all call
# a single source of truth instead of maintaining three identical copies.
# =============================================================================

run_preflight() {
    check_prerequisites
    check_runtime_conflicts
}

run_part_a() {
    ss_s1_stop_redo_apply
    ss_s2_generate_rename_sql
    ss_s3_generate_set_readonly_sql
    ss_s4_create_sparse_asm_dirs
    ss_s5_shutdown_standby
    ss_s6_set_datafiles_readonly
    ss_s7_startup_first_instance_mount
    ss_s8_run_renamefile
    ss_s9_open_standby_readonly
    ss_s10_start_remaining_instances
    ss_s11_restart_redo_apply
    ss_s12_verify_apply_lag
    ss_s13_verify_sparse_files
    ss_s14_chain_depth_post_check
}

run_part_b() {
    step1_backup_controlfile_trace
    step2_generate_rename_script
    step3_create_tm_initora
    if [[ "${SKIP_SHUTDOWN}" == "true" ]]; then
        log "Skipping TM shutdown (--skip-shutdown)"
    else
        step4_shutdown_testmaster
    fi
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
}


# =============================================================================
# SECTION 13 -- PART C: REFRESH / NEW SNAPSHOT CYCLE
# Drops existing snapshot children, takes a new sparse standby snapshot
# (advances the _Tx chain index), then creates fresh clones.
# =============================================================================

# ---------------------------------------------------------------------------
# R1: Drop All Snapshot Databases (children of the current Test Master)
# ---------------------------------------------------------------------------
refresh_r1_drop_snapshots() {
    step "R1 -- Drop All Snapshot Databases (Children of Test Master)"
    warn "This will DROP all snapshot databases listed in SNAP_SID_LIST."
    warn "Snapshots: ${SNAP_SID_LIST}"

    if [[ "${FORCE:-false}" != "true" ]]; then
        read -r -p "  Type YES to confirm drop of all snapshots: " CONFIRM
        [[ "${CONFIRM}" == "YES" ]] || { log "Aborted by user."; exit 0; }
    fi

    for SNAP_SID in ${SNAP_SID_LIST}; do
        substep "Dropping snapshot database: ${SNAP_SID}"
        log "Step 1: SHUTDOWN ABORT on ${SNAP_SID}"
        safe_exec -l "R1-shutdown-abort-${SNAP_SID}" -t 60 -- \
            "ORACLE_SID='${SNAP_SID}' '${ORACLE_HOME}/bin/sqlplus' -S / as sysdba <<'_EOF'
SHUTDOWN ABORT;
EXIT
_EOF" || true

        log "Step 2: RMAN DROP DATABASE NOPROMPT on ${SNAP_SID}"
        safe_exec -l "R1-rman-drop-${SNAP_SID}" -t 600 -- \
            "ORACLE_SID='${SNAP_SID}' '${ORACLE_HOME}/bin/rman' target / <<'_EOF'
STARTUP MOUNT FORCE;
DROP DATABASE INCLUDING BACKUPS NOPROMPT;
_EOF"
        log_chain_event "R1_DROP_SNAPSHOT sid=${SNAP_SID}"
        success "Snapshot ${SNAP_SID} dropped"
    done
    success "R1: All snapshot databases dropped"
}

# ---------------------------------------------------------------------------
# R2: Reset Test Master Datafile Permissions to Read-Write
# After dropping all snapshots, the parent standby datafiles need their
# ACL permissions restored to READ-WRITE before a new snapshot is taken.
# ---------------------------------------------------------------------------
refresh_r2_reset_tm_permissions() {
    step "R2 -- Reset Test Master Datafile Permissions (READ ONLY -> READ WRITE)"
    log "Generating change_perm.sql to restore read-write on ${TM_DATA_DG} files"

    local PERM_SQL="${WORK_DIR}/change_perm.sql"
    local tm_dg_bare="${TM_DATA_DG##\+}"

    # --- Idempotency: start TM in MOUNT only if not already MOUNTED or OPEN ---
    substep "Checking Test Master status before startup"
    local tm_status
    tm_status=$(get_db_status "${TM_ORACLE_SID}")
    log "Test Master current status: ${tm_status}"

    local tm_started_here=false
    if [[ "${tm_status}" == "DOWN" ]] || [[ "${tm_status}" == "STARTED" ]]; then
        substep "Starting TM in MOUNT to query V\$DATAFILE"
        safe_exec -l "R2-startup-mount" -t 120 -- \
            "ORACLE_SID='${TM_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' / as sysdba <<'_EOF'
STARTUP MOUNT;
EXIT
_EOF"
        [[ "${DRY_RUN}" == "true" ]] || verify_db_status "${TM_ORACLE_SID}" "MOUNTED" "R2"
        tm_started_here=true
    elif [[ "${tm_status}" == "MOUNTED" || "${tm_status}" == "OPEN" ]]; then
        log "R2: TM already ${tm_status} -- skipping STARTUP MOUNT"
    else
        error "R2: Unexpected Test Master status '${tm_status}'"
    fi

    substep "Generating permission reset SQL via spool"
    spool_sql_from_query "${TM_ORACLE_SID}" "${PERM_SQL}" \
"SELECT 'ALTER DISKGROUP ${tm_dg_bare} SET PERMISSION OWNER=READ WRITE, GROUP=READ WRITE, OTHER=NONE FOR FILE ''' || name || ''';'
FROM v\$datafile;" "R2-gen-perm-sql" > /dev/null

    local perm_count
    perm_count=$(grep -c "ALTER DISKGROUP" "${PERM_SQL}" 2>/dev/null || echo 0)
    [[ "${perm_count}" -gt 0 ]] || error "R2: change_perm.sql is empty"
    log "Generated ${perm_count} permission reset statements"

    substep "Executing permission reset as SYSASM"
    run_sqlplus_asm "@${PERM_SQL}" "R2-exec-perm"

    # Shut down TM only if this step started it
    if [[ "${tm_started_here}" == "true" ]] && [[ "${DRY_RUN}" != "true" ]]; then
        substep "Shutting down TM (started by this step)"
        safe_exec -l "R2-shutdown-tm" -t 300 -- \
            "ORACLE_SID='${TM_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' -S / as sysdba <<'_EOF'
SHUTDOWN IMMEDIATE;
EXIT
_EOF"
    fi

    log_chain_event "R2_PERMISSIONS_RESET statements=${perm_count}"
    success "R2: ${perm_count} TM datafile(s) restored to READ WRITE"
}

# ---------------------------------------------------------------------------
# R3: Take New Sparse Standby Snapshot (re-runs Part A S1-S14)
# Advances SNAP_INDEX by 1 so the new sparse layer gets the next _Tx suffix.
# ---------------------------------------------------------------------------
refresh_r3_new_sparse_standby_cycle() {
    step "R3 -- Take New Sparse Standby Snapshot (Advancing Chain to T${SNAP_INDEX})"
    log "Re-running the full Part A sparse standby snapshot cycle."
    log "New sparse files will use suffix _T${SNAP_INDEX} in ${SNAP_SPARSE_DG}"

    check_chain_depth
    run_part_a

    log_chain_event "R3_NEW_SNAPSHOT_CYCLE index=T${SNAP_INDEX} stby=${STBY_DB_UNIQUE_NAME}"
    success "R3: New sparse standby snapshot complete (T${SNAP_INDEX})"
}

# ---------------------------------------------------------------------------
# R4: Re-create Sparse Clone (re-runs Part B steps 1-14)
# ---------------------------------------------------------------------------
refresh_r4_recreate_snapclone() {
    step "R4 -- Re-create Sparse Clone (Running Part B Creation Cycle)"
    log "Snapshot DB    : ${SNAP_DB_NAME} (${SNAP_ORACLE_SID})"
    log "Snapshot Index : T${SNAP_INDEX}"

    # Ensure TM (standby) is OPEN before running the clone creation cycle
    local tm_status
    tm_status=$(get_db_status "${TM_ORACLE_SID}")
    log "TM status before clone cycle: ${tm_status}"
    if [[ "${tm_status}" != "OPEN" ]]; then
        substep "Starting Test Master (current status: ${tm_status})"
        safe_exec -l "R4-startup-open" -t 180 -- \
            "ORACLE_SID='${TM_ORACLE_SID}' '${ORACLE_HOME}/bin/sqlplus' / as sysdba <<'_EOF'
STARTUP;
EXIT
_EOF"
        [[ "${DRY_RUN}" == "true" ]] || verify_db_status "${TM_ORACLE_SID}" "OPEN" "R4"
    fi

    run_preflight
    run_part_b

    log_chain_event "R4_CLONE_CREATED index=T${SNAP_INDEX} snap=${SNAP_DB_NAME}"
    success "R4: Sparse clone T${SNAP_INDEX} created from refreshed Test Master"
}

# =============================================================================
# SECTION 14 -- SNAP INDEX COUNTER MANAGEMENT
# Tracks which _Tx suffix is next for this Test Master generation.
# Persists in ${WORK_DIR}/.snap_index_counter; protected by flock (fd 200).
# =============================================================================

_SNAP_INDEX_COUNTER_FILE=""
_SNAP_INDEX_LOCK_FILE=""

resolve_snap_index() {
    _SNAP_INDEX_COUNTER_FILE="${WORK_DIR}/.snap_index_counter"
    _SNAP_INDEX_LOCK_FILE="${WORK_DIR}/.snap_index_counter.lock"

    if [[ -n "${_SNAP_INDEX_EXPLICIT:-}" ]]; then
        log "Snapshot index: T${SNAP_INDEX}  (explicit override -- counter file not used)"
        return 0
    fi

    exec 200>"${_SNAP_INDEX_LOCK_FILE}"
    if ! flock -w 60 200; then
        error "Could not acquire counter lock within 60s. Another run may be in progress."
    fi
    log "Acquired exclusive lock on snap index counter"

    if [[ -f "${_SNAP_INDEX_COUNTER_FILE}" ]]; then
        local _ctr
        _ctr=$(tr -d '[:space:]' < "${_SNAP_INDEX_COUNTER_FILE}" 2>/dev/null)
        if [[ "${_ctr}" =~ ^[0-9]+$ ]]; then
            SNAP_INDEX="${_ctr}"
        else
            warn "Counter file corrupt ('${_ctr}') -- defaulting to T0"
            SNAP_INDEX=0
        fi
    else
        SNAP_INDEX=0
    fi
    log "Snapshot index: T${SNAP_INDEX}  (from counter file; next will be T$(( SNAP_INDEX + 1 )))"
}

advance_snap_index() {
    [[ -n "${_SNAP_INDEX_EXPLICIT:-}" ]] && return 0
    local next_idx=$(( SNAP_INDEX + 1 ))
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] Would write counter: ${_SNAP_INDEX_COUNTER_FILE} -> ${next_idx}"
    else
        local _tmp="${_SNAP_INDEX_COUNTER_FILE}.tmp.$$"
        echo "${next_idx}" > "${_tmp}"
        mv -f "${_tmp}" "${_SNAP_INDEX_COUNTER_FILE}"
        log "Counter file updated: ${_SNAP_INDEX_COUNTER_FILE} -> ${next_idx}"
    fi
    flock -u 200 2>/dev/null || true
}

reset_snap_index() {
    local reset_to="${1:-0}"
    if [[ -n "${_SNAP_INDEX_EXPLICIT:-}" ]]; then
        log "Explicit index set -- not resetting counter"
        return 0
    fi
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[DRY-RUN] Would reset counter to ${reset_to}"
    else
        local _tmp="${_SNAP_INDEX_COUNTER_FILE:-${WORK_DIR}/.snap_index_counter}.tmp.$$"
        echo "${reset_to}" > "${_tmp}"
        mv -f "${_tmp}" "${_SNAP_INDEX_COUNTER_FILE:-${WORK_DIR}/.snap_index_counter}"
        log "Counter reset to ${reset_to}"
    fi
    log_chain_event "INDEX_RESET to=${reset_to}"
}

# =============================================================================
# SECTION 15 -- SUMMARY PRINTERS
# =============================================================================

print_sparse_standby_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}+============================================================+${NC}"
    echo -e "${GREEN}${BOLD}|   Exadata Sparse Standby Snapshot COMPLETE                 |${NC}"
    echo -e "${GREEN}${BOLD}|   ${SCRIPT_VERSION}                                                  |${NC}"
    echo -e "${GREEN}${BOLD}+============================================================+${NC}"
    echo ""
    echo -e "  Standby DB        : ${BOLD}${STBY_DB_UNIQUE_NAME}${NC}  (SID: ${STBY_ORACLE_SID})"
    echo -e "  Primary DB        : ${BOLD}${PRIMARY_DB_UNIQUE_NAME}${NC}"
    if [[ "${CASCADED_STANDBY}" == "true" ]]; then
        echo -e "  Cascade Source    : ${BOLD}${CASCADE_SOURCE_DB_UNIQUE_NAME}${NC}"
    fi
    echo -e "  RAC Mode          : ${BOLD}YES (srvctl)${NC}  Instances: ${STBY_INSTANCES}"
    echo -e "  Sparse DG         : ${BOLD}${SNAP_SPARSE_DG}${NC}"
    echo -e "  Data DG           : ${BOLD}${SNAP_DATA_DG}${NC}"
    echo -e "  Snapshot Index    : ${BOLD}T${SNAP_INDEX}${NC}  (sparse files end in _T${SNAP_INDEX})"
    echo -e "  Redo Apply        : ${BOLD}APPLY-ON${NC}  (restarted)"
    echo -e "  Chain Log         : ${BOLD}${CHAIN_LOG}${NC}"
    echo -e "  Log File          : ${BOLD}${LOGFILE}${NC}"
    echo -e "  Audit Log         : ${BOLD}$(_safe_exec_audit_log)${NC}"
    echo ""
    echo -e "  Generated Files:"
    echo -e "    ${WORK_DIR}/rename_files.sql"
    echo -e "    ${WORK_DIR}/set_datafiles_read_only.sql"
    echo ""
    echo -e "  ${YELLOW}NEXT STEPS:${NC}"
    echo -e "    To create a sparse clone from this Test Master:"
    echo -e "      $0 --clone [--config <file>]"
    echo -e "    To take the next periodic snapshot (advance chain):"
    echo -e "      $0 --refresh [--config <file>]"
    echo ""
}

print_clone_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}+============================================================+${NC}"
    echo -e "${GREEN}${BOLD}|   Exadata Sparse Clone Creation COMPLETE                   |${NC}"
    echo -e "${GREEN}${BOLD}|   ${SCRIPT_VERSION}                                                  |${NC}"
    echo -e "${GREEN}${BOLD}+============================================================+${NC}"
    echo ""
    echo -e "  Test Master DB    : ${BOLD}${TM_DB_NAME}${NC}  (SID: ${TM_ORACLE_SID})"
    echo -e "  Snapshot DB       : ${BOLD}${SNAP_DB_NAME}${NC}  (SID: ${SNAP_ORACLE_SID})"
    echo -e "  Sparse DG         : ${BOLD}${SNAP_SPARSE_DG}${NC}"
    echo -e "  Data DG           : ${BOLD}${SNAP_DATA_DG}${NC}"
    echo -e "  Snapshot Index    : ${BOLD}T${SNAP_INDEX}${NC}"
    echo -e "  Working Dir       : ${BOLD}${WORK_DIR}${NC}"
    echo -e "  Log File          : ${BOLD}${LOGFILE}${NC}"
    echo -e "  Audit Log         : ${BOLD}$(_safe_exec_audit_log)${NC}"
    echo ""
    echo -e "  ${YELLOW}NOTE:${NC} Test Master DB is currently SHUTDOWN."
    echo -e "  Restart: ORACLE_SID=${TM_ORACLE_SID} sqlplus / as sysdba; SQL> STARTUP"
    echo ""
}

print_refresh_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}+============================================================+${NC}"
    echo -e "${GREEN}${BOLD}|   Test Master REFRESH + New Sparse Snapshot COMPLETE       |${NC}"
    echo -e "${GREEN}${BOLD}|   ${SCRIPT_VERSION}                                                  |${NC}"
    echo -e "${GREEN}${BOLD}+============================================================+${NC}"
    echo ""
    echo -e "  Standby DB        : ${BOLD}${STBY_DB_UNIQUE_NAME}${NC}"
    echo -e "  New Snapshot DB   : ${BOLD}${SNAP_DB_NAME}${NC}  (SID: ${SNAP_ORACLE_SID})"
    echo -e "  Snapshot Index    : ${BOLD}T${SNAP_INDEX}${NC}  (advanced from previous cycle)"
    echo -e "  Chain Log         : ${BOLD}${CHAIN_LOG}${NC}"
    echo -e "  Log File          : ${BOLD}${LOGFILE}${NC}"
    echo ""
    echo -e "  ${YELLOW}REMINDER:${NC} If data masking is required, apply it to the Test"
    echo -e "  Master NOW before creating new snapshot clones for distribution."
    echo ""
}

# =============================================================================
# SECTION 16 -- USAGE
# =============================================================================

usage() {
    echo ""
    echo -e "${BOLD}Usage:${NC} $0 [OPTIONS]"
    echo ""
    echo -e "${BOLD}MODES:${NC}"
    echo "  (default)              Full lifecycle: sparse standby snapshot + clone creation"
    echo "  --sparse-standby       Part A only: take sparse standby snapshot (S1-S14)"
    echo "  --clone                Part B only: create sparse clone from Test Master (Steps 1-14)"
    echo "  --refresh              Part C: drop snapshots, new sparse snapshot, new clone"
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo "  --config <file>        Source a config file to override default variables"
    echo "  --dry-run              Print all commands without executing"
    echo "  --force-shutdown       Authorise Test Master shutdown (required for step 4)"
    echo "  --skip-shutdown        Skip Test Master shutdown step (already down)"
    echo "  --cdb                  Enable CDB mode (PDB temp files, ASM subdirs by GUID)"
    echo "  --force                Skip interactive confirmation prompts"
    echo "  --snap-index <N>       Override the snapshot chain index for this run"
    echo "  --step <ID>            Run a single step only"
    echo "  --help                 Show this help message"
    echo ""
    echo -e "${BOLD}Sparse Standby steps (--sparse-standby --step SN):${NC}"
    echo "  S1   Stop redo apply (DGMGRL APPLY-OFF)"
    echo "  S2   Generate rename_files.sql"
    echo "  S3   Generate set_datafiles_read_only.sql"
    echo "  S4   Create SPARSE ASM directories for standby DB"
    echo "  S5   Shutdown standby database (srvctl)"
    echo "  S6   Set datafile ACLs to READ ONLY (SYSASM)"
    echo "  S7   Start first standby instance in MOUNT"
    echo "  S8   Execute CLONEDB_RENAMEFILE (rename_files.sql)"
    echo "  S9   Open standby database READ ONLY"
    echo "  S10  Start remaining RAC instances"
    echo "  S11  Restart redo apply (DGMGRL APPLY-ON)"
    echo "  S12  Verify apply lag"
    echo "  S13  Verify V\$CLONEDFILE relationships"
    echo "  S14  Post-snapshot chain depth check"
    echo ""
    echo -e "${BOLD}Clone creation steps (--clone --step N):${NC}"
    echo "  1    Backup control file to trace"
    echo "  2    Generate rename_files.sql (TM mapping)"
    echo "  3    Export TM SPFILE to init.ora"
    echo "  4    Shutdown Test Master  [requires --force-shutdown]"
    echo "  5    Create snap_init.ora"
    echo "  6    Build CREATE CONTROLFILE script"
    echo "  7    Create OS audit directory"
    echo "  8    Create ASM directories"
    echo "  9    Startup snapshot NOMOUNT"
    echo "  10   Create snapshot control file"
    echo "  11   Run rename_files.sql (CLONEDB_RENAMEFILE)"
    echo "  12   Open snapshot RESETLOGS"
    echo "  13   Verify V\$CLONEDFILE"
    echo "  14   Add tempfile to TEMP"
    echo ""
    echo -e "${BOLD}Refresh steps (--refresh --step RN):${NC}"
    echo "  R1   Drop all snapshot child databases"
    echo "  R2   Reset TM datafile permissions to READ WRITE"
    echo "  R3   Take new sparse standby snapshot (Part A)"
    echo "  R4   Re-create sparse clone (Part B)"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                                    # Full lifecycle (snapshot + clone)"
    echo "  $0 --sparse-standby                   # Snapshot only (S1-S14)"
    echo "  $0 --clone --force-shutdown           # Clone only (Steps 1-14)"
    echo "  $0 --refresh --force --force-shutdown # Full refresh cycle"
    echo "  $0 --sparse-standby --step S1         # Single step"
    echo "  $0 --clone --step 13                  # Verify only"
    echo "  $0 --refresh --step R1                # Drop snapshots only"
    echo "  $0 --config prod.conf --dry-run       # Dry-run with config"
    echo ""
}

# =============================================================================
# SECTION 17 -- ARGUMENT PARSING & MAIN ENTRY POINT
# =============================================================================

SKIP_SHUTDOWN=false
RUN_STEP=""
MODE="full"     # full | sparse-standby | clone | refresh
FORCE=false
_SNAP_INDEX_EXPLICIT=""
_SCRIPT_EXIT_CODE=0   # set to 1 by error(); read by EXIT trap
_CURRENT_STEP=""      # updated by step() -- last step banner entered
_FAILED_STEP=""       # set by error() before exit -- surfaced in footer

# On any exit: release locks, run rollbacks if failed, print diagnostic footer.
_exit_handler() {
    local code="${_SCRIPT_EXIT_CODE:-0}"
    flock -u 200 2>/dev/null || true
    release_execution_lock
    if [[ "${code}" -ne 0 ]]; then
        run_rollbacks
        { echo -e "\n${RED}${BOLD}======================================================${NC}";
          echo -e "${RED}${BOLD}  SCRIPT FAILED${NC}";
          echo -e "${RED}${BOLD}======================================================${NC}";
          echo -e "${RED}  Mode        : ${MODE}${NC}";
          [[ -n "${_FAILED_STEP}" ]] && \
          echo -e "${RED}  Failed step : ${_FAILED_STEP}${NC}";
          echo -e "${RED}  Log file    : ${LOGFILE}${NC}";
          echo -e "${RED}  Audit log   : $(_safe_exec_audit_log 2>/dev/null || true)${NC}";
          echo -e "${RED}  Re-run step : $0 --${MODE} --step ${_FAILED_STEP:-<step_id>} [--config <file>]${NC}";
          echo -e "${RED}${BOLD}======================================================${NC}\n"; } >&2
    fi
}
trap '_exit_handler' EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)         shift 2 ;;  # already sourced in early parse above; consume args only
        --dry-run)        DRY_RUN=true; shift ;;
        --force-shutdown) FORCE_SHUTDOWN=true; shift ;;
        --skip-shutdown)  SKIP_SHUTDOWN=true; shift ;;
        --cdb)            IS_CDB="true"; shift ;;
        --force)          FORCE=true; shift ;;
        --sparse-standby) MODE="sparse-standby"; shift ;;
        --clone)          MODE="clone"; shift ;;
        --refresh)        MODE="refresh"; shift ;;
        --snap-index)
            [[ "$2" =~ ^[0-9]+$ ]] || { echo "ERROR: --snap-index requires a non-negative integer" >&2; exit 1; }
            SNAP_INDEX="$2"; _SNAP_INDEX_EXPLICIT="yes"; shift 2 ;;
        --step)           RUN_STEP="$2"; shift 2 ;;
        --help)           usage; exit 0 ;;
        *)                echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Bootstrap: work dir, export ORACLE_HOME, validate, lock, banner
# ---------------------------------------------------------------------------
mkdir -p "${WORK_DIR}"
_init_logdir
export ORACLE_HOME PATH="${ORACLE_HOME}/bin:${PATH}" ORACLE_BASE FORCE

validate_config_vars
_safe_exec_banner
acquire_execution_lock

# ---------------------------------------------------------------------------
# Print run header to log
# ---------------------------------------------------------------------------
section "Exadata Sparse Standby Automation  ${SCRIPT_VERSION}"
log "Mode          : ${MODE}"
log "Standby DB    : ${STBY_DB_UNIQUE_NAME}  (SID: ${STBY_ORACLE_SID})"
log "Primary DB    : ${PRIMARY_DB_UNIQUE_NAME}"
log "Snapshot DB   : ${SNAP_DB_NAME}  (SID: ${SNAP_ORACLE_SID})"
log "RAC mode      : YES (srvctl)"
log "Cascaded DG   : ${CASCADED_STANDBY}$([ "${CASCADED_STANDBY}" == "true" ] && echo " (source: ${CASCADE_SOURCE_DB_UNIQUE_NAME})" || true)"
log "DRY_RUN       : ${DRY_RUN}"
log "FORCE_SHUTDOWN: ${FORCE_SHUTDOWN}"
log "Log file      : ${LOGFILE}"
log "Audit log     : $(_safe_exec_audit_log)"
log "Chain log     : ${CHAIN_LOG}"
log "Work dir      : ${WORK_DIR}"

# ---------------------------------------------------------------------------
# MODE: sparse-standby -- Part A only (S1-S14)
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "sparse-standby" ]]; then
    section "PART A -- Sparse Standby Snapshot"

    # Resolve snap index before any steps
    resolve_snap_index
    log "Sparse datafiles will end in _T${SNAP_INDEX}"

    if [[ -n "${RUN_STEP}" ]]; then
        log "Running single step: ${RUN_STEP}"
        case "${RUN_STEP}" in
            S1)  run_preflight; ss_s1_stop_redo_apply ;;
            S2)  ss_s2_generate_rename_sql ;;
            S3)  ss_s3_generate_set_readonly_sql ;;
            S4)  ss_s4_create_sparse_asm_dirs ;;
            S5)  ss_s5_shutdown_standby ;;
            S6)  ss_s6_set_datafiles_readonly ;;
            S7)  ss_s7_startup_first_instance_mount ;;
            S8)  ss_s8_run_renamefile ;;
            S9)  ss_s9_open_standby_readonly ;;
            S10) ss_s10_start_remaining_instances ;;
            S11) ss_s11_restart_redo_apply ;;
            S12) ss_s12_verify_apply_lag ;;
            S13) ss_s13_verify_sparse_files ;;
            S14) ss_s14_chain_depth_post_check ;;
            *)   error "Unknown sparse-standby step: ${RUN_STEP}. Valid: S1-S14" ;;
        esac
        exit 0
    fi

    check_chain_depth
    run_preflight
    run_part_a

    advance_snap_index
    print_sparse_standby_summary
    exit 0
fi

# ---------------------------------------------------------------------------
# MODE: clone -- Part B only (Steps 1-14)
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "clone" ]]; then
    section "PART B -- Hierarchical Sparse Clone Creation"
    resolve_snap_index
    log "Sparse datafiles will end in _T${SNAP_INDEX}"

    if [[ -n "${RUN_STEP}" ]]; then
        log "Running single step: ${RUN_STEP}"
        case "${RUN_STEP}" in
            1)  run_preflight ;;
            2)  step1_backup_controlfile_trace ;;
            3)  step2_generate_rename_script ;;
            4)  step3_create_tm_initora ;;
            5)  step4_shutdown_testmaster ;;
            6)  step5_create_snap_initora ;;
            7)  step6_build_controlfile_script ;;
            8)  step7_create_audit_dir ;;
            9)  step8_create_asm_dirs ;;
            10) step9_startup_nomount ;;
            11) step10_create_controlfile ;;
            12) step11_rename_files ;;
            13) step12_open_resetlogs ;;
            14) step13_verify_cloned_files ;;
            15) step14_add_tempfile ;;
            *)  error "Unknown clone step: ${RUN_STEP}. Valid: 1-14" ;;
        esac
        exit 0
    fi

    run_preflight
    run_part_b

    advance_snap_index
    print_clone_summary
    exit 0
fi

# ---------------------------------------------------------------------------
# MODE: refresh -- Part C (R1-R4)
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "refresh" ]]; then
    section "PART C -- Refresh: New Sparse Snapshot Cycle"
    log "Snapshots to drop : ${SNAP_SID_LIST}"
    log "Refresh method    : ${REFRESH_METHOD}"

    # Advance the snap index for the new snapshot generation
    resolve_snap_index
    # For a refresh: use the CURRENT counter value as the NEW chain snapshot index
    log "New snapshot index: T${SNAP_INDEX}"

    if [[ -n "${RUN_STEP}" ]]; then
        log "Running single refresh step: ${RUN_STEP}"
        case "${RUN_STEP}" in
            R1) refresh_r1_drop_snapshots ;;
            R2) refresh_r2_reset_tm_permissions ;;
            R3) refresh_r3_new_sparse_standby_cycle ;;
            R4) refresh_r4_recreate_snapclone ;;
            *)  error "Unknown refresh step: ${RUN_STEP}. Valid: R1-R4" ;;
        esac
        exit 0
    fi

    refresh_r1_drop_snapshots
    refresh_r2_reset_tm_permissions
    refresh_r3_new_sparse_standby_cycle
    refresh_r4_recreate_snapclone

    advance_snap_index
    print_refresh_summary
    exit 0
fi

# ---------------------------------------------------------------------------
# MODE: full (default) -- Part A + Part B (sparse standby snapshot + clone)
# ---------------------------------------------------------------------------
section "FULL LIFECYCLE -- Sparse Standby Snapshot + Clone Creation"
resolve_snap_index
log "Sparse datafiles will end in _T${SNAP_INDEX}"

check_chain_depth
run_preflight

section "PART A -- Sparse Standby Snapshot (S1-S14)"
run_part_a

section "PART B -- Hierarchical Sparse Clone Creation (Steps 1-14)"
run_part_b

advance_snap_index

section "COMPLETE"
print_sparse_standby_summary
print_clone_summary

exit 0
