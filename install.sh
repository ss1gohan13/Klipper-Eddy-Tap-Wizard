#!/usr/bin/env bash
#
# Klipper Eddy Tap Wizard Installer - rough draft
#
# This draft extends the existing installer with:
#   - active Klipper config-tree discovery
#   - native Eddy / BTT-style Eddy / Eddy-NG detection
#   - legacy nested Eddy Tap Wizard layout detection/migration
#   - legacy BIGTREETECH Klipper-fork warning
#   - Full / Minimal eddy.cfg template generation for fresh installs
#   - preservation of an existing user-owned eddy.cfg
#   - required [bed_mesh] zero_reference_position validation/setup
#   - [include eddy.cfg] management for generated configurations
#   - compatibility with existing native Eddy configurations
#   - safe migration of the old installer-managed direct include block
#   - an advisory Eddy USB firmware/identity check
#
# Existing behavior retained:
#   - eddy_macros.cfg and eddy_setup_wizard.cfg are repo-managed symlinks
#   - temperature_probe.py is copied and hash-managed
#   - [save_variables] is detected/added
#   - backups are created before config changes
#   - --update pulls the currently checked-out branch
#   - Klipper is restarted at the end of a successful install
#
# IMPORTANT:
#   eddy.cfg is USER-OWNED once generated. Normal updates never regenerate or
#   replace it. The required zero_reference_position is only changed after
#   explicit user confirmation.
#
# Usage:
#   ./install.sh
#   ./install.sh --update
#   ./install.sh --yes
#   ./install.sh --update --yes
#   ./install.sh --detect-only
#
set -Eeuo pipefail

PROJECT_NAME="Klipper Eddy Tap Wizard"
PROJECT_SLUG="klipper-eddy-tap-wizard"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"

HOME_DIR="${HOME}"
PRINTER_DATA_DIR="${PRINTER_DATA_DIR:-${HOME_DIR}/printer_data}"
CONFIG_DIR="${CONFIG_DIR:-${PRINTER_DATA_DIR}/config}"
KLIPPER_DIR="${KLIPPER_DIR:-${HOME_DIR}/klipper}"
KLIPPER_EXTRAS_DIR="${KLIPPER_EXTRAS_DIR:-${KLIPPER_DIR}/klippy/extras}"
KLIPPY_LOG="${PRINTER_DATA_DIR}/logs/klippy.log"

SRC_MACROS="${SCRIPT_DIR}/printer_data/config/eddy_macros.cfg"
SRC_WIZARD="${SCRIPT_DIR}/printer_data/config/eddy_setup_wizard.cfg"
SRC_TEMPLATE_FULL="${SCRIPT_DIR}/printer_data/config/templates/eddy.cfg.template"
SRC_TEMPLATE_MINIMAL="${SCRIPT_DIR}/printer_data/config/templates/eddy-minimal.cfg.template"
SRC_CLEAR_TEMPLATE="${SCRIPT_DIR}/printer_data/config/templates/eddy_clear_calibration.cfg.template"
SRC_GCODE_SHELL_COMMAND="${SCRIPT_DIR}/klipper/klippy/extras/gcode_shell_command.py"
SRC_CLEAR_SCRIPT="${SCRIPT_DIR}/scripts/clear_eddy_calibration.py"
SRC_TEMP_PROBE="${SCRIPT_DIR}/klipper/klippy/extras/temperature_probe.py"

DST_MACROS="${CONFIG_DIR}/eddy_macros.cfg"
DST_WIZARD="${CONFIG_DIR}/eddy_setup_wizard.cfg"
DST_CLEAR="${CONFIG_DIR}/eddy_clear_calibration.cfg"
DST_EDDY="${CONFIG_DIR}/eddy.cfg"

# Previous Eddy Tap Wizard releases commonly used this nested layout.
LEGACY_EDDY_DIR="${CONFIG_DIR}/eddy"
LEGACY_EDDY_CFG="${LEGACY_EDDY_DIR}/eddy.cfg"
LEGACY_MACROS="${LEGACY_EDDY_DIR}/eddy_macros.cfg"
LEGACY_WIZARD="${LEGACY_EDDY_DIR}/eddy_setup_wizard.cfg"
LEGACY_CLEAR="${LEGACY_EDDY_DIR}/eddy_clear_calibration.cfg"

DST_TEMP_PROBE="${KLIPPER_EXTRAS_DIR}/temperature_probe.py"
DST_GCODE_SHELL_COMMAND="${KLIPPER_EXTRAS_DIR}/gcode_shell_command.py"
PRINTER_CFG="${CONFIG_DIR}/printer.cfg"

STATE_DIR="${XDG_CONFIG_HOME:-${HOME_DIR}/.config}/${PROJECT_SLUG}"
TEMP_HASH_FILE="${STATE_DIR}/temperature_probe.installed.sha256"
GCODE_SHELL_HASH_FILE="${STATE_DIR}/gcode_shell_command.installed.sha256"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_ROOT="${CONFIG_DIR}/eddy_wizard_backups"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

AUTO_YES=0
DO_UPDATE=0
DETECT_ONLY=0
AFTER_PULL="${EDDY_WIZARD_AFTER_PULL:-0}"

# Installation mode selected after discovery:
#   generated          = a template-generated ~/printer_data/config/eddy.cfg is active
#   existing_eddy_file = a pre-existing user-owned eddy.cfg is activated without rewriting it
#   existing_native    = use an existing native [probe_eddy_current ...] configuration in-place
#   legacy_keep        = keep the previous config/eddy/ nested layout in-place
#   legacy_migrated    = migrate the previous nested layout to flat config/ files
CONFIG_MODE=""

ACTIVE_DST_MACROS="${DST_MACROS}"
ACTIVE_DST_WIZARD="${DST_WIZARD}"
LEGACY_MIGRATION_CLEANUP_PENDING=0
FRESH_EDDY_CFG_GENERATED=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    RED=$'\033[1;31m'
    GREEN=$'\033[1;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[1;34m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    BOLD=""
    RESET=""
fi

info()  { printf '%s[INFO]%s %s\n' "${BLUE}" "${RESET}" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "${YELLOW}" "${RESET}" "$*"; }
error() { printf '%s[FAIL]%s %s\n' "${RED}" "${RESET}" "$*" >&2; }

die() {
    error "$*"
    exit 1
}

usage() {
    cat <<'EOF'
Klipper Eddy Tap Wizard Installer

Usage:
  ./install.sh [options]

Options:
  --update       Pull the latest commit from the currently checked-out branch
                 before running the installer.
  --detect-only  Detect and report the current Eddy/Klipper configuration.
                 Do not modify printer configuration or Klipper files.
  -y, --yes      Automatically answer yes to yes/no prompts.
                 Fresh eddy.cfg generation still requires interactive geometry
                 and connection information.
  -h, --help     Show this help.

Environment overrides:
  PRINTER_DATA_DIR=/path/to/printer_data
  CONFIG_DIR=/path/to/config
  KLIPPER_DIR=/path/to/klipper
  KLIPPER_EXTRAS_DIR=/path/to/klippy/extras

Recommended update command:
  ./install.sh --update

The installer:
  - discovers the active Klipper config tree starting at printer.cfg
  - detects native Eddy, BTT-style Eddy, Eddy-NG, legacy nested Wizard layouts,
    and common conflicts
  - generates ~/printer_data/config/eddy.cfg from a Full or Minimal template
    on a fresh setup
  - can safely migrate the old config/eddy/ Wizard layout to flat config/ files
  - never regenerates or replaces an existing flat eddy.cfg during normal updates
  - validates/prompts for the required [bed_mesh] zero_reference_position
  - symlinks eddy_macros.cfg and eddy_setup_wizard.cfg into printer_data/config
  - backs up files before replacing/modifying them
  - checks/adds [save_variables] when required and none exists
  - safely manages the project's modified temperature_probe.py
  - restarts Klipper after a successful installation
EOF
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-y}"
    local answer

    if [[ "${AUTO_YES}" -eq 1 ]]; then
        printf '%s [auto: yes]\n' "${prompt}"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        [[ "${default}" == "y" ]]
        return
    fi

    if [[ "${default}" == "y" ]]; then
        read -r -p "${prompt} [Y/n] " answer || true
        answer="${answer:-y}"
    else
        read -r -p "${prompt} [y/N] " answer || true
        answer="${answer:-n}"
    fi

    [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

ANSWER=""

ask_choice() {
    local prompt="$1"
    local default="$2"
    local min="$3"
    local max="$4"
    local value

    while true; do
        read -r -p "${prompt} [${default}]: " value || true
        value="${value:-${default}}"

        if [[ "${value}" =~ ^[0-9]+$ ]] \
            && (( value >= min && value <= max )); then
            ANSWER="${value}"
            return 0
        fi

        warn "Enter a number from ${min} to ${max}."
    done
}

ask_required() {
    local prompt="$1"
    local value

    while true; do
        read -r -p "${prompt}: " value || true
        if [[ -n "${value}" ]]; then
            ANSWER="${value}"
            return 0
        fi
        warn "A value is required."
    done
}

ask_number() {
    local prompt="$1"
    local default="${2:-}"
    local value

    while true; do
        if [[ -n "${default}" ]]; then
            read -r -p "${prompt} [${default}]: " value || true
            value="${value:-${default}}"
        else
            read -r -p "${prompt}: " value || true
        fi

        if [[ "${value}" =~ ^-?([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
            ANSWER="${value}"
            return 0
        fi

        warn "Enter a valid numeric value."
    done
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)
            DO_UPDATE=1
            shift
            ;;
        --detect-only)
            DETECT_ONLY=1
            shift
            ;;
        -y|--yes)
            AUTO_YES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1 (use --help)"
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Safety / prerequisite checks
# ---------------------------------------------------------------------------

printf '\n%s%s Installer%s\n' "${BOLD}" "${PROJECT_NAME}" "${RESET}"
printf '%s\n\n' "------------------------------------------------------------"

if [[ -n "${SUDO_USER:-}" ]]; then
    die "Do not run this installer with sudo. Run it as your normal Klipper user."
fi

command -v git >/dev/null 2>&1 || die "git is required but was not found."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required but was not found."
command -v grep >/dev/null 2>&1 || die "grep is required but was not found."
command -v awk >/dev/null 2>&1 || die "awk is required but was not found."
command -v sed >/dev/null 2>&1 || die "sed is required but was not found."

[[ -d "${CONFIG_DIR}" ]] || die "Klipper config directory not found: ${CONFIG_DIR}"
[[ -f "${PRINTER_CFG}" ]] || die "printer.cfg not found: ${PRINTER_CFG}"

# In detect-only mode the repository payload does not need to be complete.
if [[ "${DETECT_ONLY}" -eq 0 ]]; then
    [[ -d "${KLIPPER_EXTRAS_DIR}" ]] || die "Klipper extras directory not found: ${KLIPPER_EXTRAS_DIR}"
    
    [[ -f "${SRC_MACROS}" ]] || die "Repository file missing: ${SRC_MACROS}"
    [[ -f "${SRC_WIZARD}" ]] || die "Repository file missing: ${SRC_WIZARD}"
    [[ -f "${SRC_TEMPLATE_FULL}" ]] || die "Repository file missing: ${SRC_TEMPLATE_FULL}"
    [[ -f "${SRC_TEMPLATE_MINIMAL}" ]] || die "Repository file missing: ${SRC_TEMPLATE_MINIMAL}"
    [[ -f "${SRC_CLEAR_TEMPLATE}" ]] || die "Repository file missing: ${SRC_CLEAR_TEMPLATE}"
    [[ -f "${SRC_CLEAR_SCRIPT}" ]] || die "Repository file missing: ${SRC_CLEAR_SCRIPT}"
    [[ -f "${SRC_TEMP_PROBE}" ]] || die "Repository file missing: ${SRC_TEMP_PROBE}"
    [[ -f "${SRC_GCODE_SHELL_COMMAND}" ]] || die "Repository file missing: ${SRC_GCODE_SHELL_COMMAND}"

    # Verify this looks like the expected patched temperature_probe.py.
    grep -Fq 'TAP_START_Z = 5.' "${SRC_TEMP_PROBE}" \
        || die "Repository temperature_probe.py does not contain TAP_START_Z = 5."
    grep -Fq 'tool_zero_z = mpresult.bed_z' "${SRC_TEMP_PROBE}" \
        || die "Repository temperature_probe.py does not contain the expected Tap bed-reference fix."
    grep -Fq 'curpos[2] = self.last_zero_pos + TAP_START_Z' "${SRC_TEMP_PROBE}" \
        || die "Repository temperature_probe.py does not contain the expected safe thermal Tap start-height fix."

    ok "Repository files validated."
fi

info "Repository:      ${SCRIPT_DIR}"
info "Printer config:  ${CONFIG_DIR}"
info "Klipper source:  ${KLIPPER_DIR}"

# ---------------------------------------------------------------------------
# Optional git update
# ---------------------------------------------------------------------------

if [[ "${DO_UPDATE}" -eq 1 && "${AFTER_PULL}" -ne 1 ]]; then
    if ! git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "--update was requested, but ${SCRIPT_DIR} is not a Git working tree."
    fi

    branch="$(git -C "${SCRIPT_DIR}" branch --show-current)"
    [[ -n "${branch}" ]] || die "Cannot update while the repository is in detached HEAD state."

    if [[ -n "$(git -C "${SCRIPT_DIR}" status --porcelain)" ]]; then
        die "Repository has local changes. Commit/stash them before running --update."
    fi

    info "Pulling latest changes from branch '${branch}'..."
    git -C "${SCRIPT_DIR}" pull --ff-only origin "${branch}"
    ok "Repository updated."

    export EDDY_WIZARD_AFTER_PULL=1
    reexec_args=()
    [[ "${AUTO_YES}" -eq 1 ]] && reexec_args+=("--yes")
    [[ "${DETECT_ONLY}" -eq 1 ]] && reexec_args+=("--detect-only")
    exec "${SCRIPT_PATH}" "${reexec_args[@]}"
fi

# ---------------------------------------------------------------------------
# Backup helpers
# ---------------------------------------------------------------------------

BACKUP_CREATED=0

ensure_backup_dir() {
    if [[ "${BACKUP_CREATED}" -eq 0 ]]; then
        mkdir -p "${BACKUP_DIR}"
        BACKUP_CREATED=1
    fi
}

backup_path() {
    local src="$1"
    local label="$2"

    [[ -e "${src}" || -L "${src}" ]] || return 0

    ensure_backup_dir
    cp -a -- "${src}" "${BACKUP_DIR}/${label}"
    ok "Backed up ${src} -> ${BACKUP_DIR}/${label}"
}

# ---------------------------------------------------------------------------
# Active Klipper config-tree discovery
# ---------------------------------------------------------------------------

declare -a ACTIVE_CFG_FILES=()
declare -A ACTIVE_CFG_SEEN=()

discover_cfg_file() {
    local file="$1"
    local abs_file
    local identity
    local base_dir
    local line
    local include_spec
    local include_pattern
    local -a matches=()
    local match

    if [[ "${file}" = /* ]]; then
        abs_file="${file}"
    else
        abs_file="${CONFIG_DIR}/${file}"
    fi

    [[ -f "${abs_file}" ]] || return 0

    identity="$(readlink -f -- "${abs_file}" 2>/dev/null || printf '%s' "${abs_file}")"
    if [[ -n "${ACTIVE_CFG_SEEN[${identity}]+x}" ]]; then
        return 0
    fi

    ACTIVE_CFG_SEEN["${identity}"]=1
    ACTIVE_CFG_FILES+=("${abs_file}")
    base_dir="$(dirname -- "${abs_file}")"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Only active [include ...] directives are followed. Commented lines
        # intentionally do not match this expression.
        if [[ "${line}" =~ ^[[:space:]]*\[include[[:space:]]+([^]]+)\][[:space:]]*(#.*)?$ ]]; then
            include_spec="$(trim "${BASH_REMATCH[1]}")"

            if [[ "${include_spec}" = /* ]]; then
                include_pattern="${include_spec}"
            else
                include_pattern="${base_dir}/${include_spec}"
            fi

            matches=()
            mapfile -t matches < <(compgen -G "${include_pattern}" || true)

            for match in "${matches[@]}"; do
                [[ -f "${match}" ]] && discover_cfg_file "${match}"
            done
        fi
    done < "${abs_file}"
}

rebuild_cfg_tree() {
    ACTIVE_CFG_FILES=()
    ACTIVE_CFG_SEEN=()
    discover_cfg_file "${PRINTER_CFG}"
}

path_is_active() {
    local target="$1"
    local target_id
    local file
    local file_id

    [[ -e "${target}" || -L "${target}" ]] || return 1
    target_id="$(readlink -f -- "${target}" 2>/dev/null || printf '%s' "${target}")"

    for file in "${ACTIVE_CFG_FILES[@]}"; do
        file_id="$(readlink -f -- "${file}" 2>/dev/null || printf '%s' "${file}")"
        [[ "${file_id}" == "${target_id}" ]] && return 0
    done

    return 1
}

cfg_tree_has_regex() {
    local regex="$1"
    local file

    for file in "${ACTIVE_CFG_FILES[@]}"; do
        if grep -Eq "${regex}" "${file}" 2>/dev/null; then
            return 0
        fi
    done

    return 1
}

print_active_cfg_tree() {
    local file
    info "Active Klipper config files:"
    for file in "${ACTIVE_CFG_FILES[@]}"; do
        printf '  - %s\n' "${file}"
    done
}

# ---------------------------------------------------------------------------
# Eddy configuration discovery/classification
# ---------------------------------------------------------------------------

declare -a NATIVE_EDDY_RECORDS=()
declare -a EDDY_NG_RECORDS=()
declare -a LEGACY_INCLUDE_RECORDS=()
declare -a LEGACY_EXTRA_ACTIVE_FILES=()

EDDY_STATE="none"
BTT_STYLE=0
LEGACY_WIZARD_DETECTED=0
LEGACY_INCLUDE_USES_GLOB=0

scan_legacy_include_references() {
    local target_id=""
    local file
    local file_id
    local result
    local line_no
    local text
    local include_spec
    local include_pattern
    local candidate
    local candidate_id
    local base_dir
    local include_kind
    local -a matches=()

    LEGACY_INCLUDE_RECORDS=()
    LEGACY_INCLUDE_USES_GLOB=0

    [[ -e "${LEGACY_EDDY_CFG}" || -L "${LEGACY_EDDY_CFG}" ]] || return 0
    target_id="$(readlink -f -- "${LEGACY_EDDY_CFG}" 2>/dev/null || printf '%s' "${LEGACY_EDDY_CFG}")"

    for file in "${ACTIVE_CFG_FILES[@]}"; do
        file_id="$(readlink -f -- "${file}" 2>/dev/null || printf '%s' "${file}")"
        [[ "${file_id}" == "${target_id}" ]] && continue

        base_dir="$(dirname -- "${file}")"

        while IFS= read -r result; do
            [[ -n "${result}" ]] || continue
            line_no="${result%%:*}"
            text="${result#*:}"
            include_spec="$(printf '%s\n' "${text}" | sed -E 's/^[[:space:]]*\[include[[:space:]]+([^]]+)\].*$/\1/')"
            include_spec="$(trim "${include_spec}")"

            if [[ "${include_spec}" = /* ]]; then
                include_pattern="${include_spec}"
            else
                include_pattern="${base_dir}/${include_spec}"
            fi

            include_kind="direct"
            case "${include_spec}" in
                *'*'*|*'?'*|*'['*)
                    include_kind="glob"
                    matches=()
                    mapfile -t matches < <(compgen -G "${include_pattern}" || true)

                    for candidate in "${matches[@]}"; do
                        [[ -e "${candidate}" || -L "${candidate}" ]] || continue
                        candidate_id="$(readlink -f -- "${candidate}" 2>/dev/null || printf '%s' "${candidate}")"

                        if [[ "${candidate_id}" == "${target_id}" ]]; then
                            LEGACY_INCLUDE_RECORDS+=("${file}|${line_no}|${include_spec}|${include_kind}")
                            LEGACY_INCLUDE_USES_GLOB=1
                            break
                        fi
                    done
                    ;;
                *)
                    [[ -e "${include_pattern}" || -L "${include_pattern}" ]] || continue
                    candidate_id="$(readlink -f -- "${include_pattern}" 2>/dev/null || printf '%s' "${include_pattern}")"

                    if [[ "${candidate_id}" == "${target_id}" ]]; then
                        LEGACY_INCLUDE_RECORDS+=("${file}|${line_no}|${include_spec}|${include_kind}")
                    fi
                    ;;
            esac
        done < <(grep -nE '^[[:space:]]*\[include[[:space:]]+[^]]+\][[:space:]]*(#.*)?$' "${file}" 2>/dev/null || true)
    done
}

scan_legacy_wizard_layout() {
    local record=""
    local probe_file=""
    local probe_file_id=""
    local legacy_cfg_id=""
    local file

    LEGACY_WIZARD_DETECTED=0
    LEGACY_EXTRA_ACTIVE_FILES=()

    (( ${#NATIVE_EDDY_RECORDS[@]} == 1 )) || return 0

    record="${NATIVE_EDDY_RECORDS[0]}"
    IFS='|' read -r probe_file _ _ <<< "${record}"

    [[ -e "${LEGACY_EDDY_CFG}" || -L "${LEGACY_EDDY_CFG}" ]] || return 0
    [[ -e "${LEGACY_WIZARD}" || -L "${LEGACY_WIZARD}" ]] || return 0
    [[ -e "${LEGACY_MACROS}" || -L "${LEGACY_MACROS}" ]] || return 0

    path_is_active "${LEGACY_EDDY_CFG}" || return 0
    path_is_active "${LEGACY_WIZARD}" || return 0
    path_is_active "${LEGACY_MACROS}" || return 0

    probe_file_id="$(readlink -f -- "${probe_file}" 2>/dev/null || printf '%s' "${probe_file}")"
    legacy_cfg_id="$(readlink -f -- "${LEGACY_EDDY_CFG}" 2>/dev/null || printf '%s' "${LEGACY_EDDY_CFG}")"
    [[ "${probe_file_id}" == "${legacy_cfg_id}" ]] || return 0

    # A valid old-layout Wizard install has exactly the Eddy config, Wizard,
    # and macros active from config/eddy/. Extra active files make automatic
    # migration ambiguous, but the layout is still identified and can be kept.
    for file in "${ACTIVE_CFG_FILES[@]}"; do
        if [[ "${file}" == "${LEGACY_EDDY_DIR}/"* ]]; then
            case "$(basename -- "${file}")" in
                eddy.cfg|eddy_setup_wizard.cfg|eddy_macros.cfg|eddy_clear_calibration.cfg)
                    ;;
                *)
                    LEGACY_EXTRA_ACTIVE_FILES+=("${file}")
                    ;;
            esac
        fi
    done

    scan_legacy_include_references
    LEGACY_WIZARD_DETECTED=1
}

scan_eddy_sections() {
    local file
    local result
    local line_no
    local text
    local probe_name

    NATIVE_EDDY_RECORDS=()
    EDDY_NG_RECORDS=()
    BTT_STYLE=0
    LEGACY_WIZARD_DETECTED=0
    LEGACY_INCLUDE_RECORDS=()
    LEGACY_EXTRA_ACTIVE_FILES=()
    LEGACY_INCLUDE_USES_GLOB=0

    for file in "${ACTIVE_CFG_FILES[@]}"; do
        while IFS= read -r result; do
            [[ -n "${result}" ]] || continue
            line_no="${result%%:*}"
            text="${result#*:}"
            probe_name="$(printf '%s\n' "${text}" | sed -E 's/^[[:space:]]*\[probe_eddy_current[[:space:]]+([^]]+)\].*$/\1/')"
            NATIVE_EDDY_RECORDS+=("${file}|${line_no}|${probe_name}")
            [[ "${probe_name}" == "btt_eddy" ]] && BTT_STYLE=1
        done < <(grep -nE '^[[:space:]]*\[probe_eddy_current[[:space:]]+[^]]+\][[:space:]]*(#.*)?$' "${file}" 2>/dev/null || true)

        while IFS= read -r result; do
            [[ -n "${result}" ]] || continue
            line_no="${result%%:*}"
            text="${result#*:}"
            probe_name="$(printf '%s\n' "${text}" | sed -E 's/^[[:space:]]*\[probe_eddy_ng[[:space:]]+([^]]+)\].*$/\1/')"
            EDDY_NG_RECORDS+=("${file}|${line_no}|${probe_name}")
        done < <(grep -nE '^[[:space:]]*\[probe_eddy_ng[[:space:]]+[^]]+\][[:space:]]*(#.*)?$' "${file}" 2>/dev/null || true)

        if grep -Eq '^[[:space:]]*\[temperature_sensor[[:space:]]+btt_eddy_mcu\][[:space:]]*(#.*)?$' "${file}" 2>/dev/null \
            || grep -Eq '^[[:space:]]*\[temperature_probe[[:space:]]+btt_eddy\][[:space:]]*(#.*)?$' "${file}" 2>/dev/null \
            || grep -Eq '^[[:space:]]*\[gcode_macro[[:space:]]+PROBE_EDDY_CURRENT_CALIBRATE_AUTO\][[:space:]]*(#.*)?$' "${file}" 2>/dev/null; then
            BTT_STYLE=1
        fi
    done

    scan_legacy_wizard_layout

    if (( ${#NATIVE_EDDY_RECORDS[@]} > 0 && ${#EDDY_NG_RECORDS[@]} > 0 )); then
        EDDY_STATE="conflict"
    elif (( ${#EDDY_NG_RECORDS[@]} > 1 )); then
        EDDY_STATE="conflict"
    elif (( ${#NATIVE_EDDY_RECORDS[@]} > 1 )); then
        # The published wizard currently expects one native Eddy probe.
        EDDY_STATE="conflict"
    elif (( ${#EDDY_NG_RECORDS[@]} == 1 )); then
        EDDY_STATE="eddy_ng"
    elif (( ${#NATIVE_EDDY_RECORDS[@]} == 1 )); then
        if [[ "${LEGACY_WIZARD_DETECTED}" -eq 1 ]]; then
            EDDY_STATE="legacy_wizard"
        elif path_is_active "${DST_EDDY}" \
            && grep -Fq 'Klipper Eddy Tap Wizard' "${DST_EDDY}" 2>/dev/null; then
            EDDY_STATE="wizard"
        elif [[ "${BTT_STYLE}" -eq 1 ]]; then
            EDDY_STATE="btt_native"
        else
            EDDY_STATE="native"
        fi
    elif [[ -e "${DST_EDDY}" || -L "${DST_EDDY}" ]]; then
        EDDY_STATE="orphan_eddy_cfg"
    else
        EDDY_STATE="none"
    fi
}

print_probe_record() {
    local record="$1"
    local file line probe

    IFS='|' read -r file line probe <<< "${record}"
    printf '    Probe: [probe_eddy_current %s]\n' "${probe}"
    printf '    File:  %s:%s\n' "${file}" "${line}"
}

print_ng_record() {
    local record="$1"
    local file line probe

    IFS='|' read -r file line probe <<< "${record}"
    printf '    Probe: [probe_eddy_ng %s]\n' "${probe}"
    printf '    File:  %s:%s\n' "${file}" "${line}"
}

print_legacy_include_record() {
    local record="$1"
    local file line include_spec include_kind

    IFS='|' read -r file line include_spec include_kind <<< "${record}"
    printf '    Include: %s:%s -> [include %s]' "${file}" "${line}" "${include_spec}"
    [[ "${include_kind}" == "glob" ]] && printf ' (wildcard)'
    printf '\n'
}

report_eddy_state() {
    local record
    local file

    printf '\n%sEddy configuration discovery%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"

    case "${EDDY_STATE}" in
        wizard)
            ok "Existing Klipper Eddy Tap Wizard configuration detected."
            print_probe_record "${NATIVE_EDDY_RECORDS[0]}"
            info "User configuration: ${DST_EDDY}"
            ;;
        legacy_wizard)
            ok "Existing legacy Eddy Tap Wizard layout detected."
            print_probe_record "${NATIVE_EDDY_RECORDS[0]}"
            info "Legacy directory: ${LEGACY_EDDY_DIR}"
            info "Wizard:           ${LEGACY_WIZARD}"
            info "Macros:           ${LEGACY_MACROS}"

            if (( ${#LEGACY_INCLUDE_RECORDS[@]} > 0 )); then
                for record in "${LEGACY_INCLUDE_RECORDS[@]}"; do
                    print_legacy_include_record "${record}"
                done
            else
                warn "The active include that loads ${LEGACY_EDDY_CFG} could not be identified."
            fi

            if (( ${#LEGACY_EXTRA_ACTIVE_FILES[@]} > 0 )); then
                warn "Additional active files were found inside the legacy Eddy directory:"
                for file in "${LEGACY_EXTRA_ACTIVE_FILES[@]}"; do
                    printf '      %s\n' "${file}"
                done
                warn "Automatic flat-layout migration will be disabled until those files are reviewed."
            fi
            ;;
        btt_native)
            ok "Existing native Eddy configuration detected."
            info "Configuration resembles BIGTREETECH's current native Eddy sample."
            print_probe_record "${NATIVE_EDDY_RECORDS[0]}"
            ;;
        native)
            ok "Existing native Klipper Eddy configuration detected."
            print_probe_record "${NATIVE_EDDY_RECORDS[0]}"
            ;;
        eddy_ng)
            warn "Eddy-NG configuration detected."
            print_ng_record "${EDDY_NG_RECORDS[0]}"
            ;;
        conflict)
            error "Conflicting or unsupported multiple Eddy probe configurations detected."
            if (( ${#NATIVE_EDDY_RECORDS[@]} > 0 )); then
                printf '  Native Eddy sections:\n'
                for record in "${NATIVE_EDDY_RECORDS[@]}"; do
                    print_probe_record "${record}"
                done
            fi
            if (( ${#EDDY_NG_RECORDS[@]} > 0 )); then
                printf '  Eddy-NG sections:\n'
                for record in "${EDDY_NG_RECORDS[@]}"; do
                    print_ng_record "${record}"
                done
            fi
            ;;
        orphan_eddy_cfg)
            warn "${DST_EDDY} exists but is not part of the active config tree and no active Eddy probe was detected."
            ;;
        none)
            info "No active Eddy configuration detected."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Klipper origin / legacy BTT fork check
# ---------------------------------------------------------------------------

KLIPPER_ORIGIN=""
LEGACY_BTT_KLIPPER=0

check_klipper_origin() {
    if ! git -C "${KLIPPER_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        warn "${KLIPPER_DIR} is not a Git working tree; Klipper origin could not be verified."
        return 0
    fi

    KLIPPER_ORIGIN="$(git -C "${KLIPPER_DIR}" remote get-url origin 2>/dev/null || true)"

    if [[ -z "${KLIPPER_ORIGIN}" ]]; then
        warn "Klipper Git origin could not be determined."
        return 0
    fi

    info "Klipper origin: ${KLIPPER_ORIGIN}"

    if [[ "${KLIPPER_ORIGIN}" =~ [Bb][Ii][Gg][Tt][Rr][Ee][Ee][Tt][Ee][Cc][Hh].*[Kk][Ll][Ii][Pp][Pp][Ee][Rr] ]]; then
        LEGACY_BTT_KLIPPER=1
        warn "A BIGTREETECH Klipper fork appears to be in use."
        warn "Current BIGTREETECH Eddy documentation uses mainline Klipper."
    else
        ok "No legacy BIGTREETECH Klipper origin was detected."
    fi
}

# ---------------------------------------------------------------------------
# Eddy USB firmware/identity advisory check
# ---------------------------------------------------------------------------

check_eddy_usb_identity() {
    local serial_path="$1"
    local base

    [[ -n "${serial_path}" ]] || return 0
    base="$(basename -- "${serial_path}")"

    printf '\n%sEddy USB firmware/identity advisory%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"

    if [[ -e "${serial_path}" || -L "${serial_path}" ]]; then
        ok "Configured Eddy USB serial path currently exists: ${serial_path}"
    else
        warn "Configured Eddy USB serial path is not currently present: ${serial_path}"
    fi

    if [[ "${base}" =~ [Kk]lipper ]] && [[ "${base}" =~ [Rr][Pp]2040|[Ee]ddy ]]; then
        ok "USB identifier looks consistent with Klipper firmware on an Eddy/RP2040 device."
    elif [[ "${base}" =~ [Ee]ddy ]]; then
        info "USB identifier contains 'Eddy', but the exact firmware build cannot be proven from the device name."
    else
        warn "The USB identifier does not clearly identify Eddy/Klipper firmware."
        warn "This may still be valid if the device uses a custom USB descriptor."
    fi

    # BTT's current guide specifically warns about the RP2040 flash-chip
    # CLKDIV 4 build option. That compile-time selection is not exposed by a
    # normal Klipper runtime identity, so the installer can only warn.
    info "Runtime detection cannot verify BTT's RP2040 flash-chip CLKDIV 4 build setting."
}

find_active_mcu_eddy_serial() {
    local file
    local line
    local in_section=0
    local value

    for file in "${ACTIVE_CFG_FILES[@]}"; do
        in_section=0
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ "${line}" =~ ^[[:space:]]*\[mcu[[:space:]]+eddy\][[:space:]]*(#.*)?$ ]]; then
                in_section=1
                continue
            fi

            if [[ "${line}" =~ ^[[:space:]]*\[[^]]+\] ]]; then
                in_section=0
            fi

            if [[ "${in_section}" -eq 1 && "${line}" =~ ^[[:space:]]*serial[[:space:]]*:[[:space:]]*([^#]+) ]]; then
                value="$(trim "${BASH_REMATCH[1]}")"
                printf '%s' "${value}"
                return 0
            fi
        done < "${file}"
    done

    return 1
}

# ---------------------------------------------------------------------------
# Required Eddy calibration reference discovery / management
# ---------------------------------------------------------------------------

declare -a BED_MESH_RECORDS=()
declare -a TEMP_PROBE_RECORDS=()

BED_MESH_FILE=""
BED_MESH_LINE=""
BED_MESH_ZERO_RAW=""
BED_MESH_ZERO_VALID=0
BED_MESH_ZERO_X=""
BED_MESH_ZERO_Y=""

TEMP_CAL_FILE=""
TEMP_CAL_LINE=""
TEMP_CAL_POSITION_RAW=""
TEMP_CAL_RECOMMEND_VALID=0
TEMP_CAL_RECOMMEND_X=""
TEMP_CAL_RECOMMEND_Y=""

is_number() {
    local value="$1"
    [[ "${value}" =~ ^-?([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

parse_xy_pair() {
    local raw="$1"
    local first=""
    local second=""
    local extra=""

    IFS=',' read -r first second extra <<< "${raw}"
    first="$(trim "${first:-}")"
    second="$(trim "${second:-}")"

    [[ -n "${first}" && -n "${second}" ]] || return 1
    is_number "${first}" || return 1
    is_number "${second}" || return 1

    PARSED_X="${first}"
    PARSED_Y="${second}"
    return 0
}

read_option_from_section() {
    local file="$1"
    local start_line="$2"
    local option="$3"

    awk -v start="${start_line}" -v option="${option}" '
        NR < start { next }
        NR == start { in_section=1; next }

        in_section && /^[[:space:]]*\[[^]]+\][[:space:]]*([#;].*)?$/ {
            exit
        }

        in_section {
            line=$0
            sub(/[[:space:]]*[#;].*$/, "", line)

            pattern="^[[:space:]]*" option "[[:space:]]*[:=][[:space:]]*"
            if (line ~ pattern) {
                sub(pattern, "", line)
                sub(/[[:space:]]+$/, "", line)
                print line
                exit
            }
        }
    ' "${file}"
}

scan_calibration_reference() {
    local file
    local result
    local line_no
    local probe_name=""
    local record=""
    local raw=""

    BED_MESH_RECORDS=()
    TEMP_PROBE_RECORDS=()

    BED_MESH_FILE=""
    BED_MESH_LINE=""
    BED_MESH_ZERO_RAW=""
    BED_MESH_ZERO_VALID=0
    BED_MESH_ZERO_X=""
    BED_MESH_ZERO_Y=""

    TEMP_CAL_FILE=""
    TEMP_CAL_LINE=""
    TEMP_CAL_POSITION_RAW=""
    TEMP_CAL_RECOMMEND_VALID=0
    TEMP_CAL_RECOMMEND_X=""
    TEMP_CAL_RECOMMEND_Y=""

    # Locate the active [bed_mesh] section and the file that owns it.
    for file in "${ACTIVE_CFG_FILES[@]}"; do
        while IFS= read -r result; do
            [[ -n "${result}" ]] || continue
            line_no="${result%%:*}"
            BED_MESH_RECORDS+=("${file}|${line_no}")
        done < <(grep -nE '^[[:space:]]*\[bed_mesh\][[:space:]]*([#;].*)?$' "${file}" 2>/dev/null || true)
    done

    if (( ${#BED_MESH_RECORDS[@]} == 1 )); then
        IFS='|' read -r BED_MESH_FILE BED_MESH_LINE <<< "${BED_MESH_RECORDS[0]}"
        BED_MESH_ZERO_RAW="$(read_option_from_section "${BED_MESH_FILE}" "${BED_MESH_LINE}" "zero_reference_position")"

        if [[ -n "${BED_MESH_ZERO_RAW}" ]] && parse_xy_pair "${BED_MESH_ZERO_RAW}"; then
            BED_MESH_ZERO_VALID=1
            BED_MESH_ZERO_X="${PARSED_X}"
            BED_MESH_ZERO_Y="${PARSED_Y}"
        fi
    fi

    # If a single native Eddy probe exists, look for a matching
    # [temperature_probe <name>] calibration_position. Its X/Y position is a
    # useful recommendation, but it is never silently imposed on the user.
    if (( ${#NATIVE_EDDY_RECORDS[@]} == 1 )); then
        IFS='|' read -r _ _ probe_name <<< "${NATIVE_EDDY_RECORDS[0]}"

        for file in "${ACTIVE_CFG_FILES[@]}"; do
            while IFS= read -r result; do
                [[ -n "${result}" ]] || continue
                line_no="${result%%:*}"
                TEMP_PROBE_RECORDS+=("${file}|${line_no}")
            done < <(grep -nE "^[[:space:]]*\\[temperature_probe[[:space:]]+${probe_name}\\][[:space:]]*([#;].*)?$" "${file}" 2>/dev/null || true)
        done

        if (( ${#TEMP_PROBE_RECORDS[@]} == 1 )); then
            IFS='|' read -r TEMP_CAL_FILE TEMP_CAL_LINE <<< "${TEMP_PROBE_RECORDS[0]}"
            TEMP_CAL_POSITION_RAW="$(read_option_from_section "${TEMP_CAL_FILE}" "${TEMP_CAL_LINE}" "calibration_position")"

            if [[ -n "${TEMP_CAL_POSITION_RAW}" ]] && parse_xy_pair "${TEMP_CAL_POSITION_RAW}"; then
                TEMP_CAL_RECOMMEND_VALID=1
                TEMP_CAL_RECOMMEND_X="${PARSED_X}"
                TEMP_CAL_RECOMMEND_Y="${PARSED_Y}"
            fi
        fi
    fi
}

report_calibration_reference() {
    printf '\n%sEddy calibration reference%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"

    if (( ${#BED_MESH_RECORDS[@]} == 0 )); then
        warn "No active [bed_mesh] section was detected."
        warn "zero_reference_position is required for initial Eddy calibration."
        return 0
    fi

    if (( ${#BED_MESH_RECORDS[@]} > 1 )); then
        error "Multiple active [bed_mesh] sections were detected."
        for record in "${BED_MESH_RECORDS[@]}"; do
            printf '    %s\n' "${record}"
        done
        return 0
    fi

    info "Bed mesh: ${BED_MESH_FILE}:${BED_MESH_LINE}"

    if [[ "${BED_MESH_ZERO_VALID}" -eq 1 ]]; then
        ok "zero_reference_position detected: X${BED_MESH_ZERO_X} Y${BED_MESH_ZERO_Y}"
    elif [[ -n "${BED_MESH_ZERO_RAW}" ]]; then
        warn "zero_reference_position exists but could not be parsed as X, Y: ${BED_MESH_ZERO_RAW}"
    else
        warn "zero_reference_position is not configured."
    fi

    if [[ "${TEMP_CAL_RECOMMEND_VALID}" -eq 1 ]]; then
        info "Matching temperature calibration position suggests: X${TEMP_CAL_RECOMMEND_X} Y${TEMP_CAL_RECOMMEND_Y}"
    fi
}

write_bed_mesh_zero_reference() {
    local x="$1"
    local y="$2"
    local tmp_cfg
    local backup_label

    [[ -n "${BED_MESH_FILE}" && -n "${BED_MESH_LINE}" ]] \
        || die "Internal error: [bed_mesh] location was not resolved."

    backup_label="$(basename -- "${BED_MESH_FILE}").before_zero_reference_position"
    backup_path "${BED_MESH_FILE}" "${backup_label}"
    tmp_cfg="$(mktemp)"

    awk -v start="${BED_MESH_LINE}" -v value="${x}, ${y}" '
        NR == start {
            print
            in_section=1
            next
        }

        in_section && /^[[:space:]]*\[[^]]+\][[:space:]]*([#;].*)?$/ {
            if (!written) {
                print "zero_reference_position: " value
                written=1
            }
            in_section=0
            print
            next
        }

        in_section && /^[[:space:]]*zero_reference_position[[:space:]]*[:=]/ {
            if (!written) {
                print "zero_reference_position: " value
                written=1
            }
            next
        }

        { print }

        END {
            if (in_section && !written) {
                print "zero_reference_position: " value
            }
        }
    ' "${BED_MESH_FILE}" > "${tmp_cfg}"

    cat "${tmp_cfg}" > "${BED_MESH_FILE}"
    rm -f -- "${tmp_cfg}"

    ok "Set [bed_mesh] zero_reference_position: ${x}, ${y}"
}

numeric_equal() {
    local a="$1"
    local b="$2"
    awk -v a="${a}" -v b="${b}" 'BEGIN { exit !(a == b) }'
}

ensure_calibration_reference() {
    local default_x=""
    local default_y=""
    local selected_x=""
    local selected_y=""

    rebuild_cfg_tree
    scan_eddy_sections
    scan_calibration_reference

    printf '\n%sRequired Eddy calibration reference%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"

    if (( ${#BED_MESH_RECORDS[@]} == 0 )); then
        error "No active [bed_mesh] configuration was found."
        printf '\nThe Eddy Tap Wizard requires an existing [bed_mesh] section because\n'
        printf 'zero_reference_position is required for initial Eddy calibration.\n\n'
        printf 'Configure [bed_mesh], then rerun the installer.\n\n'
        exit 1
    fi

    if (( ${#BED_MESH_RECORDS[@]} > 1 )); then
        error "Multiple active [bed_mesh] sections were detected."
        die "Resolve the duplicate [bed_mesh] configuration before installing the Eddy Tap Wizard."
    fi

    printf 'Eddy calibration requires a zero reference position.\n\n'
    printf 'This is the NOZZLE position used for the initial Eddy calibration.\n\n'

    if [[ "${BED_MESH_ZERO_VALID}" -eq 1 ]]; then
        info "Existing zero_reference_position: X${BED_MESH_ZERO_X} Y${BED_MESH_ZERO_Y}"
        default_x="${BED_MESH_ZERO_X}"
        default_y="${BED_MESH_ZERO_Y}"
    elif [[ -n "${BED_MESH_ZERO_RAW}" ]]; then
        warn "Existing zero_reference_position could not be parsed: ${BED_MESH_ZERO_RAW}"
        warn "A valid X, Y value must be entered."
    else
        warn "No zero_reference_position is currently configured."
    fi

    if [[ "${TEMP_CAL_RECOMMEND_VALID}" -eq 1 ]]; then
        info "Recommended from temperature calibration: X${TEMP_CAL_RECOMMEND_X} Y${TEMP_CAL_RECOMMEND_Y}"

        # If no valid existing zero reference is present, use the matching
        # temperature calibration_position as the suggested input default.
        if [[ -z "${default_x}" || -z "${default_y}" ]]; then
            default_x="${TEMP_CAL_RECOMMEND_X}"
            default_y="${TEMP_CAL_RECOMMEND_Y}"
        fi
    fi

    # Fresh template generation already required the user to enter this value
    # as Zero reference X/Y. Do not ask the same question twice.
    if [[ "${FRESH_EDDY_CFG_GENERATED}" -eq 1 && "${BED_MESH_ZERO_VALID}" -eq 1 ]]; then
        ok "Fresh template already contains the confirmed zero reference position."
        return 0
    fi

    # A normal ./install.sh --update should not repeatedly ask the user to
    # reconfirm geometry that is already valid. Missing/invalid values still
    # require interactive input even during an update.
    if [[ "${AFTER_PULL}" -eq 1 && "${BED_MESH_ZERO_VALID}" -eq 1 ]]; then
        ok "Update mode: preserving existing zero_reference_position."
        return 0
    fi

    # Non-interactive installs cannot invent or reconfirm printer geometry.
    if [[ ! -t 0 ]]; then
        if [[ "${BED_MESH_ZERO_VALID}" -eq 1 ]]; then
            ok "Non-interactive mode: preserving existing zero_reference_position."
            return 0
        fi
        die "zero_reference_position requires interactive X/Y input. Rerun the installer from an interactive terminal."
    fi

    while true; do
        if [[ -n "${default_x}" ]]; then
            ask_number "Zero reference X" "${default_x}"
        else
            ask_number "Zero reference X"
        fi
        selected_x="${ANSWER}"

        if [[ -n "${default_y}" ]]; then
            ask_number "Zero reference Y" "${default_y}"
        else
            ask_number "Zero reference Y"
        fi
        selected_y="${ANSWER}"

        printf '\n%sEddy calibration reference:%s\n\n' "${BOLD}" "${RESET}"
        printf '  Nozzle X: %s\n' "${selected_x}"
        printf '  Nozzle Y: %s\n\n' "${selected_y}"
        printf 'This will be written as:\n\n'
        printf '  zero_reference_position: %s, %s\n\n' "${selected_x}" "${selected_y}"

        if ask_yes_no "Continue?" "y"; then
            break
        fi

        printf '\nRe-enter the zero reference position.\n\n'
        default_x="${selected_x}"
        default_y="${selected_y}"
    done

    if [[ "${BED_MESH_ZERO_VALID}" -eq 1 ]] \
        && numeric_equal "${selected_x}" "${BED_MESH_ZERO_X}" \
        && numeric_equal "${selected_y}" "${BED_MESH_ZERO_Y}"; then
        ok "zero_reference_position confirmed; no change was required."
        return 0
    fi

    write_bed_mesh_zero_reference "${selected_x}" "${selected_y}"

    rebuild_cfg_tree
    scan_eddy_sections
    scan_calibration_reference

    if [[ "${BED_MESH_ZERO_VALID}" -ne 1 ]] \
        || ! numeric_equal "${BED_MESH_ZERO_X}" "${selected_x}" \
        || ! numeric_equal "${BED_MESH_ZERO_Y}" "${selected_y}"; then
        die "zero_reference_position verification failed after writing the configuration."
    fi

    ok "Required Eddy calibration reference verified."
}

# ---------------------------------------------------------------------------
# Initial discovery
# ---------------------------------------------------------------------------

rebuild_cfg_tree
scan_eddy_sections
check_klipper_origin
report_eddy_state

if [[ "${DETECT_ONLY}" -eq 1 ]]; then
    scan_calibration_reference
    report_calibration_reference

    printf '\n'
    print_active_cfg_tree

    existing_serial="$(find_active_mcu_eddy_serial || true)"
    if [[ -n "${existing_serial}" ]]; then
        check_eddy_usb_identity "${existing_serial}"
    fi

    printf '\n%sDetection complete. No files were modified.%s\n\n' "${GREEN}${BOLD}" "${RESET}"
    exit 0
fi

if [[ "${LEGACY_BTT_KLIPPER}" -eq 1 ]]; then
    warn "The Eddy Tap Wizard should be installed against mainline Klipper."
    if ! ask_yes_no "Continue anyway despite the detected BIGTREETECH Klipper fork?" "n"; then
        die "Installation stopped. Migrate Klipper to mainline and rerun the installer."
    fi
fi

# Incompatible states stop before any printer/Klipper files are modified.
case "${EDDY_STATE}" in
    eddy_ng)
        printf '\n'
        warn "The Eddy Tap Wizard requires Klipper's native [probe_eddy_current] implementation."
        warn "Automatic Eddy-NG migration is intentionally NOT implemented in this rough draft."
        warn "No printer configuration or Klipper files have been changed."
        exit 0
        ;;
    conflict)
        printf '\n'
        warn "Resolve the Eddy configuration conflict before installing the wizard."
        warn "No printer configuration or Klipper files have been changed."
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# Template rendering
# ---------------------------------------------------------------------------

replace_placeholder() {
    local file="$1"
    local token="$2"
    local value="$3"
    local escaped

    escaped="${value//\\/\\\\}"
    escaped="${escaped//&/\\&}"
    escaped="${escaped//|/\\|}"

    sed -i "s|{{${token}}}|${escaped}|g" "${file}"
}

render_clear_calibration_cfg() {
    local dst_clear="${1:-"${dst_clear}"
    local tmp_clear
    local escaped_script

    printf '\n%sPreparing Eddy clear-calibration configuration...%s\n' "${BOLD}" "${RESET}"

    # 4B-4 only creates a missing rendered config.
    # Existing-file update/ownership behavior will be handled separately.
    if [[ -e "${dst_clear}" || -L "${DST_CLEAR}" ]]; then
        [[ -f "${dst_clear}" ]] \
            || die "Existing clear-calibration path is not a regular file: ${dst_clear}"

        if grep -Fq '__EDDY_CLEAR_SCRIPT__' "${dst_clear}"; then
            die "Existing ${dst_clear} still contains the unresolved __EDDY_CLEAR_SCRIPT__ placeholder."
        fi

        ok "Existing eddy_clear_calibration.cfg detected; preserving it."
        return 0
    fi

    tmp_clear="$(mktemp)"

    cp -a -- "${SRC_CLEAR_TEMPLATE}" "${tmp_clear}" \
        || {
            rm -f -- "${tmp_clear}"
            die "Failed to copy Eddy clear-calibration template."
        }

    escaped_script="${SRC_CLEAR_SCRIPT//\\/\\\\}"
    escaped_script="${escaped_script//&/\\&}"
    escaped_script="${escaped_script//|/\\|}"

    sed -i "s|__EDDY_CLEAR_SCRIPT__|${escaped_script}|g" "${tmp_clear}" \
        || {
            rm -f -- "${tmp_clear}"
            die "Failed to render Eddy clear-calibration script path."
        }

    if grep -Fq '__EDDY_CLEAR_SCRIPT__' "${tmp_clear}"; then
        rm -f -- "${tmp_clear}"
        die "Rendered Eddy clear-calibration config still contains __EDDY_CLEAR_SCRIPT__."
    fi

    if ! grep -Fq "${SRC_CLEAR_SCRIPT}" "${tmp_clear}"; then
        rm -f -- "${tmp_clear}"
        die "Rendered Eddy clear-calibration config does not contain the expected script path."
    fi

    cp -- "${tmp_clear}" "${dst_clear}" \
        || {
            rm -f -- "${tmp_clear}"
            die "Failed to install rendered eddy_clear_calibration.cfg."
        }

    chmod 0644 "${dst_clear}" 2>/dev/null || true
    rm -f -- "${tmp_clear}"

    [[ -f "${dst_clear}" ]] \
        || die "eddy_clear_calibration.cfg installation verification failed."

    ok "Generated Eddy clear-calibration configuration: ${dst_clear}"
}

validate_can_uuid() {
    local value="$1"
    [[ "${value}" =~ ^[0-9A-Fa-f]{12,32}$ ]]
}

generate_eddy_cfg() {
    local template_choice
    local connection_choice
    local template
    local serial_value=""
    local can_uuid=""
    local x_offset
    local y_offset
    local bed_center_x
    local bed_center_y
    local mesh_min_x
    local mesh_min_y
    local mesh_max_x
    local mesh_max_y
    local cal_bed_temp
    local cal_extruder_temp
    local max_validation_temp
    local tmp_cfg

    if [[ "${AUTO_YES}" -eq 1 || ! -t 0 ]]; then
        die "Fresh eddy.cfg generation requires interactive connection and printer geometry input. Rerun without --yes from an interactive terminal."
    fi

    printf '\n%sCreate Eddy configuration%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"
    printf 'Select configuration template:\n'
    printf '  1) Full    - core Eddy config plus commented Z-Tilt/QGL/homing/screw examples\n'
    printf '  2) Minimal - only the core Eddy, temperature compensation, and bed mesh\n'
    ask_choice "Template" "1" "1" "2"
    template_choice="${ANSWER}"

    if [[ "${template_choice}" -eq 1 ]]; then
        template="${SRC_TEMPLATE_FULL}"
    else
        template="${SRC_TEMPLATE_MINIMAL}"
    fi

    printf '\nSelect Eddy connection:\n'
    printf '  1) USB\n'
    printf '  2) CAN\n'
    ask_choice "Connection" "1" "1" "2"
    connection_choice="${ANSWER}"

    if [[ "${connection_choice}" -eq 1 ]]; then
        ask_required "Eddy USB serial path (example: /dev/serial/by-id/usb-Klipper_rp2040_...)"
        serial_value="${ANSWER}"
    else
        while true; do
            ask_required "Eddy CAN UUID"
            can_uuid="${ANSWER}"
            if validate_can_uuid "${can_uuid}"; then
                break
            fi
            warn "CAN UUID should be a hexadecimal identifier (normally 12 hex characters)."
        done
    fi

    printf '\nProbe offsets\n'
    ask_number "X offset"
    x_offset="${ANSWER}"
    ask_number "Y offset"
    y_offset="${ANSWER}"

    printf '\nEddy calibration reference (NOZZLE position)\n'
    ask_number "Zero reference X"
    bed_center_x="${ANSWER}"
    ask_number "Zero reference Y"
    bed_center_y="${ANSWER}"

    printf '\nBed mesh boundaries (probe-center reachable coordinates)\n'
    ask_number "Mesh minimum X"
    mesh_min_x="${ANSWER}"
    ask_number "Mesh minimum Y"
    mesh_min_y="${ANSWER}"
    ask_number "Mesh maximum X"
    mesh_max_x="${ANSWER}"
    ask_number "Mesh maximum Y"
    mesh_max_y="${ANSWER}"

    awk -v min="${mesh_min_x}" -v max="${mesh_max_x}" 'BEGIN { exit !(min < max) }' \
        || die "Mesh minimum X must be less than mesh maximum X."
    awk -v min="${mesh_min_y}" -v max="${mesh_max_y}" 'BEGIN { exit !(min < max) }' \
        || die "Mesh minimum Y must be less than mesh maximum Y."

    printf '\nTemperature compensation settings\n'
    ask_number "Calibration bed temperature" "95"
    cal_bed_temp="${ANSWER}"
    ask_number "Calibration extruder temperature" "150"
    cal_extruder_temp="${ANSWER}"
    ask_number "Maximum validation temperature" "100"
    max_validation_temp="${ANSWER}"

    printf '\n%sConfiguration summary%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"
    printf 'Template:                    %s\n' "$([[ "${template_choice}" -eq 1 ]] && printf 'Full' || printf 'Minimal')"
    printf 'Connection:                  %s\n' "$([[ "${connection_choice}" -eq 1 ]] && printf 'USB' || printf 'CAN')"
    [[ "${connection_choice}" -eq 1 ]] && printf 'Serial:                      %s\n' "${serial_value}"
    [[ "${connection_choice}" -eq 2 ]] && printf 'CAN UUID:                    %s\n' "${can_uuid}"
    printf 'Probe offset:                X=%s Y=%s\n' "${x_offset}" "${y_offset}"
    printf 'Zero reference (nozzle):     X=%s Y=%s\n' "${bed_center_x}" "${bed_center_y}"
    printf 'Mesh min:                    X=%s Y=%s\n' "${mesh_min_x}" "${mesh_min_y}"
    printf 'Mesh max:                    X=%s Y=%s\n' "${mesh_max_x}" "${mesh_max_y}"
    printf 'Calibration bed temp:        %s\n' "${cal_bed_temp}"
    printf 'Calibration extruder temp:   %s\n' "${cal_extruder_temp}"
    printf 'Maximum validation temp:     %s\n' "${max_validation_temp}"

    if ! ask_yes_no "Generate ${DST_EDDY} with these values?" "y"; then
        die "Configuration generation cancelled."
    fi

    tmp_cfg="$(mktemp)"
    cp -a -- "${template}" "${tmp_cfg}"

    replace_placeholder "${tmp_cfg}" "X_OFFSET" "${x_offset}"
    replace_placeholder "${tmp_cfg}" "Y_OFFSET" "${y_offset}"
    replace_placeholder "${tmp_cfg}" "BED_CENTER_X" "${bed_center_x}"
    replace_placeholder "${tmp_cfg}" "BED_CENTER_Y" "${bed_center_y}"
    replace_placeholder "${tmp_cfg}" "MESH_MIN_X" "${mesh_min_x}"
    replace_placeholder "${tmp_cfg}" "MESH_MIN_Y" "${mesh_min_y}"
    replace_placeholder "${tmp_cfg}" "MESH_MAX_X" "${mesh_max_x}"
    replace_placeholder "${tmp_cfg}" "MESH_MAX_Y" "${mesh_max_y}"
    replace_placeholder "${tmp_cfg}" "CALIBRATION_BED_TEMP" "${cal_bed_temp}"
    replace_placeholder "${tmp_cfg}" "CALIBRATION_EXTRUDER_TEMP" "${cal_extruder_temp}"
    replace_placeholder "${tmp_cfg}" "MAX_VALIDATION_TEMP" "${max_validation_temp}"

    if [[ "${connection_choice}" -eq 1 ]]; then
        replace_placeholder "${tmp_cfg}" "EDDY_SERIAL" "${serial_value}"
        # Leave the CAN placeholder commented for reference.
    else
        replace_placeholder "${tmp_cfg}" "EDDY_CANBUS_UUID" "${can_uuid}"

        # The templates are USB-active by default. Convert the MCU section to CAN.
        sed -i -E 's|^serial:[[:space:]].*$|#serial: {{EDDY_SERIAL}}|' "${tmp_cfg}"
        sed -i -E 's|^restart_method:[[:space:]]*command[[:space:]]*$|#restart_method: command|' "${tmp_cfg}"
        sed -i -E 's|^#canbus_uuid:[[:space:]]*|canbus_uuid: |' "${tmp_cfg}"
    fi

    # Any unresolved placeholders in ACTIVE lines indicate a bad/incomplete render.
    if grep -nE '^[[:space:]]*[^#[:space:]].*\{\{[A-Z0-9_]+\}\}' "${tmp_cfg}" >/dev/null 2>&1; then
        error "Generated eddy.cfg still contains unresolved placeholders in active lines:"
        grep -nE '^[[:space:]]*[^#[:space:]].*\{\{[A-Z0-9_]+\}\}' "${tmp_cfg}" >&2 || true
        rm -f -- "${tmp_cfg}"
        die "Template rendering failed."
    fi

    if [[ -e "${DST_EDDY}" || -L "${DST_EDDY}" ]]; then
        rm -f -- "${tmp_cfg}"
        die "${DST_EDDY} appeared during generation. It will not be overwritten."
    fi

    cp -- "${tmp_cfg}" "${DST_EDDY}"
    chmod 0644 "${DST_EDDY}" 2>/dev/null || true
    rm -f -- "${tmp_cfg}"

    FRESH_EDDY_CFG_GENERATED=1
    ok "Generated user-owned Eddy configuration: ${DST_EDDY}"
}

# ---------------------------------------------------------------------------
# Legacy nested Wizard layout migration
# ---------------------------------------------------------------------------

legacy_cfg_has_wizard_includes() {
    grep -Eq '^[[:space:]]*\[include[[:space:]]+(\./)?eddy_setup_wizard\.cfg\][[:space:]]*(#.*)?$' "${LEGACY_EDDY_CFG}" \
        && grep -Eq '^[[:space:]]*\[include[[:space:]]+(\./)?eddy_macros\.cfg\][[:space:]]*(#.*)?$' "${LEGACY_EDDY_CFG}"
}

legacy_migration_preflight() {
    local record=""
    local include_file=""
    local include_line=""
    local include_spec=""
    local include_kind=""
    local include_file_id=""
    local printer_cfg_id=""

    [[ "${LEGACY_WIZARD_DETECTED}" -eq 1 ]] \
        || die "Legacy migration was requested, but the legacy Wizard layout is no longer detected."

    if [[ -e "${DST_EDDY}" || -L "${DST_EDDY}" ]]; then
        die "Cannot migrate automatically because ${DST_EDDY} already exists. It will not be overwritten."
    fi

    if (( ${#LEGACY_EXTRA_ACTIVE_FILES[@]} > 0 )); then
        error "Automatic migration is disabled because extra active files exist under ${LEGACY_EDDY_DIR}:"
        for file in "${LEGACY_EXTRA_ACTIVE_FILES[@]}"; do
            printf '  %s\n' "${file}" >&2
        done
        die "Keep the legacy layout for now or review the extra files manually."
    fi

    if (( ${#LEGACY_INCLUDE_RECORDS[@]} != 1 )); then
        die "Automatic migration requires exactly one active include that loads ${LEGACY_EDDY_CFG}; found ${#LEGACY_INCLUDE_RECORDS[@]}."
    fi

    record="${LEGACY_INCLUDE_RECORDS[0]}"
    IFS='|' read -r include_file include_line include_spec include_kind <<< "${record}"

    include_file_id="$(readlink -f -- "${include_file}" 2>/dev/null || printf '%s' "${include_file}")"
    printer_cfg_id="$(readlink -f -- "${PRINTER_CFG}" 2>/dev/null || printf '%s' "${PRINTER_CFG}")"

    if [[ "${include_file_id}" != "${printer_cfg_id}" ]]; then
        error "The legacy Eddy layout is loaded from ${include_file}:${include_line}"
        die "This rough draft only auto-migrates legacy includes located directly in printer.cfg. Keep the existing layout for now."
    fi

    legacy_cfg_has_wizard_includes \
        || die "${LEGACY_EDDY_CFG} does not contain the expected Eddy Wizard macro/setup includes. Automatic migration was stopped."

    info "Legacy migration preflight passed."
    info "Source config: ${LEGACY_EDDY_CFG}"
    info "New config:    ${DST_EDDY}"
    info "Include:       ${include_file}:${include_line} -> [include ${include_spec}]"
    if [[ "${include_kind}" == "glob" ]]; then
        info "The legacy include is a wildcard and will be replaced with [include eddy.cfg]."
    fi

    return 0
}

rewrite_legacy_include_to_flat() {
    local record="${LEGACY_INCLUDE_RECORDS[0]}"
    local include_file=""
    local include_line=""
    local include_spec=""
    local include_kind=""
    local tmp_cfg

    IFS='|' read -r include_file include_line include_spec include_kind <<< "${record}"

    backup_path "${include_file}" "printer.cfg.before_legacy_eddy_migration"
    tmp_cfg="$(mktemp)"

    awk -v target_line="${include_line}" '
        NR == target_line {
            print "[include eddy.cfg]"
            next
        }
        { print }
    ' "${include_file}" > "${tmp_cfg}"

    cat "${tmp_cfg}" > "${include_file}"
    rm -f -- "${tmp_cfg}"

    ok "Replaced legacy [include ${include_spec}] with [include eddy.cfg]."
}

prepare_legacy_layout_migration() {
    local tmp_cfg

    legacy_migration_preflight

    printf '\n%sMigrating legacy Eddy Tap Wizard layout...%s\n' "${BOLD}" "${RESET}"

    # Back up the entire nested directory before any migration changes.
    backup_path "${LEGACY_EDDY_DIR}" "legacy_eddy_directory"

    # Copy the user-owned configuration as a real file, not a symlink.
    tmp_cfg="$(mktemp)"
    cp -L -- "${LEGACY_EDDY_CFG}" "${tmp_cfg}"

    if grep -nE '^[[:space:]]*[^#[:space:]].*\{\{[A-Z0-9_]+\}\}' "${tmp_cfg}" >/dev/null 2>&1; then
        rm -f -- "${tmp_cfg}"
        die "Legacy eddy.cfg unexpectedly contains unresolved active template placeholders. Migration stopped."
    fi

    cp -- "${tmp_cfg}" "${DST_EDDY}"
    chmod 0644 "${DST_EDDY}" 2>/dev/null || true
    rm -f -- "${tmp_cfg}"

    ok "Copied user-owned Eddy configuration to: ${DST_EDDY}"

    rewrite_legacy_include_to_flat

    LEGACY_MIGRATION_CLEANUP_PENDING=1
    CONFIG_MODE="legacy_migrated"

    # The old directory remains in place until the new flat configuration,
    # symlinks, and active include tree have all been validated.
    rebuild_cfg_tree
}

finalize_legacy_layout_migration() {
    local root_eddy_id=""
    local legacy_eddy_id=""

    [[ "${LEGACY_MIGRATION_CLEANUP_PENDING}" -eq 1 ]] || return 0

    rebuild_cfg_tree

    if ! path_is_active "${DST_EDDY}"; then
        warn "New flat eddy.cfg is not active. The legacy directory will NOT be removed."
        return 1
    fi

    if ! path_is_active "${DST_MACROS}" || ! path_is_active "${DST_WIZARD}"; then
        warn "New flat Eddy Wizard files are not both active. The legacy directory will NOT be removed."
        return 1
    fi

    if path_is_active "${LEGACY_EDDY_CFG}" \
        || path_is_active "${LEGACY_MACROS}" \
        || path_is_active "${LEGACY_WIZARD}"; then
        warn "One or more legacy nested Eddy files are still active. The legacy directory will NOT be removed."
        return 1
    fi

    if [[ -d "${LEGACY_EDDY_DIR}" ]]; then
        rm -rf -- "${LEGACY_EDDY_DIR}"
        ok "Removed the inactive legacy directory: ${LEGACY_EDDY_DIR}"
        info "A complete copy is preserved in: ${BACKUP_DIR}/legacy_eddy_directory"
    fi

    LEGACY_MIGRATION_CLEANUP_PENDING=0
FRESH_EDDY_CFG_GENERATED=0
    return 0
}

# ---------------------------------------------------------------------------
# Choose installation mode from discovered state
# ---------------------------------------------------------------------------

case "${EDDY_STATE}" in
    wizard)
        CONFIG_MODE="generated"
        ok "Existing ${DST_EDDY} will be preserved; zero_reference_position will be confirmed separately."
        ;;
    legacy_wizard)
        printf '\n'
        info "The previous nested Eddy Tap Wizard layout is active."
        printf 'Choose how to continue:\n'
        printf '  1) Keep the existing config/eddy/ layout\n'
        printf '  2) Migrate to the new flat config/ layout\n'

        if [[ "${AUTO_YES}" -eq 1 || ! -t 0 ]]; then
            legacy_choice=1
            info "Non-interactive/--yes mode: keeping the existing legacy layout."
        else
            ask_choice "Legacy layout action" "1" "1" "2"
            legacy_choice="${ANSWER}"
        fi

        if [[ "${legacy_choice}" -eq 1 ]]; then
            CONFIG_MODE="legacy_keep"
            ACTIVE_DST_MACROS="${LEGACY_MACROS}"
            ACTIVE_DST_WIZARD="${LEGACY_WIZARD}"
            ok "The existing nested Eddy configuration will remain in place."
        else
            prepare_legacy_layout_migration
            ACTIVE_DST_MACROS="${DST_MACROS}"
            ACTIVE_DST_WIZARD="${DST_WIZARD}"
        fi
        ;;
    btt_native)
        CONFIG_MODE="existing_native"
        printf '\n'
        info "The existing BTT-style native Eddy configuration can be used in-place."
        warn "This rough draft does not automatically migrate BTT configuration or old calibration data into eddy.cfg."
        if ! ask_yes_no "Keep the existing native Eddy config and install/update the Tap Wizard around it?" "y"; then
            die "Installation cancelled. Existing Eddy configuration was not changed."
        fi
        ;;
    native)
        CONFIG_MODE="existing_native"
        printf '\n'
        info "The existing native [probe_eddy_current] configuration can be used in-place."
        if ! ask_yes_no "Keep the existing native Eddy config and install/update the Tap Wizard around it?" "y"; then
            die "Installation cancelled. Existing Eddy configuration was not changed."
        fi
        ;;
    orphan_eddy_cfg)
        printf '\n'
        warn "An existing eddy.cfg will not be overwritten."
        if grep -Eq '^[[:space:]]*\[probe_eddy_current[[:space:]]+[^]]+\]' "${DST_EDDY}" 2>/dev/null; then
            info "The inactive eddy.cfg appears to contain a native Eddy probe section."
            if ask_yes_no "Activate the existing ${DST_EDDY} instead of generating a new file?" "y"; then
                CONFIG_MODE="existing_eddy_file"
            else
                die "Installation stopped to protect the existing eddy.cfg."
            fi
        else
            die "Existing inactive ${DST_EDDY} does not clearly contain a native Eddy probe. Inspect it manually before continuing."
        fi
        ;;
    none)
        generate_eddy_cfg
        CONFIG_MODE="generated"
        ;;
esac

# ---------------------------------------------------------------------------
# Generate portable clear-calibration configuration
# ---------------------------------------------------------------------------

if [[ "${CONFIG_MODE}" != "legacy_keep" ]]; then
    render_clear_calibration_cfg
fi

# ---------------------------------------------------------------------------
# Install the two repo-managed config files as symlinks
# ---------------------------------------------------------------------------

install_cfg_link() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if [[ -L "${dst}" ]]; then
        local current
        local desired
        current="$(readlink -f -- "${dst}" 2>/dev/null || true)"
        desired="$(readlink -f -- "${src}")"

        if [[ "${current}" == "${desired}" ]]; then
            ok "${label} already linked to repository."
            return 0
        fi
    fi

    if [[ -e "${dst}" || -L "${dst}" ]]; then
        backup_path "${dst}" "$(basename -- "${dst}").backup"
        rm -f -- "${dst}"
    fi

    ln -s -- "${src}" "${dst}"
    ok "Installed ${label}: ${dst} -> ${src}"
}

printf '\n%sInstalling wizard configuration files...%s\n' "${BOLD}" "${RESET}"

install_cfg_link "${SRC_MACROS}" "${ACTIVE_DST_MACROS}" "eddy_macros.cfg"
install_cfg_link "${SRC_WIZARD}" "${ACTIVE_DST_WIZARD}" "eddy_setup_wizard.cfg"

# ---------------------------------------------------------------------------
# Include management
# ---------------------------------------------------------------------------

printer_cfg_has_managed_block() {
    grep -Fq '# >>> Klipper Eddy Tap Wizard >>>' "${PRINTER_CFG}" \
        && grep -Fq '# <<< Klipper Eddy Tap Wizard <<<' "${PRINTER_CFG}"
}

rewrite_managed_block_for_eddy_cfg() {
    local tmp_cfg

    backup_path "${PRINTER_CFG}" "printer.cfg.before_eddy_include"
    tmp_cfg="$(mktemp)"

    awk '
        BEGIN {
            in_block=0
            inserted=0
        }

        $0 == "# >>> Klipper Eddy Tap Wizard >>>" {
            if (!inserted) {
                print "# >>> Klipper Eddy Tap Wizard >>>"
                print "[include eddy.cfg]"
                print "# <<< Klipper Eddy Tap Wizard <<<"
                inserted=1
            }
            in_block=1
            next
        }

        $0 == "# <<< Klipper Eddy Tap Wizard <<<" {
            in_block=0
            next
        }

        !in_block {
            print
        }
    ' "${PRINTER_CFG}" > "${tmp_cfg}"

    cat "${tmp_cfg}" > "${PRINTER_CFG}"
    rm -f -- "${tmp_cfg}"

    ok "Updated the installer-managed include block to [include eddy.cfg]."
}

remove_direct_wizard_includes_from_printer_cfg() {
    local tmp_cfg

    backup_path "${PRINTER_CFG}" "printer.cfg.before_direct_include_cleanup"
    tmp_cfg="$(mktemp)"

    sed -E \
        -e '/^[[:space:]]*\[include[[:space:]]+eddy_setup_wizard\.cfg\][[:space:]]*(#.*)?$/d' \
        -e '/^[[:space:]]*\[include[[:space:]]+eddy_macros\.cfg\][[:space:]]*(#.*)?$/d' \
        "${PRINTER_CFG}" > "${tmp_cfg}"

    cat "${tmp_cfg}" > "${PRINTER_CFG}"
    rm -f -- "${tmp_cfg}"

    ok "Removed direct Eddy Wizard include lines from printer.cfg."
}

prepend_managed_eddy_cfg_include() {
    local tmp_cfg

    backup_path "${PRINTER_CFG}" "printer.cfg.before_eddy_include"
    tmp_cfg="$(mktemp)"

    {
        printf '# >>> Klipper Eddy Tap Wizard >>>\n'
        printf '[include eddy.cfg]\n'
        printf '# <<< Klipper Eddy Tap Wizard <<<\n\n'
        cat "${PRINTER_CFG}"
    } > "${tmp_cfg}"

    cat "${tmp_cfg}" > "${PRINTER_CFG}"
    rm -f -- "${tmp_cfg}"

    ok "Added [include eddy.cfg] to the TOP of ${PRINTER_CFG}."
}

find_direct_wizard_include_files_excluding_eddy_cfg() {
    local file

    for file in "${ACTIVE_CFG_FILES[@]}"; do
        if [[ -e "${DST_EDDY}" || -L "${DST_EDDY}" ]]; then
            if [[ "$(readlink -f -- "${file}" 2>/dev/null || printf '%s' "${file}")" \
                == "$(readlink -f -- "${DST_EDDY}" 2>/dev/null || printf '%s' "${DST_EDDY}")" ]]; then
                continue
            fi
        fi

        if grep -Eq '^[[:space:]]*\[include[[:space:]]+(eddy_setup_wizard|eddy_macros)\.cfg\][[:space:]]*(#.*)?$' "${file}" 2>/dev/null; then
            printf '%s\n' "${file}"
        fi
    done
}

ensure_generated_eddy_include() {
    local -a duplicate_include_files=()
    local file
    local eddy_include_present=0
    local printer_has_direct=0

    rebuild_cfg_tree

    if cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy\.cfg\][[:space:]]*(#.*)?$'; then
        eddy_include_present=1
    fi

    # A generated eddy.cfg already includes eddy_setup_wizard.cfg and
    # eddy_macros.cfg. Any additional active direct includes would load those
    # files twice and can create duplicate macro/section errors.
    mapfile -t duplicate_include_files < <(find_direct_wizard_include_files_excluding_eddy_cfg)

    if (( ${#duplicate_include_files[@]} > 0 )); then
        for file in "${duplicate_include_files[@]}"; do
            if [[ "$(readlink -f -- "${file}" 2>/dev/null || printf '%s' "${file}")" \
                == "$(readlink -f -- "${PRINTER_CFG}" 2>/dev/null || printf '%s' "${PRINTER_CFG}")" ]]; then
                printer_has_direct=1
            else
                error "Direct wizard include found outside printer.cfg: ${file}"
                die "Remove/migrate that direct include before enabling eddy.cfg, otherwise Klipper may load duplicate macro sections."
            fi
        done
    fi

    if [[ "${printer_has_direct}" -eq 1 ]]; then
        if printer_cfg_has_managed_block; then
            rewrite_managed_block_for_eddy_cfg
            eddy_include_present=1
        else
            warn "Direct Eddy Wizard includes were found in printer.cfg."
            if ask_yes_no "Remove those direct includes and use [include eddy.cfg] instead?" "y"; then
                remove_direct_wizard_includes_from_printer_cfg
            else
                die "Cannot safely enable generated eddy.cfg while direct wizard includes remain active."
            fi
        fi
    fi

    if [[ "${eddy_include_present}" -eq 0 ]]; then
        if printer_cfg_has_managed_block; then
            rewrite_managed_block_for_eddy_cfg
        else
            prepend_managed_eddy_cfg_include
        fi
    else
        ok "[include eddy.cfg] already exists in the active config tree."
    fi

    rebuild_cfg_tree

    # Final guard: no active direct wizard include may remain outside the
    # generated eddy.cfg, because eddy.cfg already loads both files itself.
    mapfile -t duplicate_include_files < <(find_direct_wizard_include_files_excluding_eddy_cfg)
    if (( ${#duplicate_include_files[@]} > 0 )); then
        for file in "${duplicate_include_files[@]}"; do
            if [[ "$(readlink -f -- "${file}" 2>/dev/null || printf '%s' "${file}")" \
                == "$(readlink -f -- "${PRINTER_CFG}" 2>/dev/null || printf '%s' "${PRINTER_CFG}")" ]]; then
                warn "A direct Eddy Wizard include still remains in printer.cfg."
                if ask_yes_no "Remove remaining direct wizard include lines from printer.cfg?" "y"; then
                    remove_direct_wizard_includes_from_printer_cfg
                else
                    die "Generated eddy.cfg cannot be safely used with duplicate direct wizard includes."
                fi
            else
                error "Direct wizard include remains active outside eddy.cfg: ${file}"
                die "Remove that include before using generated eddy.cfg."
            fi
        done
        rebuild_cfg_tree
    fi
}

prepend_existing_eddy_cfg_include() {
    local tmp_cfg

    backup_path "${PRINTER_CFG}" "printer.cfg.before_existing_eddy_include"
    tmp_cfg="$(mktemp)"

    {
        printf '# >>> Klipper Eddy Tap Wizard Eddy Config >>>\n'
        printf '[include eddy.cfg]\n'
        printf '# <<< Klipper Eddy Tap Wizard Eddy Config <<<\n\n'
        cat "${PRINTER_CFG}"
    } > "${tmp_cfg}"

    cat "${tmp_cfg}" > "${PRINTER_CFG}"
    rm -f -- "${tmp_cfg}"

    ok "Activated the existing user-owned eddy.cfg without modifying its contents."
}

ensure_existing_eddy_file_include() {
    rebuild_cfg_tree

    if cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy\.cfg\][[:space:]]*(#.*)?$'; then
        ok "[include eddy.cfg] already exists in the active config tree."
    else
        prepend_existing_eddy_cfg_include
        rebuild_cfg_tree
    fi
}

ensure_direct_wizard_includes() {
    local wizard_present=0
    local macros_present=0
    local tmp_cfg

    rebuild_cfg_tree

    cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_setup_wizard\.cfg\][[:space:]]*(#.*)?$' \
        && wizard_present=1
    cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_macros\.cfg\][[:space:]]*(#.*)?$' \
        && macros_present=1

    if [[ "${wizard_present}" -eq 1 && "${macros_present}" -eq 1 ]]; then
        ok "Required direct Eddy Wizard includes already exist in the active config tree."
        return 0
    fi

    warn "One or more direct Eddy Wizard includes are missing."

    if ! ask_yes_no "Add the missing wizard include statements to the TOP of ${PRINTER_CFG}?" "y"; then
        die "Required wizard includes were not added."
    fi

    backup_path "${PRINTER_CFG}" "printer.cfg.before_eddy_wizard"
    tmp_cfg="$(mktemp)"

    {
        printf '# >>> Klipper Eddy Tap Wizard >>>\n'
        [[ "${wizard_present}" -eq 0 ]] && printf '[include eddy_setup_wizard.cfg]\n'
        [[ "${macros_present}" -eq 0 ]] && printf '[include eddy_macros.cfg]\n'
        printf '# <<< Klipper Eddy Tap Wizard <<<\n\n'
        cat "${PRINTER_CFG}"
    } > "${tmp_cfg}"

    cat "${tmp_cfg}" > "${PRINTER_CFG}"
    rm -f -- "${tmp_cfg}"

    ok "Added missing Eddy Wizard includes to the TOP of ${PRINTER_CFG}."
    rebuild_cfg_tree
}

ensure_clear_calibration_include() {
    local tmp_cfg

    [[ -f "${DST_CLEAR}" ]] \
        || die "Required Eddy clear-calibration config is missing: ${DST_CLEAR}"

    rebuild_cfg_tree

    # The file may already be loaded by a generated eddy.cfg template,
    # a user-owned eddy.cfg, or another valid include path.
    if path_is_active "${DST_CLEAR}"; then
        ok "eddy_clear_calibration.cfg is already active in the Klipper config tree."
        return 0
    fi

    info "Adding Eddy clear-calibration configuration to the active Klipper config tree..."

    backup_path "${PRINTER_CFG}" "printer.cfg.before_clear_calibration_include"
    tmp_cfg="$(mktemp)"

    {
        printf '# >>> Klipper Eddy Tap Wizard clear calibration >>>\n'
        printf '[include eddy_clear_calibration.cfg]\n'
        printf '# <<< Klipper Eddy Tap Wizard clear calibration <<<\n\n'
        cat "${PRINTER_CFG}"
    } > "${tmp_cfg}"

    cat "${tmp_cfg}" > "${PRINTER_CFG}"
    rm -f -- "${tmp_cfg}"

    rebuild_cfg_tree

    path_is_active "${DST_CLEAR}" \
        || die "eddy_clear_calibration.cfg was added to printer.cfg but did not become active."

    ok "Activated eddy_clear_calibration.cfg."
}

if [[ "${CONFIG_MODE}" == "generated" || "${CONFIG_MODE}" == "legacy_migrated" ]]; then
    [[ -f "${DST_EDDY}" ]] || die "Flat-layout installation selected but ${DST_EDDY} does not exist."
    ensure_generated_eddy_include
elif [[ "${CONFIG_MODE}" == "existing_eddy_file" ]]; then
    [[ -f "${DST_EDDY}" ]] || die "Existing-eddy-file mode selected but ${DST_EDDY} does not exist."
    ensure_existing_eddy_file_include
    # Because this was not generated from our template, do not assume it
    # contains the wizard includes. Ensure them independently.
    ensure_direct_wizard_includes
elif [[ "${CONFIG_MODE}" == "legacy_keep" ]]; then
    # The nested eddy.cfg already loads the nested Wizard files. Confirm that
    # they remain active, but do not rewrite any include paths.
    rebuild_cfg_tree
    path_is_active "${LEGACY_EDDY_CFG}"         || die "Legacy Eddy config unexpectedly became inactive."
    path_is_active "${LEGACY_WIZARD}"         || die "Legacy Eddy setup wizard unexpectedly became inactive."
    path_is_active "${LEGACY_MACROS}"         || die "Legacy Eddy macros unexpectedly became inactive."
    ok "Legacy nested Wizard include structure preserved."
else
    ensure_direct_wizard_includes
fi

# ---------------------------------------------------------------------------
# Ensure clear-calibration configuration is active
# ---------------------------------------------------------------------------

if [[ "${CONFIG_MODE}" != "legacy_keep" ]]; then
    ensure_clear_calibration_include
fi

# ---------------------------------------------------------------------------
# Require/confirm [bed_mesh] zero_reference_position
# ---------------------------------------------------------------------------

ensure_calibration_reference

# ---------------------------------------------------------------------------
# Detect/add [save_variables]
# ---------------------------------------------------------------------------

rebuild_cfg_tree

if cfg_tree_has_regex '^[[:space:]]*\[save_variables\][[:space:]]*(#.*)?$'; then
    ok "[save_variables] already exists in the active config tree."
else
    warn "No active [save_variables] section was found."

    if ask_yes_no "Add a [save_variables] section to ${PRINTER_CFG}?" "y"; then
        backup_path "${PRINTER_CFG}" "printer.cfg.before_save_variables"
        touch "${CONFIG_DIR}/saved_variables.cfg"

        tmp_cfg="$(mktemp)"

        if grep -Fq '# <<< Klipper Eddy Tap Wizard <<<' "${PRINTER_CFG}"; then
            awk '
                {
                    print
                    if ($0 == "# <<< Klipper Eddy Tap Wizard <<<" && !inserted) {
                        print ""
                        print "# >>> Klipper Eddy Tap Wizard save_variables >>>"
                        print "[save_variables]"
                        print "filename: ~/printer_data/config/saved_variables.cfg"
                        print "# <<< Klipper Eddy Tap Wizard save_variables <<<"
                        print ""
                        inserted=1
                    }
                }
            ' "${PRINTER_CFG}" > "${tmp_cfg}"
        else
            {
                cat <<'EOF'
# >>> Klipper Eddy Tap Wizard save_variables >>>
[save_variables]
filename: ~/printer_data/config/saved_variables.cfg
# <<< Klipper Eddy Tap Wizard save_variables <<<

EOF
                cat "${PRINTER_CFG}"
            } > "${tmp_cfg}"
        fi

        cat "${tmp_cfg}" > "${PRINTER_CFG}"
        rm -f -- "${tmp_cfg}"

        ok "Added [save_variables] above any SAVE_CONFIG block and ensured saved_variables.cfg exists."
        rebuild_cfg_tree
    else
        die "The wizard requires [save_variables]. Add one before running EDDY_SETUP."
    fi
fi

# ---------------------------------------------------------------------------
# Existing Eddy USB identity hint
# ---------------------------------------------------------------------------

existing_serial="$(find_active_mcu_eddy_serial || true)"
if [[ -n "${existing_serial}" ]]; then
    check_eddy_usb_identity "${existing_serial}"
fi

# ---------------------------------------------------------------------------
# Install/update required gcode_shell_command.py safely
# ---------------------------------------------------------------------------

printf '\n%sChecking Klipper gcode_shell_command.py...%s\n' "${BOLD}" "${RESET}"

mkdir -p "${STATE_DIR}"

src_gshell_hash="$(sha256sum "${SRC_GCODE_SHELL_COMMAND}" | awk '{print $1}')"
dst_gshell_hash=""
previous_gshell_hash=""

if [[ -f "${DST_GCODE_SHELL_COMMAND}" ]]; then
    dst_gshell_hash="$(sha256sum "${DST_GCODE_SHELL_COMMAND}" | awk '{print $1}')"
fi

if [[ -f "${GCODE_SHELL_HASH_FILE}" ]]; then
    previous_gshell_hash="$(tr -d '[:space:]' < "${GCODE_SHELL_HASH_FILE}")"
fi

if [[ -z "${dst_gshell_hash}" ]]; then
    # gcode_shell_command.py is not installed. Install it silently.
    info "Required gcode_shell_command.py was not found. Installing it automatically..."

    cp -a -- "${SRC_GCODE_SHELL_COMMAND}" "${DST_GCODE_SHELL_COMMAND}" \
        || die "Failed to install required gcode_shell_command.py."

    [[ -f "${DST_GCODE_SHELL_COMMAND}" ]] \
        || die "gcode_shell_command.py installation verification failed."

    printf '%s\n' "${src_gshell_hash}" > "${GCODE_SHELL_HASH_FILE}"

    ok "Installed required Klipper gcode_shell_command.py."

elif [[ "${dst_gshell_hash}" == "${src_gshell_hash}" ]]; then
    # Installed copy already matches our bundled version.
    printf '%s\n' "${src_gshell_hash}" > "${GCODE_SHELL_HASH_FILE}"

    ok "Klipper gcode_shell_command.py already matches the repository version."

elif [[ -n "${previous_gshell_hash}" && "${dst_gshell_hash}" == "${previous_gshell_hash}" ]]; then
    # We previously installed this exact copy and our bundled version changed.
    # Update it silently.
    info "A newer repository version of gcode_shell_command.py is available. Updating it automatically..."

    cp -a -- "${SRC_GCODE_SHELL_COMMAND}" "${DST_GCODE_SHELL_COMMAND}" \
        || die "Failed to update required gcode_shell_command.py."

    [[ -f "${DST_GCODE_SHELL_COMMAND}" ]] \
        || die "gcode_shell_command.py update verification failed."

    printf '%s\n' "${src_gshell_hash}" > "${GCODE_SHELL_HASH_FILE}"

    ok "Updated required Klipper gcode_shell_command.py."

else
    # An existing copy is present but it was not installed/managed by us.
    # Preserve it rather than overwriting another project's or user's copy.
    ok "Existing gcode_shell_command.py detected."
    info "The existing file is not managed by the Eddy Tap Wizard and will be preserved."
fi

# ---------------------------------------------------------------------------
# Install/update temperature_probe.py safely
# ---------------------------------------------------------------------------

printf '\n%sChecking Klipper temperature_probe.py...%s\n' "${BOLD}" "${RESET}"

mkdir -p "${STATE_DIR}"

src_temp_hash="$(sha256sum "${SRC_TEMP_PROBE}" | awk '{print $1}')"
dst_temp_hash=""
previous_managed_hash=""

if [[ -f "${DST_TEMP_PROBE}" || -L "${DST_TEMP_PROBE}" ]]; then
    dst_temp_hash="$(sha256sum "${DST_TEMP_PROBE}" | awk '{print $1}')"
fi

if [[ -f "${TEMP_HASH_FILE}" ]]; then
    previous_managed_hash="$(tr -d '[:space:]' < "${TEMP_HASH_FILE}")"
fi

installed_has_required_patch=0
if [[ -f "${DST_TEMP_PROBE}" ]] \
    && grep -Fq 'TAP_START_Z = 5.' "${DST_TEMP_PROBE}" \
    && grep -Fq 'tool_zero_z = mpresult.bed_z' "${DST_TEMP_PROBE}" \
    && grep -Fq 'curpos[2] = self.last_zero_pos + TAP_START_Z' "${DST_TEMP_PROBE}"; then
    installed_has_required_patch=1
fi

install_temp_probe_copy() {
    if [[ -e "${DST_TEMP_PROBE}" || -L "${DST_TEMP_PROBE}" ]]; then
        backup_path "${DST_TEMP_PROBE}" "temperature_probe.py.backup"
        rm -f -- "${DST_TEMP_PROBE}"
    fi

    cp -a -- "${SRC_TEMP_PROBE}" "${DST_TEMP_PROBE}"
    printf '%s\n' "${src_temp_hash}" > "${TEMP_HASH_FILE}"
    ok "Installed repository temperature_probe.py into Klipper."
}

if [[ "${dst_temp_hash}" == "${src_temp_hash}" && -n "${dst_temp_hash}" ]]; then
    printf '%s\n' "${src_temp_hash}" > "${TEMP_HASH_FILE}"
    ok "Klipper temperature_probe.py already matches the repository version."

elif [[ -n "${previous_managed_hash}" && "${dst_temp_hash}" == "${previous_managed_hash}" ]]; then
    info "The previously managed temperature_probe.py is unchanged locally."
    info "The repository version has changed; updating the managed copy."
    install_temp_probe_copy

elif [[ "${installed_has_required_patch}" -eq 1 ]]; then
    ok "Installed Klipper temperature_probe.py already contains the required Eddy Tap thermal behavior."
    warn "It differs from the repository copy, so it will be left untouched to avoid overwriting newer/upstream code."

    if ask_yes_no "Replace it with this repository's temperature_probe.py anyway?" "n"; then
        install_temp_probe_copy
    fi

else
    warn "Installed Klipper temperature_probe.py does not contain all required Eddy Tap thermal changes."

    if ask_yes_no "Back it up and install the repository's modified temperature_probe.py?" "y"; then
        install_temp_probe_copy
    else
        die "temperature_probe.py was not replaced. Thermal Eddy Tap calibration may not behave as expected."
    fi
fi

# Complete legacy cleanup only after the new flat files and include tree exist.
if [[ "${CONFIG_MODE}" == "legacy_migrated" ]]; then
    finalize_legacy_layout_migration         || die "Legacy migration could not be finalized safely. The legacy directory was left in place."
fi

# ---------------------------------------------------------------------------
# Final checks
# ---------------------------------------------------------------------------

rebuild_cfg_tree
scan_eddy_sections

printf '\n%sInstallation summary%s\n' "${BOLD}" "${RESET}"
printf '%s\n' "------------------------------------------------------------"

if [[ -L "${ACTIVE_DST_MACROS}" ]]; then
    ok "eddy_macros.cfg installed: ${ACTIVE_DST_MACROS}"
else
    warn "eddy_macros.cfg is not a symlink at ${ACTIVE_DST_MACROS}."
fi

if [[ -L "${ACTIVE_DST_WIZARD}" ]]; then
    ok "eddy_setup_wizard.cfg installed: ${ACTIVE_DST_WIZARD}"
else
    warn "eddy_setup_wizard.cfg is not a symlink at ${ACTIVE_DST_WIZARD}."
fi

if [[ "${CONFIG_MODE}" == "generated" ]]; then
    if [[ -f "${DST_EDDY}" ]]; then
        ok "User-owned eddy.cfg present: ${DST_EDDY}"
    else
        warn "Expected user-owned eddy.cfg is missing."
    fi

    if cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy\.cfg\][[:space:]]*(#.*)?$'; then
        ok "[include eddy.cfg] detected."
    else
        warn "[include eddy.cfg] was not detected."
    fi
elif [[ "${CONFIG_MODE}" == "legacy_migrated" ]]; then
    ok "Legacy nested Eddy Tap Wizard layout migrated to the flat config layout."
    ok "User-owned Eddy config: ${DST_EDDY}"

    if [[ ! -d "${LEGACY_EDDY_DIR}" ]]; then
        ok "Legacy config/eddy/ directory is no longer present."
    else
        warn "Legacy config/eddy/ directory still exists."
    fi

    if cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy\.cfg\][[:space:]]*(#.*)?$'; then
        ok "[include eddy.cfg] detected."
    else
        warn "[include eddy.cfg] was not detected."
    fi
elif [[ "${CONFIG_MODE}" == "legacy_keep" ]]; then
    ok "Legacy nested Eddy Tap Wizard layout preserved."
    ok "User-owned Eddy config: ${LEGACY_EDDY_CFG}"

    if path_is_active "${LEGACY_EDDY_CFG}" \
        && path_is_active "${LEGACY_WIZARD}" \
        && path_is_active "${LEGACY_MACROS}"; then
        ok "Legacy Eddy config, Wizard, and macros remain active."
    else
        warn "One or more legacy Eddy files are not active."
    fi
elif [[ "${CONFIG_MODE}" == "existing_eddy_file" ]]; then
    ok "Pre-existing user-owned eddy.cfg preserved and activated."

    if cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy\.cfg\][[:space:]]*(#.*)?$'; then
        ok "[include eddy.cfg] detected."
    else
        warn "[include eddy.cfg] was not detected."
    fi

    if cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_setup_wizard\.cfg\][[:space:]]*(#.*)?$' \
       && cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_macros\.cfg\][[:space:]]*(#.*)?$'; then
        ok "Wizard includes detected."
    else
        warn "Wizard includes are not both detectable."
    fi
else
    ok "Existing native Eddy configuration preserved in-place."

    if cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_setup_wizard\.cfg\][[:space:]]*(#.*)?$' \
       && cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_macros\.cfg\][[:space:]]*(#.*)?$'; then
        ok "Direct wizard includes detected."
    else
        warn "Direct wizard includes are not both detectable."
    fi
fi

scan_calibration_reference
if [[ "${BED_MESH_ZERO_VALID}" -eq 1 ]]; then
    ok "Required [bed_mesh] zero_reference_position detected: X${BED_MESH_ZERO_X} Y${BED_MESH_ZERO_Y}"
else
    warn "Required [bed_mesh] zero_reference_position was not detected."
fi

if cfg_tree_has_regex '^[[:space:]]*\[save_variables\][[:space:]]*(#.*)?$'; then
    ok "[save_variables] detected."
else
    warn "[save_variables] is still missing."
fi

if [[ -f "${DST_TEMP_PROBE}" ]] \
    && grep -Fq 'TAP_START_Z = 5.' "${DST_TEMP_PROBE}" \
    && grep -Fq 'tool_zero_z = mpresult.bed_z' "${DST_TEMP_PROBE}" \
    && grep -Fq 'curpos[2] = self.last_zero_pos + TAP_START_Z' "${DST_TEMP_PROBE}"; then
    ok "Required temperature_probe.py Eddy Tap thermal changes detected."
else
    warn "Required temperature_probe.py Eddy Tap thermal changes were not fully detected."
fi

if [[ "${CONFIG_MODE}" != "legacy_keep" ]]; then
    if [[ ! -f "${DST_CLEAR}" ]]; then
        die "Required eddy_clear_calibration.cfg is missing: ${DST_CLEAR}"
    elif grep -Fq '__EDDY_CLEAR_SCRIPT__' "${DST_CLEAR}"; then
        die "eddy_clear_calibration.cfg still contains an unresolved script-path placeholder."
    elif path_is_active "${DST_CLEAR}"; then
        ok "Required eddy_clear_calibration.cfg is active."
    else
        die "Required eddy_clear_calibration.cfg exists but is not active in the Klipper config tree."
    fi
fi

if [[ -f "${DST_GCODE_SHELL_COMMAND}" ]]; then
    ok "Required gcode_shell_command.py detected."
else
    die "Required gcode_shell_command.py is missing. EDDY_CLEAR_CALIBRATION cannot operate without it."
fi

if [[ "${EDDY_STATE}" == "conflict" || "${EDDY_STATE}" == "eddy_ng" ]]; then
    warn "Final Eddy discovery indicates an incompatible/conflicting configuration."
else
    ok "Final Eddy discovery did not find an Eddy-NG/native conflict."
fi

if [[ "${BACKUP_CREATED}" -eq 1 ]]; then
    info "Backups created in: ${BACKUP_DIR}"
fi

# ---------------------------------------------------------------------------
# Restart Klipper
# ---------------------------------------------------------------------------

if command -v systemctl >/dev/null 2>&1; then
    info "Restarting Klipper to load updated Python/config files..."

    if sudo systemctl restart klipper; then
        ok "Klipper restarted."
    else
        die "Klipper restart failed. Restart Klipper manually before using the Eddy Setup Wizard."
    fi
else
    die "systemctl was not found. Klipper must be restarted manually before using the Eddy Setup Wizard."
fi

printf '\n%sInstallation complete.%s\n' "${GREEN}${BOLD}" "${RESET}"
printf '\nRun the guided setup with:\n\n'
printf '  %sEDDY_SETUP%s\n\n' "${BOLD}" "${RESET}"
printf 'Future project updates can be applied with:\n\n'
printf '  cd %q\n' "${SCRIPT_DIR}"
printf '  ./install.sh --update\n\n'
