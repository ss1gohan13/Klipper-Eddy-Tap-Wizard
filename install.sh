#!/usr/bin/env bash
#
# Klipper Eddy Tap Wizard Installer
#
# This installer provides:
#   - active Klipper config-tree discovery
#   - native Eddy / BTT-style Eddy / Eddy-NG detection
#   - legacy nested Eddy Tap Wizard layout detection/migration
#   - legacy BIGTREETECH Klipper-fork warning
#   - Full / Minimal eddy.cfg template generation for fresh installs
#   - preservation of an existing user-owned eddy.cfg
#   - required [bed_mesh] zero_reference_position validation/setup
#   - [include eddy.cfg] management for generated configurations
#   - compatibility with existing mainline native Eddy configurations
#   - safe migration of the old installer-managed direct include block
#   - portable Eddy clear-calibration configuration management
#   - safe management of required Klipper Python extras
#   - an advisory Eddy USB firmware/identity check
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
CLEAR_CFG_HASH_FILE="${STATE_DIR}/eddy_clear_calibration.installed.sha256"
LEGACY_CLEAR_HASH_FILE="${STATE_DIR}/eddy_clear_calibration.legacy.installed.sha256"

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
    cat <<'EOF_USAGE'
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

Supported installation paths:
  - fresh mainline/native Eddy configuration using Full or Minimal templates
  - existing mainline/native [probe_eddy_current ...] configurations
  - previous Eddy Tap Wizard nested config/eddy/ layouts
  - USB or CAN Eddy connections for freshly generated eddy.cfg files

Unsupported configurations are detected and stopped before printer/Klipper
files are modified, including Eddy-NG and legacy BIGTREETECH/Rappetor-style
Eddy configurations.

The installer:
  - discovers the active Klipper config tree starting at printer.cfg
  - preserves an existing user-owned eddy.cfg during normal installs/updates
  - validates/prompts for the required [bed_mesh] zero_reference_position
  - installs/updates eddy_macros.cfg and eddy_setup_wizard.cfg as repo symlinks
  - renders and activates eddy_clear_calibration.cfg
  - checks/adds [save_variables] when required and none exists
  - safely manages the required gcode_shell_command.py dependency
  - safely manages the project's modified temperature_probe.py
  - creates backups before managed config/Python replacements
  - restarts Klipper after a successful installation
EOF_USAGE
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
command -v readlink >/dev/null 2>&1 || die "readlink is required but was not found."

[[ -d "${CONFIG_DIR}" ]] || die "Klipper config directory not found: ${CONFIG_DIR}"
[[ -f "${PRINTER_CFG}" ]] || die "printer.cfg not found: ${PRINTER_CFG}"

# In detect-only mode the repository payload does not need to be complete.
if [[ "${DETECT_ONLY}" -eq 0 ]]; then
    command -v mktemp >/dev/null 2>&1 || die "mktemp is required but was not found."
    [[ -x /usr/bin/python3 ]] || die "/usr/bin/python3 is required by the Eddy clear-calibration helper."
    [[ -d "${KLIPPER_EXTRAS_DIR}" ]] || die "Klipper extras directory not found: ${KLIPPER_EXTRAS_DIR}"

    [[ -f "${SRC_MACROS}" ]] || die "Repository file missing: ${SRC_MACROS}"
    [[ -f "${SRC_WIZARD}" ]] || die "Repository file missing: ${SRC_WIZARD}"
    [[ -f "${SRC_TEMPLATE_FULL}" ]] || die "Repository file missing: ${SRC_TEMPLATE_FULL}"
    [[ -f "${SRC_TEMPLATE_MINIMAL}" ]] || die "Repository file missing: ${SRC_TEMPLATE_MINIMAL}"
    [[ -f "${SRC_CLEAR_TEMPLATE}" ]] || die "Repository file missing: ${SRC_CLEAR_TEMPLATE}"
    [[ -f "${SRC_CLEAR_SCRIPT}" ]] || die "Repository file missing: ${SRC_CLEAR_SCRIPT}"
    [[ -f "${SRC_TEMP_PROBE}" ]] || die "Repository file missing: ${SRC_TEMP_PROBE}"
    [[ -f "${SRC_GCODE_SHELL_COMMAND}" ]] || die "Repository file missing: ${SRC_GCODE_SHELL_COMMAND}"

    # Validate the core repository payload before modifying the user's install.
    for template in "${SRC_TEMPLATE_FULL}" "${SRC_TEMPLATE_MINIMAL}"; do
        grep -Eq '^[[:space:]]*\[include[[:space:]]+eddy_setup_wizard\.cfg\]' "${template}" \
            || die "Repository template is missing [include eddy_setup_wizard.cfg]: ${template}"
        grep -Eq '^[[:space:]]*\[include[[:space:]]+eddy_macros\.cfg\]' "${template}" \
            || die "Repository template is missing [include eddy_macros.cfg]: ${template}"
        grep -Eq '^[[:space:]]*\[include[[:space:]]+eddy_clear_calibration\.cfg\]' "${template}" \
            || die "Repository template is missing [include eddy_clear_calibration.cfg]: ${template}"
    done

    grep -Fq '__EDDY_CLEAR_SCRIPT__' "${SRC_CLEAR_TEMPLATE}" \
        || die "Repository clear-calibration template is missing __EDDY_CLEAR_SCRIPT__."
    grep -Fq 'RUN_SHELL_COMMAND' "${SRC_GCODE_SHELL_COMMAND}" \
        || die "Repository gcode_shell_command.py does not provide RUN_SHELL_COMMAND."
    grep -Fq 'def load_config_prefix' "${SRC_GCODE_SHELL_COMMAND}" \
        || die "Repository gcode_shell_command.py is missing load_config_prefix()."
    grep -Fq '"--probe"' "${SRC_CLEAR_SCRIPT}" \
        || die "Repository clear_eddy_calibration.py is missing its required --probe argument."

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

    # temperature_probe calibration_position may contain a third coordinate;
    # only X/Y are needed for the zero-reference recommendation.
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
    local record

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
        if [[ -z "${default_x}" || -z "${default_y}" ]]; then
            default_x="${TEMP_CAL_RECOMMEND_X}"
            default_y="${TEMP_CAL_RECOMMEND_Y}"
        fi
    fi

    if [[ "${FRESH_EDDY_CFG_GENERATED}" -eq 1 && "${BED_MESH_ZERO_VALID}" -eq 1 ]]; then
        ok "Fresh template already contains the confirmed zero reference position."
        return 0
    fi

    if [[ "${AFTER_PULL}" -eq 1 && "${BED_MESH_ZERO_VALID}" -eq 1 ]]; then
        ok "Update mode: preserving existing zero_reference_position."
        return 0
    fi

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

# Incompatible Eddy states stop before any printer/Klipper files are modified.
case "${EDDY_STATE}" in
    btt_native)
        printf '\n'
        warn "A legacy BIGTREETECH/Rappetor-style Eddy configuration was detected."
        warn "This configuration is not currently supported by the Klipper Eddy Tap Wizard."
        warn "Automatic conversion to the required native Eddy Tap configuration is not currently supported."
        warn "No printer configuration or Klipper files have been changed."
        exit 0
        ;;
    eddy_ng)
        printf '\n'
        warn "The Eddy Tap Wizard requires Klipper's native [probe_eddy_current] implementation."
        warn "Automatic Eddy-NG migration is not currently supported."
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

# A legacy BIGTREETECH Klipper fork may still be paired with a non-BTT-style
# native Eddy config. Require an explicit opt-in before continuing in that case.
if [[ "${LEGACY_BTT_KLIPPER}" -eq 1 ]]; then
    warn "The Eddy Tap Wizard should be installed against mainline Klipper."
    if ! ask_yes_no "Continue anyway despite the detected BIGTREETECH Klipper fork?" "n"; then
        die "Installation stopped. Migrate Klipper to mainline and rerun the installer."
    fi
fi

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
    local dst_clear="${1:-${DST_CLEAR}}"
    local hash_file="${2:-${CLEAR_CFG_HASH_FILE}}"
    local tmp_clear
    local escaped_script
    local desired_hash=""
    local existing_hash=""
    local previous_hash=""
    local backup_label=""

    printf '\n%sPreparing Eddy clear-calibration configuration...%s\n' "${BOLD}" "${RESET}"

    mkdir -p "${STATE_DIR}"
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

    desired_hash="$(sha256sum "${tmp_clear}" | awk '{print $1}')"

    if [[ -f "${hash_file}" ]]; then
        previous_hash="$(tr -d '[:space:]' < "${hash_file}")"
    fi

    if [[ -L "${dst_clear}" ]]; then
        if grep -Fq '__EDDY_CLEAR_SCRIPT__' "${dst_clear}" 2>/dev/null; then
            rm -f -- "${tmp_clear}"
            die "Existing ${dst_clear} still contains the unresolved __EDDY_CLEAR_SCRIPT__ placeholder."
        fi

        rm -f -- "${hash_file}"
        rm -f -- "${tmp_clear}"

        warn "Existing eddy_clear_calibration.cfg is a symlink and will be preserved."
        info "The symlink is not managed by the Eddy Tap Wizard."
        return 0
    fi

    if [[ ! -e "${dst_clear}" ]]; then
        cp -- "${tmp_clear}" "${dst_clear}" \
            || {
                rm -f -- "${tmp_clear}"
                die "Failed to install rendered eddy_clear_calibration.cfg."
            }

        chmod 0644 "${dst_clear}" 2>/dev/null || true
        printf '%s\n' "${desired_hash}" > "${hash_file}"
        rm -f -- "${tmp_clear}"

        [[ -f "${dst_clear}" ]] \
            || die "eddy_clear_calibration.cfg installation verification failed."

        ok "Generated Eddy clear-calibration configuration: ${dst_clear}"
        return 0
    fi

    [[ -f "${dst_clear}" ]] \
        || {
            rm -f -- "${tmp_clear}"
            die "Existing clear-calibration path is not a regular file: ${dst_clear}"
        }

    if grep -Fq '__EDDY_CLEAR_SCRIPT__' "${dst_clear}"; then
        rm -f -- "${tmp_clear}"
        die "Existing ${dst_clear} still contains the unresolved __EDDY_CLEAR_SCRIPT__ placeholder."
    fi

    existing_hash="$(sha256sum "${dst_clear}" | awk '{print $1}')"

    if [[ "${existing_hash}" == "${desired_hash}" ]]; then
        printf '%s\n' "${desired_hash}" > "${hash_file}"
        rm -f -- "${tmp_clear}"

        ok "eddy_clear_calibration.cfg already matches the repository version."
        return 0
    fi

    if [[ -n "${previous_hash}" && "${existing_hash}" == "${previous_hash}" ]]; then
        if [[ "${dst_clear}" == "${LEGACY_CLEAR}" ]]; then
            backup_label="eddy_clear_calibration.cfg.before_managed_update.legacy"
        else
            backup_label="eddy_clear_calibration.cfg.before_managed_update"
        fi

        backup_path "${dst_clear}" "${backup_label}"

        cp -- "${tmp_clear}" "${dst_clear}" \
            || {
                rm -f -- "${tmp_clear}"
                die "Failed to update managed eddy_clear_calibration.cfg."
            }

        chmod 0644 "${dst_clear}" 2>/dev/null || true

        existing_hash="$(sha256sum "${dst_clear}" | awk '{print $1}')"
        if [[ "${existing_hash}" != "${desired_hash}" ]]; then
            rm -f -- "${tmp_clear}"
            die "eddy_clear_calibration.cfg update verification failed."
        fi

        printf '%s\n' "${desired_hash}" > "${hash_file}"
        rm -f -- "${tmp_clear}"

        ok "Updated managed eddy_clear_calibration.cfg."
        return 0
    fi

    rm -f -- "${hash_file}"
    rm -f -- "${tmp_clear}"

    warn "Existing eddy_clear_calibration.cfg differs from the repository version."
    info "The file is not currently managed by the Eddy Tap Wizard and will be preserved."
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

    # Verify that exactly the selected transport is active after rendering.
    if [[ "${connection_choice}" -eq 1 ]]; then
        grep -Fq "serial: ${serial_value}" "${tmp_cfg}" \
            || {
                rm -f -- "${tmp_cfg}"
                die "Generated USB eddy.cfg does not contain the requested serial path."
            }
        if grep -Eq '^[[:space:]]*canbus_uuid[[:space:]]*:' "${tmp_cfg}"; then
            rm -f -- "${tmp_cfg}"
            die "Generated USB eddy.cfg unexpectedly contains an active canbus_uuid."
        fi
    else
        grep -Fq "canbus_uuid: ${can_uuid}" "${tmp_cfg}" \
            || {
                rm -f -- "${tmp_cfg}"
                die "Generated CAN eddy.cfg does not contain the requested CAN UUID."
            }
        if grep -Eq '^[[:space:]]*serial[[:space:]]*:' "${tmp_cfg}"; then
            rm -f -- "${tmp_cfg}"
            die "Generated CAN eddy.cfg unexpectedly contains an active serial path."
        fi
    fi

    if [[ -e "${DST_EDDY}" || -L "${DST_EDDY}" ]]; then
        rm -f -- "${tmp_cfg}"
        die "${DST_EDDY} appeared during generation. It will not be overwritten."
    fi

    cp -- "${tmp_cfg}" "${DST_EDDY}"
    chmod 0644 "${DST_EDDY}" 2>/dev/null || true
    rm -f -- "${tmp_cfg}"

    [[ -f "${DST_EDDY}" ]] || die "Generated eddy.cfg could not be verified after installation."

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

    if [[ -e "${DST_CLEAR}" || -L "${DST_CLEAR}" ]]; then
        die "Cannot migrate automatically because ${DST_CLEAR} already exists. It will not be overwritten."
    fi

    # eddy.cfg is user-owned. Do not silently dereference a custom symlink and
    # turn it into a regular file during automatic migration.
    if [[ -L "${LEGACY_EDDY_CFG}" ]]; then
        warn "The legacy eddy.cfg is a symlink."
        die "Automatic migration cannot safely preserve a symlinked legacy eddy.cfg. Keep the legacy layout or replace the symlink with a regular file before migrating."
    fi

    if [[ -L "${LEGACY_CLEAR}" ]]; then
        warn "The legacy eddy_clear_calibration.cfg is a symlink."
        die "Automatic migration cannot safely preserve a symlinked legacy clear-calibration config. Keep the legacy layout or replace the symlink with a regular file before migrating."
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
        die "Automatic migration only supports legacy includes located directly in printer.cfg. Keep the existing layout for now."
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

    backup_path "${LEGACY_EDDY_DIR}" "legacy_eddy_directory"

    tmp_cfg="$(mktemp)"
    cp -- "${LEGACY_EDDY_CFG}" "${tmp_cfg}"

    if grep -nE '^[[:space:]]*[^#[:space:]].*\{\{[A-Z0-9_]+\}\}' "${tmp_cfg}" >/dev/null 2>&1; then
        rm -f -- "${tmp_cfg}"
        die "Legacy eddy.cfg unexpectedly contains unresolved active template placeholders. Migration stopped."
    fi

    cp -- "${tmp_cfg}" "${DST_EDDY}"
    chmod 0644 "${DST_EDDY}" 2>/dev/null || true
    rm -f -- "${tmp_cfg}"

    ok "Copied user-owned Eddy configuration to: ${DST_EDDY}"

    # Preserve an existing legacy clear-calibration config and transfer its
    # ownership record so the normal renderer can classify it safely.
    if [[ -e "${LEGACY_CLEAR}" ]]; then
        cp -- "${LEGACY_CLEAR}" "${DST_CLEAR}" \
            || die "Failed to migrate legacy eddy_clear_calibration.cfg."
        chmod 0644 "${DST_CLEAR}" 2>/dev/null || true

        if [[ -f "${LEGACY_CLEAR_HASH_FILE}" ]]; then
            mkdir -p "${STATE_DIR}"
            cp -- "${LEGACY_CLEAR_HASH_FILE}" "${CLEAR_CFG_HASH_FILE}" \
                || die "Failed to transfer clear-calibration ownership state."
        else
            rm -f -- "${CLEAR_CFG_HASH_FILE}"
        fi

        ok "Migrated legacy eddy_clear_calibration.cfg to: ${DST_CLEAR}"
    fi

    rewrite_legacy_include_to_flat

    LEGACY_MIGRATION_CLEANUP_PENDING=1
    CONFIG_MODE="legacy_migrated"

    # The old directory remains in place until the new flat configuration,
    # symlinks, and active include tree have all been validated.
    rebuild_cfg_tree
}

finalize_legacy_layout_migration() {
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
        || path_is_active "${LEGACY_WIZARD}" \
        || path_is_active "${LEGACY_CLEAR}"; then
        warn "One or more legacy nested Eddy files are still active. The legacy directory will NOT be removed."
        return 1
    fi

    if [[ -d "${LEGACY_EDDY_DIR}" ]]; then
        rm -rf -- "${LEGACY_EDDY_DIR}"
        ok "Removed the inactive legacy directory: ${LEGACY_EDDY_DIR}"
        info "A complete copy is preserved in: ${BACKUP_DIR}/legacy_eddy_directory"
    fi

    rm -f -- "${LEGACY_CLEAR_HASH_FILE}"
    LEGACY_MIGRATION_CLEANUP_PENDING=0
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

if [[ "${CONFIG_MODE}" == "legacy_keep" ]]; then
    render_clear_calibration_cfg "${LEGACY_CLEAR}" "${LEGACY_CLEAR_HASH_FILE}"
else
    render_clear_calibration_cfg "${DST_CLEAR}" "${CLEAR_CFG_HASH_FILE}"
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

    [[ -L "${dst}" ]] || die "Failed to install ${label} symlink: ${dst}"
    [[ "$(readlink -f -- "${dst}" 2>/dev/null || true)" == "$(readlink -f -- "${src}")" ]] \
        || die "Installed ${label} symlink does not point to the expected repository file."

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

ensure_legacy_clear_calibration_include() {
    local tmp_cfg

    [[ -f "${LEGACY_CLEAR}" ]] \
        || die "Required legacy Eddy clear-calibration config is missing: ${LEGACY_CLEAR}"

    rebuild_cfg_tree

    if path_is_active "${LEGACY_CLEAR}"; then
        ok "Legacy eddy_clear_calibration.cfg is already active in the Klipper config tree."
        return 0
    fi

    info "Adding clear-calibration support to the legacy Eddy configuration..."

    backup_path "${LEGACY_EDDY_CFG}" "eddy.cfg.before_clear_calibration_include"
    tmp_cfg="$(mktemp)"

    {
        printf '# >>> Klipper Eddy Tap Wizard clear calibration >>>\n'
        printf '[include eddy_clear_calibration.cfg]\n'
        printf '# <<< Klipper Eddy Tap Wizard clear calibration <<<\n\n'
        cat "${LEGACY_EDDY_CFG}"
    } > "${tmp_cfg}"

    cat "${tmp_cfg}" > "${LEGACY_EDDY_CFG}"
    rm -f -- "${tmp_cfg}"

    rebuild_cfg_tree

    path_is_active "${LEGACY_CLEAR}" \
        || die "Legacy eddy_clear_calibration.cfg was added but did not become active."

    ok "Activated legacy eddy_clear_calibration.cfg."
}

if [[ "${CONFIG_MODE}" == "generated" || "${CONFIG_MODE}" == "legacy_migrated" ]]; then
    [[ -f "${DST_EDDY}" ]] || die "Flat-layout installation selected but ${DST_EDDY} does not exist."
    ensure_generated_eddy_include
elif [[ "${CONFIG_MODE}" == "existing_eddy_file" ]]; then
    [[ -f "${DST_EDDY}" ]] || die "Existing-eddy-file mode selected but ${DST_EDDY} does not exist."
    ensure_existing_eddy_file_include
    ensure_direct_wizard_includes
elif [[ "${CONFIG_MODE}" == "legacy_keep" ]]; then
    rebuild_cfg_tree
    path_is_active "${LEGACY_EDDY_CFG}" \
        || die "Legacy Eddy config unexpectedly became inactive."
    path_is_active "${LEGACY_WIZARD}" \
        || die "Legacy Eddy setup wizard unexpectedly became inactive."
    path_is_active "${LEGACY_MACROS}" \
        || die "Legacy Eddy macros unexpectedly became inactive."
    ok "Legacy nested Wizard include structure preserved."
else
    ensure_direct_wizard_includes
fi

# ---------------------------------------------------------------------------
# Ensure clear-calibration configuration is active
# ---------------------------------------------------------------------------

if [[ "${CONFIG_MODE}" == "legacy_keep" ]]; then
    ensure_legacy_clear_calibration_include
else
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
            awk -v save_file="${CONFIG_DIR}/saved_variables.cfg" '
                {
                    print
                    if ($0 == "# <<< Klipper Eddy Tap Wizard <<<" && !inserted) {
                        print ""
                        print "# >>> Klipper Eddy Tap Wizard save_variables >>>"
                        print "[save_variables]"
                        print "filename: " save_file
                        print "# <<< Klipper Eddy Tap Wizard save_variables <<<"
                        print ""
                        inserted=1
                    }
                }
            ' "${PRINTER_CFG}" > "${tmp_cfg}"
        else
            {
                printf '# >>> Klipper Eddy Tap Wizard save_variables >>>\n'
                printf '[save_variables]\n'
                printf 'filename: %s/saved_variables.cfg\n' "${CONFIG_DIR}"
                printf '# <<< Klipper Eddy Tap Wizard save_variables <<<\n\n'
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

# Preserve user/foreign symlinks rather than silently taking ownership of the
# file they point to. The target must still expose the required Klipper command.
if [[ -L "${DST_GCODE_SHELL_COMMAND}" ]]; then
    rm -f -- "${GCODE_SHELL_HASH_FILE}"

    if [[ ! -f "${DST_GCODE_SHELL_COMMAND}" ]]; then
        die "Existing gcode_shell_command.py symlink is broken: ${DST_GCODE_SHELL_COMMAND}"
    fi

    grep -Fq 'RUN_SHELL_COMMAND' "${DST_GCODE_SHELL_COMMAND}" \
        || die "Existing symlinked gcode_shell_command.py does not provide RUN_SHELL_COMMAND."
    grep -Fq 'def load_config_prefix' "${DST_GCODE_SHELL_COMMAND}" \
        || die "Existing symlinked gcode_shell_command.py does not provide load_config_prefix()."

    ok "Existing gcode_shell_command.py symlink detected."
    info "The symlink is not managed by the Eddy Tap Wizard and will be preserved."

elif [[ -e "${DST_GCODE_SHELL_COMMAND}" && ! -f "${DST_GCODE_SHELL_COMMAND}" ]]; then
    die "Existing gcode_shell_command.py path is not a regular file: ${DST_GCODE_SHELL_COMMAND}"

else
    if [[ -f "${DST_GCODE_SHELL_COMMAND}" ]]; then
        dst_gshell_hash="$(sha256sum "${DST_GCODE_SHELL_COMMAND}" | awk '{print $1}')"
    fi

    if [[ -f "${GCODE_SHELL_HASH_FILE}" ]]; then
        previous_gshell_hash="$(tr -d '[:space:]' < "${GCODE_SHELL_HASH_FILE}")"
    fi

    if [[ -z "${dst_gshell_hash}" ]]; then
        info "Required gcode_shell_command.py was not found. Installing it automatically..."

        cp -a -- "${SRC_GCODE_SHELL_COMMAND}" "${DST_GCODE_SHELL_COMMAND}" \
            || die "Failed to install required gcode_shell_command.py."

        [[ -f "${DST_GCODE_SHELL_COMMAND}" ]] \
            || die "gcode_shell_command.py installation verification failed."

        printf '%s\n' "${src_gshell_hash}" > "${GCODE_SHELL_HASH_FILE}"
        ok "Installed required Klipper gcode_shell_command.py."

    elif [[ "${dst_gshell_hash}" == "${src_gshell_hash}" ]]; then
        printf '%s\n' "${src_gshell_hash}" > "${GCODE_SHELL_HASH_FILE}"
        ok "Klipper gcode_shell_command.py already matches the repository version."

    elif [[ -n "${previous_gshell_hash}" && "${dst_gshell_hash}" == "${previous_gshell_hash}" ]]; then
        info "A newer repository version of gcode_shell_command.py is available. Updating it automatically..."

        cp -a -- "${SRC_GCODE_SHELL_COMMAND}" "${DST_GCODE_SHELL_COMMAND}" \
            || die "Failed to update required gcode_shell_command.py."

        [[ -f "${DST_GCODE_SHELL_COMMAND}" ]] \
            || die "gcode_shell_command.py update verification failed."

        dst_gshell_hash="$(sha256sum "${DST_GCODE_SHELL_COMMAND}" | awk '{print $1}')"
        [[ "${dst_gshell_hash}" == "${src_gshell_hash}" ]] \
            || die "gcode_shell_command.py update hash verification failed."

        printf '%s\n' "${src_gshell_hash}" > "${GCODE_SHELL_HASH_FILE}"
        ok "Updated required Klipper gcode_shell_command.py."

    else
        rm -f -- "${GCODE_SHELL_HASH_FILE}"
        ok "Existing gcode_shell_command.py detected."
        info "The existing file is not managed by the Eddy Tap Wizard and will be preserved."
    fi
fi

# ---------------------------------------------------------------------------
# Install/update temperature_probe.py safely
# ---------------------------------------------------------------------------

printf '\n%sChecking Klipper temperature_probe.py...%s\n' "${BOLD}" "${RESET}"

mkdir -p "${STATE_DIR}"

src_temp_hash="$(sha256sum "${SRC_TEMP_PROBE}" | awk '{print $1}')"
dst_temp_hash=""
previous_managed_hash=""
installed_has_required_patch=0

# A symlink is treated as externally managed. Preserve it if its target already
# contains the required Eddy Tap behavior; otherwise stop without replacing it.
if [[ -L "${DST_TEMP_PROBE}" ]]; then
    rm -f -- "${TEMP_HASH_FILE}"

    if [[ -f "${DST_TEMP_PROBE}" ]] \
        && grep -Fq 'TAP_START_Z = 5.' "${DST_TEMP_PROBE}" \
        && grep -Fq 'tool_zero_z = mpresult.bed_z' "${DST_TEMP_PROBE}" \
        && grep -Fq 'curpos[2] = self.last_zero_pos + TAP_START_Z' "${DST_TEMP_PROBE}"; then
        ok "Symlinked temperature_probe.py already contains the required Eddy Tap thermal behavior."
        info "The symlink is externally managed and will be preserved."
    else
        die "temperature_probe.py is a symlink whose target does not contain the required Eddy Tap changes. Replace/update the symlink target manually, then rerun the installer."
    fi

else
    if [[ -e "${DST_TEMP_PROBE}" && ! -f "${DST_TEMP_PROBE}" ]]; then
        die "Existing temperature_probe.py path is not a regular file: ${DST_TEMP_PROBE}"
    fi

    if [[ -f "${DST_TEMP_PROBE}" ]]; then
        dst_temp_hash="$(sha256sum "${DST_TEMP_PROBE}" | awk '{print $1}')"
    fi

    if [[ -f "${TEMP_HASH_FILE}" ]]; then
        previous_managed_hash="$(tr -d '[:space:]' < "${TEMP_HASH_FILE}")"
    fi

    if [[ -f "${DST_TEMP_PROBE}" ]] \
        && grep -Fq 'TAP_START_Z = 5.' "${DST_TEMP_PROBE}" \
        && grep -Fq 'tool_zero_z = mpresult.bed_z' "${DST_TEMP_PROBE}" \
        && grep -Fq 'curpos[2] = self.last_zero_pos + TAP_START_Z' "${DST_TEMP_PROBE}"; then
        installed_has_required_patch=1
    fi

    install_temp_probe_copy() {
        if [[ -e "${DST_TEMP_PROBE}" ]]; then
            backup_path "${DST_TEMP_PROBE}" "temperature_probe.py.backup"
            rm -f -- "${DST_TEMP_PROBE}"
        fi

        cp -a -- "${SRC_TEMP_PROBE}" "${DST_TEMP_PROBE}"

        local installed_hash
        installed_hash="$(sha256sum "${DST_TEMP_PROBE}" | awk '{print $1}')"
        [[ "${installed_hash}" == "${src_temp_hash}" ]] \
            || die "temperature_probe.py installation hash verification failed."

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
        rm -f -- "${TEMP_HASH_FILE}"
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
fi

# Complete legacy cleanup only after the new flat files and include tree exist.
if [[ "${CONFIG_MODE}" == "legacy_migrated" ]]; then
    finalize_legacy_layout_migration \
        || die "Legacy migration could not be finalized safely. The legacy directory was left in place."
fi

# ---------------------------------------------------------------------------
# Final checks
# ---------------------------------------------------------------------------

symlink_points_to() {
    local link_path="$1"
    local source_path="$2"

    [[ -L "${link_path}" ]] || return 1
    [[ "$(readlink -f -- "${link_path}" 2>/dev/null || true)" \
        == "$(readlink -f -- "${source_path}" 2>/dev/null || true)" ]]
}

rebuild_cfg_tree
scan_eddy_sections

printf '\n%sInstallation summary%s\n' "${BOLD}" "${RESET}"
printf '%s\n' "------------------------------------------------------------"

# Repo-managed config links must exist and point at the expected repository files.
symlink_points_to "${ACTIVE_DST_MACROS}" "${SRC_MACROS}" \
    || die "eddy_macros.cfg is not linked to the expected repository file: ${ACTIVE_DST_MACROS}"
ok "eddy_macros.cfg installed: ${ACTIVE_DST_MACROS}"

symlink_points_to "${ACTIVE_DST_WIZARD}" "${SRC_WIZARD}" \
    || die "eddy_setup_wizard.cfg is not linked to the expected repository file: ${ACTIVE_DST_WIZARD}"
ok "eddy_setup_wizard.cfg installed: ${ACTIVE_DST_WIZARD}"

if [[ "${CONFIG_MODE}" == "generated" ]]; then
    [[ -f "${DST_EDDY}" ]] \
        || die "Expected user-owned eddy.cfg is missing: ${DST_EDDY}"
    ok "User-owned eddy.cfg present: ${DST_EDDY}"

    cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy\.cfg\][[:space:]]*(#.*)?$' \
        || die "[include eddy.cfg] was not detected after installation."
    ok "[include eddy.cfg] detected."

elif [[ "${CONFIG_MODE}" == "legacy_migrated" ]]; then
    ok "Legacy nested Eddy Tap Wizard layout migrated to the flat config layout."
    [[ -f "${DST_EDDY}" ]] || die "Migrated user-owned Eddy config is missing: ${DST_EDDY}"
    ok "User-owned Eddy config: ${DST_EDDY}"

    [[ ! -d "${LEGACY_EDDY_DIR}" ]] \
        || die "Legacy config/eddy/ directory still exists after migration finalization."
    ok "Legacy config/eddy/ directory is no longer present."

    cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy\.cfg\][[:space:]]*(#.*)?$' \
        || die "[include eddy.cfg] was not detected after legacy migration."
    ok "[include eddy.cfg] detected."

elif [[ "${CONFIG_MODE}" == "legacy_keep" ]]; then
    ok "Legacy nested Eddy Tap Wizard layout preserved."
    ok "User-owned Eddy config: ${LEGACY_EDDY_CFG}"

    path_is_active "${LEGACY_EDDY_CFG}" \
        || die "Legacy Eddy config is not active."
    path_is_active "${LEGACY_WIZARD}" \
        || die "Legacy Eddy setup wizard is not active."
    path_is_active "${LEGACY_MACROS}" \
        || die "Legacy Eddy macros are not active."
    ok "Legacy Eddy config, Wizard, and macros remain active."

elif [[ "${CONFIG_MODE}" == "existing_eddy_file" ]]; then
    ok "Pre-existing user-owned eddy.cfg preserved and activated."

    cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy\.cfg\][[:space:]]*(#.*)?$' \
        || die "[include eddy.cfg] was not detected for the existing user-owned Eddy config."
    ok "[include eddy.cfg] detected."

    if cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_setup_wizard\.cfg\][[:space:]]*(#.*)?$' \
       && cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_macros\.cfg\][[:space:]]*(#.*)?$'; then
        ok "Wizard includes detected."
    else
        die "Wizard includes are not both active for the existing user-owned Eddy config."
    fi

else
    ok "Existing native Eddy configuration preserved in-place."

    if cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_setup_wizard\.cfg\][[:space:]]*(#.*)?$' \
       && cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_macros\.cfg\][[:space:]]*(#.*)?$'; then
        ok "Direct wizard includes detected."
    else
        die "Direct wizard includes are not both active for the existing native Eddy configuration."
    fi
fi

scan_calibration_reference
if [[ "${BED_MESH_ZERO_VALID}" -eq 1 ]]; then
    ok "Required [bed_mesh] zero_reference_position detected: X${BED_MESH_ZERO_X} Y${BED_MESH_ZERO_Y}"
else
    die "Required [bed_mesh] zero_reference_position was not detected during final verification."
fi

if cfg_tree_has_regex '^[[:space:]]*\[save_variables\][[:space:]]*(#.*)?$'; then
    ok "[save_variables] detected."
else
    die "[save_variables] is missing during final verification."
fi

if [[ -f "${DST_TEMP_PROBE}" ]] \
    && grep -Fq 'TAP_START_Z = 5.' "${DST_TEMP_PROBE}" \
    && grep -Fq 'tool_zero_z = mpresult.bed_z' "${DST_TEMP_PROBE}" \
    && grep -Fq 'curpos[2] = self.last_zero_pos + TAP_START_Z' "${DST_TEMP_PROBE}"; then
    ok "Required temperature_probe.py Eddy Tap thermal changes detected."
else
    die "Required temperature_probe.py Eddy Tap thermal changes were not fully detected."
fi

if [[ "${CONFIG_MODE}" == "legacy_keep" ]]; then
    if [[ ! -f "${LEGACY_CLEAR}" ]]; then
        die "Required legacy eddy_clear_calibration.cfg is missing: ${LEGACY_CLEAR}"
    elif grep -Fq '__EDDY_CLEAR_SCRIPT__' "${LEGACY_CLEAR}"; then
        die "Legacy eddy_clear_calibration.cfg still contains an unresolved script-path placeholder."
    elif path_is_active "${LEGACY_CLEAR}"; then
        ok "Required legacy eddy_clear_calibration.cfg is active."
    else
        die "Required legacy eddy_clear_calibration.cfg exists but is not active in the Klipper config tree."
    fi
else
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

if [[ -f "${DST_GCODE_SHELL_COMMAND}" ]] \
    && grep -Fq 'RUN_SHELL_COMMAND' "${DST_GCODE_SHELL_COMMAND}" \
    && grep -Fq 'def load_config_prefix' "${DST_GCODE_SHELL_COMMAND}"; then
    ok "Required gcode_shell_command.py capability detected."
else
    die "gcode_shell_command.py is missing or does not expose the required RUN_SHELL_COMMAND extension. EDDY_CLEAR_CALIBRATION cannot operate without it."
fi

case "${EDDY_STATE}" in
    conflict|eddy_ng|btt_native)
        die "Final Eddy discovery indicates an incompatible/conflicting configuration (${EDDY_STATE}). Klipper will not be restarted automatically."
        ;;
    *)
        ok "Final Eddy discovery did not find an unsupported Eddy configuration."
        ;;
esac

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
#!/usr/bin/env bash
#
# Klipper Eddy Tap Wizard Installer
#
# Next-generation installer draft
#
# Design goals:
#   - one canonical Wizard layout: ~/printer_data/config/eddy/
#   - one canonical eddy.cfg template
#   - active-tree discovery plus broad recursive config-directory discovery
#   - content-based native Eddy / Eddy-NG / BTT-style classification
#   - mandatory [bed_mesh] zero_reference_position validation
#   - optional migration of compatible printer sections into eddy/eddy.cfg
#   - migrated sections replace their commented examples in eddy/eddy.cfg
#   - user-owned Eddy configuration is never overwritten by normal updates
#   - safe backup/rollback-oriented edits
#   - preserve current Wizard Python dependency management philosophy
#
# Expected repository files:
#   printer_data/config/templates/eddy.cfg.template
#   printer_data/config/templates/eddy_clear_calibration.cfg.template
#   printer_data/config/eddy_macros.cfg
#   printer_data/config/eddy_setup_wizard.cfg
#   scripts/clear_eddy_calibration.py
#   klipper/klippy/extras/gcode_shell_command.py
#   klipper/klippy/extras/temperature_probe.py
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
PRINTER_CFG="${CONFIG_DIR}/printer.cfg"

# Repository sources
SRC_MACROS="${SCRIPT_DIR}/printer_data/config/eddy_macros.cfg"
SRC_WIZARD="${SCRIPT_DIR}/printer_data/config/eddy_setup_wizard.cfg"
SRC_TEMPLATE="${SCRIPT_DIR}/printer_data/config/templates/eddy.cfg.template"
SRC_CLEAR_TEMPLATE="${SCRIPT_DIR}/printer_data/config/templates/eddy_clear_calibration.cfg.template"
SRC_CLEAR_SCRIPT="${SCRIPT_DIR}/scripts/clear_eddy_calibration.py"
SRC_GCODE_SHELL_COMMAND="${SCRIPT_DIR}/klipper/klippy/extras/gcode_shell_command.py"
SRC_TEMP_PROBE="${SCRIPT_DIR}/klipper/klippy/extras/temperature_probe.py"

# Canonical destination - there is no alternate layout.
EDDY_DIR="${CONFIG_DIR}/eddy"
DST_EDDY="${EDDY_DIR}/eddy.cfg"
DST_MACROS="${EDDY_DIR}/eddy_macros.cfg"
DST_WIZARD="${EDDY_DIR}/eddy_setup_wizard.cfg"
DST_CLEAR="${EDDY_DIR}/eddy_clear_calibration.cfg"

DST_TEMP_PROBE="${KLIPPER_EXTRAS_DIR}/temperature_probe.py"
DST_GCODE_SHELL_COMMAND="${KLIPPER_EXTRAS_DIR}/gcode_shell_command.py"

STATE_DIR="${XDG_CONFIG_HOME:-${HOME_DIR}/.config}/${PROJECT_SLUG}"
TEMP_HASH_FILE="${STATE_DIR}/temperature_probe.installed.sha256"
TEMP_BASE_HASH_FILE="${STATE_DIR}/temperature_probe.base.sha256"
TEMP_BASE_COMMIT_FILE="${STATE_DIR}/temperature_probe.base.commit"
GCODE_SHELL_HASH_FILE="${STATE_DIR}/gcode_shell_command.installed.sha256"
CLEAR_CFG_HASH_FILE="${STATE_DIR}/eddy_clear_calibration.installed.sha256"

# temperature_probe.py is a tracked Klipper source file.  Keep its repository
# path explicit so Git HEAD remains the authoritative source for restoration.
KLIPPER_TEMP_PROBE_REL="klippy/extras/temperature_probe.py"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_ROOT="${CONFIG_DIR}/eddy_wizard_backups"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
BACKUP_CREATED=0

AUTO_YES=0
DO_UPDATE=0
DETECT_ONLY=0
UNINSTALL=0
PREPARE_KLIPPER_UPDATE=0
AFTER_PULL="${EDDY_WIZARD_AFTER_PULL:-0}"

# Sections that may optionally be consolidated into eddy/eddy.cfg.
MIGRATABLE_SECTIONS=(
    "bed_mesh"
    "bed_screws"
    "screws_tilt_adjust"
    "safe_z_home"
    "homing_override"
    "z_tilt"
    "quad_gantry_level"
)

# Populated by discovery.
declare -a ACTIVE_CFG_FILES=()
declare -A ACTIVE_CFG_SEEN=()
declare -a ALL_CFG_FILES=()
declare -a MISSING_INCLUDE_RECORDS=()
declare -a ACTIVE_NATIVE_PROBE_RECORDS=()
declare -a ACTIVE_EDDY_NG_RECORDS=()
declare -a INACTIVE_EDDY_FILES=()
declare -a HISTORICAL_CFG_FILES=()
declare -a BTT_STYLE_FILES=()

EDDY_STATE="none"
NATIVE_PROBE_FILE=""
NATIVE_PROBE_SECTION=""
NATIVE_PROBE_NAME=""

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

clear_screen() {
    # Keep interactive SSH/terminal runs clean without emitting ANSI control
    # sequences into redirected output or non-interactive logs.
    if [[ -t 1 ]]; then
        printf '\033[2J\033[3J\033[H'
    fi
}

info()  { printf '%s[INFO]%s %s\n' "${BLUE}" "${RESET}" "$*"; }
ok()    { printf '%s[ OK ]%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "${YELLOW}" "${RESET}" "$*"; }
error() { printf '%s[FAIL]%s %s\n' "${RED}" "${RESET}" "$*" >&2; }
die()   { error "$*"; exit 1; }

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

ANSWER=""

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

ask_choice() {
    local prompt="$1"
    local default="$2"
    local min="$3"
    local max="$4"
    local value

    while true; do
        read -r -p "${prompt} [${default}]: " value || true
        value="${value:-${default}}"
        if [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )); then
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

usage() {
    cat <<'EOF'
Klipper Eddy Tap Wizard Installer

Usage:
  ./install.sh
  ./install.sh --update
  ./install.sh --detect-only
  ./install.sh --uninstall
  ./install.sh --prepare-klipper-update
  ./install.sh --yes

Canonical installed layout:
  ~/printer_data/config/eddy/
    eddy.cfg
    eddy_macros.cfg
    eddy_setup_wizard.cfg
    eddy_clear_calibration.cfg

Options:
  --update                  Fast-forward the currently checked-out Wizard branch, then rerun.
  --detect-only             Scan active and inactive config files without modifying them.
  --uninstall               Remove Wizard integration while preserving user Eddy config.
  --prepare-klipper-update  Remove the Eddy compatibility patch so Klipper can update cleanly.
  -y, --yes                 Automatically accept normal yes/no prompts.
  -h, --help                Show this help.

Fresh configuration generation remains interactive because connection,
probe-offset, and geometry information cannot be safely guessed.
EOF
}

# ---------------------------------------------------------------------------
# Arguments / menu
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update) DO_UPDATE=1; shift ;;
        --detect-only) DETECT_ONLY=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --prepare-klipper-update) PREPARE_KLIPPER_UPDATE=1; shift ;;
        -y|--yes) AUTO_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

selected_actions=$((DO_UPDATE + DETECT_ONLY + UNINSTALL + PREPARE_KLIPPER_UPDATE))
(( selected_actions <= 1 )) \
    || die "--update, --detect-only, --uninstall, and --prepare-klipper-update are mutually exclusive."

if [[ "${AFTER_PULL}" -ne 1 \
   && "${DO_UPDATE}" -eq 0 \
   && "${DETECT_ONLY}" -eq 0 \
   && "${UNINSTALL}" -eq 0 \
   && "${PREPARE_KLIPPER_UPDATE}" -eq 0 ]]; then
    clear_screen

    printf '\n%sChoose action%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"
    printf '  1) Install / Repair\n'
    printf '  2) Update Eddy Wizard\n'
    printf '  3) Uninstall\n'
    printf '  4) Detect only\n'
    printf '  5) Remove Eddy Patch for Klipper Update\n'
    printf '  6) Exit\n'
    ask_choice "Action" "1" "1" "6"
    case "${ANSWER}" in
        1) ;;
        2) DO_UPDATE=1 ;;
        3) UNINSTALL=1 ;;
        4) DETECT_ONLY=1 ;;
        5) PREPARE_KLIPPER_UPDATE=1 ;;
        6)
            clear_screen
            printf '%s\n' "Exiting Klipper Eddy Tap Wizard."
            exit 0
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

clear_screen

printf '\n%s%s Installer%s\n' "${BOLD}" "${PROJECT_NAME}" "${RESET}"
printf '%s\n\n' "------------------------------------------------------------"

[[ -z "${SUDO_USER:-}" ]] \
    || die "Do not run install.sh with sudo. Run it as the normal Klipper user."

for cmd in git grep awk sed sha256sum readlink find mktemp python3; do
    command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is required."
done

[[ -d "${CONFIG_DIR}" ]] || die "Config directory not found: ${CONFIG_DIR}"
[[ -f "${PRINTER_CFG}" ]] || die "printer.cfg not found: ${PRINTER_CFG}"
[[ -d "${KLIPPER_DIR}/.git" ]] || die "Klipper Git repository not found: ${KLIPPER_DIR}"

if [[ "${DETECT_ONLY}" -eq 0 && "${UNINSTALL}" -eq 0 && "${PREPARE_KLIPPER_UPDATE}" -eq 0 ]]; then
    [[ -d "${KLIPPER_EXTRAS_DIR}" ]] || die "Klipper extras directory not found: ${KLIPPER_EXTRAS_DIR}"
    for required in \
        "${SRC_MACROS}" \
        "${SRC_WIZARD}" \
        "${SRC_TEMPLATE}" \
        "${SRC_CLEAR_TEMPLATE}" \
        "${SRC_CLEAR_SCRIPT}" \
        "${SRC_TEMP_PROBE}" \
        "${SRC_GCODE_SHELL_COMMAND}"; do
        [[ -f "${required}" ]] || die "Repository file missing: ${required}"
    done
fi

# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------

perform_update() {
    local branch

    git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "Repository checkout is not a Git worktree: ${SCRIPT_DIR}"

    branch="$(git -C "${SCRIPT_DIR}" symbolic-ref --quiet --short HEAD || true)"
    [[ -n "${branch}" ]] || die "Cannot update from a detached HEAD."

    info "Updating branch: ${branch}"
    git -C "${SCRIPT_DIR}" pull --ff-only \
        || die "Git update failed. Resolve local changes/divergence first."

    if [[ "${AUTO_YES}" -eq 1 ]]; then
        exec env EDDY_WIZARD_AFTER_PULL=1 "${SCRIPT_PATH}" --yes
    else
        exec env EDDY_WIZARD_AFTER_PULL=1 "${SCRIPT_PATH}"
    fi
}

if [[ "${DO_UPDATE}" -eq 1 && "${AFTER_PULL}" -ne 1 ]]; then
    perform_update
fi

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------

ensure_backup_dir() {
    if [[ "${BACKUP_CREATED}" -eq 0 ]]; then
        mkdir -p "${BACKUP_DIR}"
        BACKUP_CREATED=1
    fi
}

backup_path() {
    local src="$1"
    local label="${2:-$(basename -- "${src}")}"

    [[ -e "${src}" || -L "${src}" ]] || return 0

    ensure_backup_dir
    if [[ -d "${src}" && ! -L "${src}" ]]; then
        cp -a -- "${src}" "${BACKUP_DIR}/${label}"
    else
        cp -a -- "${src}" "${BACKUP_DIR}/${label}"
    fi
    info "Backup: ${src} -> ${BACKUP_DIR}/${label}"
}

# ---------------------------------------------------------------------------
# Active config-tree discovery
# ---------------------------------------------------------------------------

resolve_path() {
    readlink -f -- "$1" 2>/dev/null || printf '%s' "$1"
}

discover_cfg_file() {
    local file="$1"
    local abs_file
    local base_dir
    local line include_spec include_pattern
    local -a matches=()

    [[ -f "${file}" ]] || return 0
    abs_file="$(resolve_path "${file}")"

    [[ -z "${ACTIVE_CFG_SEEN[${abs_file}]:-}" ]] || return 0
    ACTIVE_CFG_SEEN["${abs_file}"]=1
    ACTIVE_CFG_FILES+=("${abs_file}")
    base_dir="$(dirname -- "${abs_file}")"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^[[:space:]]*\[include[[:space:]]+([^]]+)\][[:space:]]*(#.*)?$ ]]; then
            include_spec="$(trim "${BASH_REMATCH[1]}")"
            if [[ "${include_spec}" = /* ]]; then
                include_pattern="${include_spec}"
            else
                include_pattern="${base_dir}/${include_spec}"
            fi

            matches=()
            mapfile -t matches < <(compgen -G "${include_pattern}" || true)

            if (( ${#matches[@]} == 0 )); then
                MISSING_INCLUDE_RECORDS+=("${abs_file}|${include_spec}")
                continue
            fi

            local match
            for match in "${matches[@]}"; do
                [[ -f "${match}" ]] && discover_cfg_file "${match}"
            done
        fi
    done < "${abs_file}"
}

rebuild_active_tree() {
    ACTIVE_CFG_FILES=()
    ACTIVE_CFG_SEEN=()
    MISSING_INCLUDE_RECORDS=()
    discover_cfg_file "${PRINTER_CFG}"
}

path_is_active() {
    local wanted

    wanted="$(resolve_path "$1")"
    [[ -n "${ACTIVE_CFG_SEEN[${wanted}]:-}" ]]
}

# ---------------------------------------------------------------------------
# Broad config-directory scan
# ---------------------------------------------------------------------------

scan_all_cfg_files() {
    local file
    local resolved
    declare -A seen=()

    ALL_CFG_FILES=()
    HISTORICAL_CFG_FILES=()

    printf '\n'
    start_scan_indicator "Scanning Klipper configuration files"

    for file in "${ACTIVE_CFG_FILES[@]}"; do
        resolved="$(resolve_path "${file}")"

        if [[ -z "${seen[${resolved}]:-}" ]]; then
            ALL_CFG_FILES+=("${resolved}")
            seen["${resolved}"]=1
        fi
    done

    while IFS= read -r file; do
        resolved="$(resolve_path "${file}")"

        if [[ -n "${seen[${resolved}]:-}" ]]; then
            continue
        fi

        if is_historical_backup_cfg "${resolved}"; then
            HISTORICAL_CFG_FILES+=("${resolved}")
            continue
        fi

        ALL_CFG_FILES+=("${resolved}")
        seen["${resolved}"]=1
    done < <(
        find "${CONFIG_DIR}" \
            -type f \
            -name '*.cfg' \
            ! -path "${BACKUP_ROOT}/*" \
            ! -path '*/.git/*' \
            -print 2>/dev/null |
        sort
    )

    stop_scan_indicator
    ok "Configuration scan complete."
}

is_historical_backup_cfg() {
    local file="$1"
    local base
    local rel

    base="$(basename -- "${file}")"
    rel="${file#${CONFIG_DIR}/}"

    # Klipper / Mainsail / Fluidd timestamped printer.cfg backups
    if [[ "${base}" =~ ^printer-[0-9]{8}_[0-9]{6}\.cfg$ ]]; then
        return 0
    fi

    # Common backup suffixes
    if [[ "${base}" =~ \.(bak|backup|old|orig)(\.cfg)?$ ]]; then
        return 0
    fi

    # Clearly archival directory components
	if [[ "/${rel}/" =~ /[^/]*(backup|backups|bkp|archive|archives)[^/]*/ ]]; then
		return 0
	fi

    # Wizard's own backups
    if [[ "${file}" == "${BACKUP_ROOT}/"* ]]; then
        return 0
    fi

    return 1
}

file_has_eddy_content() {
    local file="$1"

    grep -Eqi \
        '\[(probe_eddy_current|probe_eddy_ng|temperature_probe[[:space:]]+[^]]*eddy|mcu[[:space:]]+eddy|temperature_sensor[[:space:]]+[^]]*eddy)[^]]*\]|eddy[-_ ]ng|PROBE_EDDY|LDC_CALIBRATE|Eddy Tap Wizard' \
        "${file}" 2>/dev/null
}

is_btt_style_file() {
    local file="$1"

    # Modern BTT examples use native [probe_eddy_current], so BTT-style is
    # identified by the characteristic BTT helper/config signatures rather
    # than by probe name alone.
    grep -Eq '^[[:space:]]*\[probe_eddy_current[[:space:]]+btt_eddy\]' "${file}" 2>/dev/null \
        && grep -Eq 'PROBE_EDDY_CURRENT_CALIBRATE_AUTO|BTT_BED_MESH_CALIBRATE|variable_runtime_offset|SET_GCODE_OFFSET_ORIG' "${file}" 2>/dev/null
}

start_scan_indicator() {
    local message="$1"

    (
        while true; do
            printf '\r[INFO] %s.  ' "${message}"
            sleep 0.4
            printf '\r[INFO] %s.. ' "${message}"
            sleep 0.4
            printf '\r[INFO] %s...' "${message}"
            sleep 0.4
        done
    ) &

    SCAN_INDICATOR_PID=$!
}

stop_scan_indicator() {
    if [[ -n "${SCAN_INDICATOR_PID:-}" ]]; then
        kill "${SCAN_INDICATOR_PID}" 2>/dev/null || true
        wait "${SCAN_INDICATOR_PID}" 2>/dev/null || true
        unset SCAN_INDICATOR_PID
    fi

    printf '\r%-70s\r' ' '
}

scan_eddy_families() {
	start_scan_indicator "Analyzing ${#ALL_CFG_FILES[@]} configuration files for Eddy settings"
    local file
    local line
    local section
    local name
    local active

	ACTIVE_NATIVE_PROBE_RECORDS=()
	ACTIVE_EDDY_NG_RECORDS=()
	INACTIVE_EDDY_FILES=()
	BTT_STYLE_FILES=()

    for file in "${ALL_CFG_FILES[@]}"; do
        active=0
        path_is_active "${file}" && active=1

        # Ignore historical/backup configs only when they are inactive.
        # Active files are always inspected.

        if is_btt_style_file "${file}"; then
            BTT_STYLE_FILES+=("${file}")
        fi

        while IFS= read -r line; do
            section="$(printf '%s' "${line}" | sed -E 's/^[[:space:]]*\[([^]]+)\].*$/\1/')"
            name="${section#probe_eddy_current }"
            if [[ "${active}" -eq 1 ]]; then
                ACTIVE_NATIVE_PROBE_RECORDS+=("${file}|${section}|${name}")
            fi
        done < <(grep -E '^[[:space:]]*\[probe_eddy_current[[:space:]]+[^]]+\]' "${file}" 2>/dev/null || true)

        while IFS= read -r line; do
            section="$(printf '%s' "${line}" | sed -E 's/^[[:space:]]*\[([^]]+)\].*$/\1/')"
            name="${section#probe_eddy_ng }"
            if [[ "${active}" -eq 1 ]]; then
                ACTIVE_EDDY_NG_RECORDS+=("${file}|${section}|${name}")
            fi
        done < <(grep -E '^[[:space:]]*\[probe_eddy_ng[[:space:]]+[^]]+\]' "${file}" 2>/dev/null || true)

        if [[ "${active}" -eq 0 ]] && file_has_eddy_content "${file}"; then
            INACTIVE_EDDY_FILES+=("${file}")
        fi
    done

    if (( ${#ACTIVE_NATIVE_PROBE_RECORDS[@]} > 1 )); then
        EDDY_STATE="multiple_native"
    elif (( ${#ACTIVE_NATIVE_PROBE_RECORDS[@]} == 1 && ${#ACTIVE_EDDY_NG_RECORDS[@]} > 0 )); then
        EDDY_STATE="conflict"
    elif (( ${#ACTIVE_EDDY_NG_RECORDS[@]} > 1 )); then
        EDDY_STATE="multiple_ng"
    elif (( ${#ACTIVE_EDDY_NG_RECORDS[@]} == 1 )); then
        EDDY_STATE="eddy_ng"
    elif (( ${#ACTIVE_NATIVE_PROBE_RECORDS[@]} == 1 )); then
        EDDY_STATE="native"
        IFS='|' read -r NATIVE_PROBE_FILE NATIVE_PROBE_SECTION NATIVE_PROBE_NAME \
            <<< "${ACTIVE_NATIVE_PROBE_RECORDS[0]}"
    else
        EDDY_STATE="none"
    fi
	
	stop_scan_indicator
	ok "Eddy configuration analysis complete."
}

report_discovery() {
    printf '\n%sConfiguration discovery%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"
    printf 'Active config files:          %d\n' "${#ACTIVE_CFG_FILES[@]}"
	printf 'Config files analyzed:        %d\n' "${#ALL_CFG_FILES[@]}"
	printf 'Historical backups ignored:   %d\n' "${#HISTORICAL_CFG_FILES[@]}"
	printf 'Active native Eddy probes:    %d\n' "${#ACTIVE_NATIVE_PROBE_RECORDS[@]}"
	printf 'Active Eddy-NG probes:        %d\n' "${#ACTIVE_EDDY_NG_RECORDS[@]}"
	printf 'Inactive Eddy candidates:     %d\n' "${#INACTIVE_EDDY_FILES[@]}"
	printf 'Classification:               %s\n' "${EDDY_STATE}"

    if (( ${#MISSING_INCLUDE_RECORDS[@]} > 0 )); then
        warn "Missing include targets were found in the active config tree:"
        local record file spec
        for record in "${MISSING_INCLUDE_RECORDS[@]}"; do
            IFS='|' read -r file spec <<< "${record}"
            printf '  %s -> [include %s]\n' "${file}" "${spec}"
        done
    fi

    if (( ${#INACTIVE_EDDY_FILES[@]} > 0 )); then
        info "Inactive Eddy migration candidates were found:"
        local file
        for file in "${INACTIVE_EDDY_FILES[@]}"; do
            printf '  %s\n' "${file}"
        done
    fi
}

# ---------------------------------------------------------------------------
# Config-section parsing/editing helpers
# ---------------------------------------------------------------------------

section_record_for_active_name() {
    local target="$1"
    local file
    local result

    for file in "${ACTIVE_CFG_FILES[@]}"; do
        result="$(
            python3 - "${file}" "${target}" <<'PY'
import re, sys
path, target = sys.argv[1], sys.argv[2]
rx = re.compile(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$')
with open(path, encoding='utf-8') as f:
    for lineno, line in enumerate(f, 1):
        m = rx.match(line.rstrip('\n'))
        if m and m.group(1).strip().lower() == target.lower():
            print(f"{path}|{lineno}|{m.group(1).strip()}")
            break
PY
        )"
        [[ -n "${result}" ]] && { printf '%s\n' "${result}"; return 0; }
    done
    return 1
}

extract_section_to_file() {
    local source="$1"
    local section_name="$2"
    local output="$3"

    python3 - "${source}" "${section_name}" "${output}" <<'PY'
import re, sys
source, target, output = sys.argv[1:]
header = re.compile(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$')
with open(source, encoding='utf-8') as f:
    lines = f.readlines()

start = None
end = len(lines)
for i, line in enumerate(lines):
    m = header.match(line.rstrip('\n'))
    if m and m.group(1).strip().lower() == target.lower():
        start = i
        break

if start is None:
    raise SystemExit(2)

for i in range(start + 1, len(lines)):
    if header.match(lines[i].rstrip('\n')):
        end = i
        break

chunk = lines[start:end]
while chunk and not chunk[-1].strip():
    chunk.pop()
chunk.append('\n')

with open(output, 'w', encoding='utf-8') as f:
    f.writelines(chunk)
PY
}

remove_section_from_file() {
    local source="$1"
    local section_name="$2"
    local tmp

    tmp="$(mktemp)"
    python3 - "${source}" "${section_name}" "${tmp}" <<'PY'
import re, sys
source, target, output = sys.argv[1:]
header = re.compile(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$')
with open(source, encoding='utf-8') as f:
    lines = f.readlines()

start = None
end = None
for i, line in enumerate(lines):
    m = header.match(line.rstrip('\n'))
    if m and m.group(1).strip().lower() == target.lower():
        start = i
        break

if start is None:
    raise SystemExit(2)

end = len(lines)
for i in range(start + 1, len(lines)):
    if header.match(lines[i].rstrip('\n')):
        end = i
        break

# Preserve comments directly preceding the next real section. We only remove
# from the section header through the last non-comment/nonblank option content.
# Interior comments remain part of the migrated section.
out = lines[:start] + lines[end:]
with open(output, 'w', encoding='utf-8') as f:
    f.writelines(out)
PY

    cat "${tmp}" > "${source}"
    rm -f -- "${tmp}"
}

replace_commented_example_with_section() {
    local section_name="$1"
    local section_file="$2"
    local tmp

    tmp="$(mktemp)"
    python3 - "${DST_EDDY}" "${section_name}" "${section_file}" "${tmp}" <<'PY'
import re, sys
dest, target, section_file, output = sys.argv[1:]
with open(dest, encoding='utf-8') as f:
    lines = f.readlines()
with open(section_file, encoding='utf-8') as f:
    replacement = f.readlines()

# The canonical template keeps optional examples commented:
#   #[bed_mesh]
#   #speed: ...
#
# Replace from that commented section header up to (but not including)
# the next large banner line. This leaves the destination heading intact.
start_rx = re.compile(r'^\s*#\s*\[' + re.escape(target) + r'\]\s*$',
                      re.IGNORECASE)
banner_rx = re.compile(r'^\s*#{20,}\s*$')

start = None
for i, line in enumerate(lines):
    if start_rx.match(line.rstrip('\n')):
        start = i
        break

if start is None:
    # If the example does not exist, append the migrated section rather than
    # risking damage to unrelated user content.
    if lines and lines[-1].strip():
        lines.append('\n')
    lines.extend(replacement)
else:
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if banner_rx.match(lines[i].rstrip('\n')):
            end = i
            break
    lines = lines[:start] + replacement + ['\n'] + lines[end:]

with open(output, 'w', encoding='utf-8') as f:
    f.writelines(lines)
PY

    cat "${tmp}" > "${DST_EDDY}"
    rm -f -- "${tmp}"
}

section_has_option() {
    local source="$1"
    local section_name="$2"
    local option="$3"

    python3 - "${source}" "${section_name}" "${option}" <<'PY'
import re, sys
source, target, option = sys.argv[1:]
header = re.compile(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$')
opt = re.compile(r'^\s*' + re.escape(option) + r'\s*:', re.IGNORECASE)
inside = False
with open(source, encoding='utf-8') as f:
    for line in f:
        m = header.match(line.rstrip('\n'))
        if m:
            inside = m.group(1).strip().lower() == target.lower()
            continue
        if inside and opt.match(line):
            raise SystemExit(0)
raise SystemExit(1)
PY
}

get_section_option() {
    local source="$1"
    local section_name="$2"
    local option="$3"

    python3 - "${source}" "${section_name}" "${option}" <<'PY'
import re, sys
source, target, option = sys.argv[1:]
header = re.compile(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$')
opt = re.compile(r'^\s*' + re.escape(option) + r'\s*:\s*(.*?)\s*(?:#.*)?$',
                 re.IGNORECASE)
inside = False
with open(source, encoding='utf-8') as f:
    for line in f:
        m = header.match(line.rstrip('\n'))
        if m:
            inside = m.group(1).strip().lower() == target.lower()
            continue
        if inside:
            m = opt.match(line.rstrip('\n'))
            if m:
                print(m.group(1).strip())
                raise SystemExit(0)
raise SystemExit(1)
PY
}

insert_option_into_section() {
    local source="$1"
    local section_name="$2"
    local option="$3"
    local value="$4"
    local tmp

    tmp="$(mktemp)"
    python3 - "${source}" "${section_name}" "${option}" "${value}" "${tmp}" <<'PY'
import re, sys
source, target, option, value, output = sys.argv[1:]
header = re.compile(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$')
with open(source, encoding='utf-8') as f:
    lines = f.readlines()

start = None
end = len(lines)
for i, line in enumerate(lines):
    m = header.match(line.rstrip('\n'))
    if m and m.group(1).strip().lower() == target.lower():
        start = i
        break
if start is None:
    raise SystemExit(2)

for i in range(start + 1, len(lines)):
    if header.match(lines[i].rstrip('\n')):
        end = i
        break

insert_at = end
while insert_at > start + 1 and not lines[insert_at - 1].strip():
    insert_at -= 1

lines.insert(insert_at, f"{option}: {value}\n")
with open(output, 'w', encoding='utf-8') as f:
    f.writelines(lines)
PY

    cat "${tmp}" > "${source}"
    rm -f -- "${tmp}"
}

# ---------------------------------------------------------------------------
# zero_reference_position
# ---------------------------------------------------------------------------

BED_MESH_FILE=""
ZERO_REFERENCE_VALUE=""

locate_active_bed_mesh() {
    local record
    BED_MESH_FILE=""
    record="$(section_record_for_active_name "bed_mesh" || true)"
    [[ -n "${record}" ]] || return 1
    IFS='|' read -r BED_MESH_FILE _ _ <<< "${record}"
    return 0
}

validate_zero_reference_position() {
    local zrx zry

    if locate_active_bed_mesh; then
        if section_has_option "${BED_MESH_FILE}" "bed_mesh" "zero_reference_position"; then
            ZERO_REFERENCE_VALUE="$(
                get_section_option "${BED_MESH_FILE}" "bed_mesh" "zero_reference_position"
            )"
            ok "Existing zero_reference_position preserved: ${ZERO_REFERENCE_VALUE}"
            return 0
        fi

        printf '\n%s[bed_mesh] requires zero_reference_position%s\n' "${BOLD}" "${RESET}"
        info "Existing [bed_mesh]: ${BED_MESH_FILE}"
        ask_number "Zero reference X"
        zrx="${ANSWER}"
        ask_number "Zero reference Y"
        zry="${ANSWER}"
        ZERO_REFERENCE_VALUE="${zrx}, ${zry}"

        if ! ask_yes_no "Add zero_reference_position: ${ZERO_REFERENCE_VALUE} to the existing [bed_mesh]?" "y"; then
            die "zero_reference_position is required by the Eddy Tap Wizard."
        fi

        backup_path "${BED_MESH_FILE}" "$(basename -- "${BED_MESH_FILE}").before_zero_reference"
        insert_option_into_section \
            "${BED_MESH_FILE}" "bed_mesh" "zero_reference_position" "${ZERO_REFERENCE_VALUE}"
        ok "Added zero_reference_position to ${BED_MESH_FILE}"
        rebuild_active_tree
        return 0
    fi

    # No active bed_mesh. Fresh generation will activate the template's
    # personalized [bed_mesh] example after collecting geometry.
    return 1
}

# ---------------------------------------------------------------------------
# Eddy Tap negative Z travel validation
# ---------------------------------------------------------------------------

Z_TRAVEL_FILE=""
Z_POSITION_MIN=""

locate_active_stepper_z() {
    local record

    Z_TRAVEL_FILE=""
    Z_POSITION_MIN=""

    record="$(section_record_for_active_name "stepper_z" || true)"
    [[ -n "${record}" ]] || return 1

    IFS='|' read -r Z_TRAVEL_FILE _ _ <<< "${record}"
    return 0
}

validate_tap_negative_z_travel() {
    if ! locate_active_stepper_z; then
        warn "No active [stepper_z] section was found."
        warn "Unable to automatically verify Eddy Tap negative Z travel."
        return 0
    fi

    Z_POSITION_MIN="$(
        get_section_option "${Z_TRAVEL_FILE}" "stepper_z" "position_min" || true
    )"

    # Missing position_min: add the Eddy Tap-safe default.
    if [[ -z "${Z_POSITION_MIN}" ]]; then
        info "[stepper_z] does not define position_min."
        info "Adding position_min: -1 for Eddy Tap."

        backup_path \
            "${Z_TRAVEL_FILE}" \
            "$(basename -- "${Z_TRAVEL_FILE}").before_tap_position_min"

        insert_option_into_section \
            "${Z_TRAVEL_FILE}" \
            "stepper_z" \
            "position_min" \
            "-1"

        Z_POSITION_MIN="-1"

        ok "Added [stepper_z] position_min: -1"
        rebuild_active_tree
        return 0
    fi

    # Existing position_min must be numeric.
    if ! [[ "${Z_POSITION_MIN}" =~ ^-?([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
        die "Invalid [stepper_z] position_min value: ${Z_POSITION_MIN}"
    fi

    # Anything greater than -1 does not provide the minimum travel
    # we want for Eddy Tap. Force it to -1.
    if awk -v z="${Z_POSITION_MIN}" 'BEGIN { exit !(z > -1) }'; then
        info "Active [stepper_z] position_min is ${Z_POSITION_MIN}."
        info "Eddy Tap requires at least 1mm of negative Z travel."

        backup_path \
            "${Z_TRAVEL_FILE}" \
            "$(basename -- "${Z_TRAVEL_FILE}").before_tap_position_min"

        python3 - "${Z_TRAVEL_FILE}" <<'PY'
import re
import sys

path = sys.argv[1]

header_rx = re.compile(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$')
option_rx = re.compile(
    r'^(\s*)position_min\s*:\s*([^#\r\n]*)(\s*(?:#.*)?)$',
    re.IGNORECASE,
)

with open(path, encoding='utf-8') as f:
    lines = f.readlines()

inside = False
changed = False

for i, line in enumerate(lines):
    stripped = line.rstrip('\n')
    header = header_rx.match(stripped)

    if header:
        inside = header.group(1).strip().lower() == "stepper_z"
        continue

    if inside:
        match = option_rx.match(stripped)
        if match:
            newline = '\n' if line.endswith('\n') else ''
            lines[i] = (
                f"{match.group(1)}position_min: -1"
                f"{match.group(3)}{newline}"
            )
            changed = True
            break

if not changed:
    raise SystemExit(2)

with open(path, 'w', encoding='utf-8') as f:
    f.writelines(lines)
PY

        Z_POSITION_MIN="-1"

        ok "Updated [stepper_z] position_min to -1."
        rebuild_active_tree
        return 0
    fi

    # -1 or anything more negative is already acceptable.
    ok "Eddy Tap Z travel already configured: position_min=${Z_POSITION_MIN}"
}

# ---------------------------------------------------------------------------
# Template rendering / fresh canonical Eddy config
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

validate_can_uuid() {
    [[ "$1" =~ ^[0-9A-Fa-f]{12,32}$ ]]
}

activate_commented_example() {
    local section="$1"
    local tmp

    tmp="$(mktemp)"
    python3 - "${DST_EDDY}" "${section}" "${tmp}" <<'PY'
import re, sys
path, target, output = sys.argv[1:]
with open(path, encoding='utf-8') as f:
    lines = f.readlines()

start_rx = re.compile(r'^(\s*)#\s*(\[' + re.escape(target) + r'\])\s*$',
                      re.IGNORECASE)
banner_rx = re.compile(r'^\s*#{20,}\s*$')
start = None
for i, line in enumerate(lines):
    if start_rx.match(line.rstrip('\n')):
        start = i
        break
if start is None:
    raise SystemExit(2)

end = len(lines)
for i in range(start + 1, len(lines)):
    if banner_rx.match(lines[i].rstrip('\n')):
        end = i
        break

for i in range(start, end):
    s = lines[i]
    m = re.match(r'^(\s*)#( ?)(.*)$', s)
    if m:
        lines[i] = m.group(1) + m.group(3)

with open(output, 'w', encoding='utf-8') as f:
    f.writelines(lines)
PY
    cat "${tmp}" > "${DST_EDDY}"
    rm -f -- "${tmp}"
}

generate_fresh_eddy_cfg() {
    local connection serial_value="" can_uuid=""
    local x_offset y_offset
    local zero_x zero_y
    local mesh_min_x="" mesh_min_y="" mesh_max_x="" mesh_max_y=""
    local cal_bed_temp cal_extruder_temp max_validation_temp
    local tmp_cfg
    local create_bed_mesh=0

    [[ "${AUTO_YES}" -eq 0 && -t 0 ]] \
        || die "Fresh Eddy configuration requires interactive input."

    printf '\n%sCreate canonical Eddy configuration%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "Destination: ${DST_EDDY}"

    printf '\nConnection:\n'
    printf '  1) USB\n'
    printf '  2) CAN\n'
    ask_choice "Connection" "1" "1" "2"
    connection="${ANSWER}"

    if [[ "${connection}" -eq 1 ]]; then
        ask_required "Eddy USB serial path"
        serial_value="${ANSWER}"
    else
        while true; do
            ask_required "Eddy CAN UUID"
            can_uuid="${ANSWER}"
            validate_can_uuid "${can_uuid}" && break
            warn "Expected a hexadecimal CAN UUID."
        done
    fi

    printf '\nProbe/nozzle offsets\n'
    ask_number "X offset"
    x_offset="${ANSWER}"
    ask_number "Y offset"
    y_offset="${ANSWER}"

    if [[ -n "${ZERO_REFERENCE_VALUE}" ]]; then
        IFS=',' read -r zero_x zero_y <<< "${ZERO_REFERENCE_VALUE}"
        zero_x="$(trim "${zero_x}")"
        zero_y="$(trim "${zero_y}")"
    else
        printf '\nZero reference position\n'
        ask_number "Zero reference X"
        zero_x="${ANSWER}"
        ask_number "Zero reference Y"
        zero_y="${ANSWER}"
        ZERO_REFERENCE_VALUE="${zero_x}, ${zero_y}"
    fi

    if ! locate_active_bed_mesh; then
        create_bed_mesh=1
        printf '\nNo active [bed_mesh] was found.\n'
        info "A valid [bed_mesh] with zero_reference_position is required."
        ask_number "Mesh minimum X"
        mesh_min_x="${ANSWER}"
        ask_number "Mesh minimum Y"
        mesh_min_y="${ANSWER}"
        ask_number "Mesh maximum X"
        mesh_max_x="${ANSWER}"
        ask_number "Mesh maximum Y"
        mesh_max_y="${ANSWER}"

        awk -v a="${mesh_min_x}" -v b="${mesh_max_x}" 'BEGIN{exit !(a<b)}' \
            || die "Mesh minimum X must be less than maximum X."
        awk -v a="${mesh_min_y}" -v b="${mesh_max_y}" 'BEGIN{exit !(a<b)}' \
            || die "Mesh minimum Y must be less than maximum Y."
    else
        # Personalize the commented reference from existing values when present.
        local mm
        mm="$(get_section_option "${BED_MESH_FILE}" "bed_mesh" "mesh_min" || true)"
        if [[ -n "${mm}" ]]; then
            IFS=',' read -r mesh_min_x mesh_min_y <<< "${mm}"
            mesh_min_x="$(trim "${mesh_min_x}")"; mesh_min_y="$(trim "${mesh_min_y}")"
        fi
        mm="$(get_section_option "${BED_MESH_FILE}" "bed_mesh" "mesh_max" || true)"
        if [[ -n "${mm}" ]]; then
            IFS=',' read -r mesh_max_x mesh_max_y <<< "${mm}"
            mesh_max_x="$(trim "${mesh_max_x}")"; mesh_max_y="$(trim "${mesh_max_y}")"
        fi
    fi

    mesh_min_x="${mesh_min_x:-0}"
    mesh_min_y="${mesh_min_y:-0}"
    mesh_max_x="${mesh_max_x:-0}"
    mesh_max_y="${mesh_max_y:-0}"

    printf '\nTemperature compensation settings\n'
    ask_number "Calibration bed temperature" "95"
    cal_bed_temp="${ANSWER}"
    ask_number "Calibration extruder temperature" "150"
    cal_extruder_temp="${ANSWER}"
    ask_number "Maximum validation temperature" "100"
    max_validation_temp="${ANSWER}"

    printf '\n%sConfiguration summary%s\n' "${BOLD}" "${RESET}"
    printf 'Destination:                  %s\n' "${DST_EDDY}"
    printf 'Connection:                   %s\n' "$([[ "${connection}" -eq 1 ]] && printf USB || printf CAN)"
    printf 'Probe offsets:                X=%s Y=%s\n' "${x_offset}" "${y_offset}"
    printf 'zero_reference_position:      %s\n' "${ZERO_REFERENCE_VALUE}"
    if [[ "${create_bed_mesh}" -eq 1 ]]; then
        printf '[bed_mesh]:                  create in eddy.cfg\n'
        printf 'Mesh min/max:                 %s,%s -> %s,%s\n' \
            "${mesh_min_x}" "${mesh_min_y}" "${mesh_max_x}" "${mesh_max_y}"
    else
        printf '[bed_mesh]:                  preserve existing at %s\n' "${BED_MESH_FILE}"
    fi

    ask_yes_no "Generate the canonical Eddy configuration?" "y" \
        || die "Configuration generation cancelled."

    mkdir -p "${EDDY_DIR}"
    tmp_cfg="$(mktemp)"
    cp -- "${SRC_TEMPLATE}" "${tmp_cfg}"

    replace_placeholder "${tmp_cfg}" "X_OFFSET" "${x_offset}"
    replace_placeholder "${tmp_cfg}" "Y_OFFSET" "${y_offset}"
    replace_placeholder "${tmp_cfg}" "BED_CENTER_X" "${zero_x}"
    replace_placeholder "${tmp_cfg}" "BED_CENTER_Y" "${zero_y}"
    replace_placeholder "${tmp_cfg}" "MESH_MIN_X" "${mesh_min_x}"
    replace_placeholder "${tmp_cfg}" "MESH_MIN_Y" "${mesh_min_y}"
    replace_placeholder "${tmp_cfg}" "MESH_MAX_X" "${mesh_max_x}"
    replace_placeholder "${tmp_cfg}" "MESH_MAX_Y" "${mesh_max_y}"
    replace_placeholder "${tmp_cfg}" "CALIBRATION_BED_TEMP" "${cal_bed_temp}"
    replace_placeholder "${tmp_cfg}" "CALIBRATION_EXTRUDER_TEMP" "${cal_extruder_temp}"
    replace_placeholder "${tmp_cfg}" "MAX_VALIDATION_TEMP" "${max_validation_temp}"

    if [[ "${connection}" -eq 1 ]]; then
        replace_placeholder "${tmp_cfg}" "EDDY_SERIAL" "${serial_value}"
    else
        replace_placeholder "${tmp_cfg}" "EDDY_CANBUS_UUID" "${can_uuid}"
        sed -i -E 's|^serial:[[:space:]].*$|#serial: {{EDDY_SERIAL}}|' "${tmp_cfg}"
        sed -i -E 's|^restart_method:[[:space:]]*command[[:space:]]*$|#restart_method: command|' "${tmp_cfg}"
        sed -i -E 's|^#canbus_uuid:[[:space:]]*|canbus_uuid: |' "${tmp_cfg}"
    fi

    if grep -nE '^[[:space:]]*[^#[:space:]].*\{\{[A-Z0-9_]+\}\}' "${tmp_cfg}" >/dev/null; then
        error "Unresolved active placeholders remain in the template:"
        grep -nE '^[[:space:]]*[^#[:space:]].*\{\{[A-Z0-9_]+\}\}' "${tmp_cfg}" >&2 || true
        rm -f -- "${tmp_cfg}"
        die "Template render failed."
    fi

    [[ ! -e "${DST_EDDY}" && ! -L "${DST_EDDY}" ]] \
        || { rm -f -- "${tmp_cfg}"; die "${DST_EDDY} already exists and will not be overwritten."; }

    cp -- "${tmp_cfg}" "${DST_EDDY}"
    rm -f -- "${tmp_cfg}"
    chmod 0644 "${DST_EDDY}" 2>/dev/null || true
    ok "Generated user-owned Eddy configuration: ${DST_EDDY}"

    if [[ "${create_bed_mesh}" -eq 1 ]]; then
        activate_commented_example "bed_mesh"
        ok "Activated personalized [bed_mesh] in eddy.cfg."
    fi
}

# ---------------------------------------------------------------------------
# Existing native Eddy normalization
# ---------------------------------------------------------------------------

deactivate_moved_config_source() {
    local source="$1"
    local source_real
    local parent line include_spec include_pattern
    local tmp changed
    local -a matches=()

    source_real="$(resolve_path "${source}")"

    for parent in "${ACTIVE_CFG_FILES[@]}"; do
        [[ "$(resolve_path "${parent}")" == "${source_real}" ]] && continue

        tmp="$(mktemp)"
        changed=0
        : > "${tmp}"

        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ "${line}" =~ ^[[:space:]]*\[include[[:space:]]+([^]]+)\][[:space:]]*(#.*)?$ ]]; then
                include_spec="$(trim "${BASH_REMATCH[1]}")"
                if [[ "${include_spec}" = /* ]]; then
                    include_pattern="${include_spec}"
                else
                    include_pattern="$(dirname -- "${parent}")/${include_spec}"
                fi

                matches=()
                mapfile -t matches < <(compgen -G "${include_pattern}" || true)

                local match matched_source=0
                for match in "${matches[@]}"; do
                    if [[ "$(resolve_path "${match}")" == "${source_real}" ]]; then
                        matched_source=1
                        break
                    fi
                done

                if [[ "${matched_source}" -eq 1 ]]; then
                    # Exact include: remove it because printer.cfg will receive
                    # the one canonical [include eddy/eddy.cfg].
                    if [[ "${include_spec}" != *'*'* \
                       && "${include_spec}" != *'?'* \
                       && "${include_spec}" != *'['* ]]; then
                        changed=1
                        continue
                    fi
                    # Wildcard include: leave it unchanged. Moving the source
                    # file out of its old location naturally removes the match.
                fi
            fi
            printf '%s\n' "${line}" >> "${tmp}"
        done < "${parent}"

        if [[ "${changed}" -eq 1 ]]; then
            backup_path "${parent}" "$(basename -- "${parent}").before_eddy_source_move"
            cat "${tmp}" > "${parent}"
            info "Removed old exact include for migrated Eddy config from ${parent}"
        fi
        rm -f -- "${tmp}"
    done
}

copy_existing_dedicated_eddy_cfg() {
    local source="$1"

    mkdir -p "${EDDY_DIR}"

    if [[ "$(resolve_path "${source}")" == "$(resolve_path "${DST_EDDY}")" ]]; then
        ok "Native Eddy configuration is already at the canonical destination."
        return 0
    fi

    if [[ -e "${DST_EDDY}" || -L "${DST_EDDY}" ]]; then
        die "Canonical ${DST_EDDY} already exists. Refusing to overwrite it."
    fi

    backup_path "${source}" "$(basename -- "${source}").before_eddy_normalization"
    cp -- "${source}" "${DST_EDDY}"
    chmod 0644 "${DST_EDDY}" 2>/dev/null || true

    deactivate_moved_config_source "${source}"
    rm -f -- "${source}"

    ok "Moved existing Eddy configuration to canonical destination: ${DST_EDDY}"
}

native_source_looks_dedicated() {
    local source="$1"
    local base
    base="$(basename -- "${source}")"

    [[ "${base,,}" == *eddy* ]] && return 0

    # If every active section in the file is clearly Eddy/Wizard related,
    # consider it a dedicated Eddy config even if the filename is custom.
    python3 - "${source}" <<'PY'
import re, sys
p = sys.argv[1]
h = re.compile(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$')
allowed_prefixes = (
    'mcu eddy', 'temperature_sensor', 'temperature_probe',
    'probe_eddy_current', 'probe_eddy_ng', 'bed_mesh', 'bed_screws',
    'screws_tilt_adjust', 'safe_z_home', 'homing_override', 'z_tilt',
    'quad_gantry_level', 'gcode_macro', 'save_variables'
)
sections=[]
with open(p, encoding='utf-8') as f:
    for line in f:
        m=h.match(line.rstrip('\n'))
        if m:
            sections.append(m.group(1).strip().lower())
if not sections:
    raise SystemExit(1)
if all(s.startswith(allowed_prefixes) for s in sections):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

normalize_existing_native() {
    local source="${NATIVE_PROBE_FILE}"

    printf '\n%sExisting native Eddy configuration%s\n' "${BOLD}" "${RESET}"
    info "Probe section: [${NATIVE_PROBE_SECTION}]"
    info "Source: ${source}"

    if [[ "$(resolve_path "${source}")" == "$(resolve_path "${DST_EDDY}")" ]]; then
        ok "Existing native Eddy configuration is already canonical."
        return 0
    fi

    if native_source_looks_dedicated "${source}"; then
        if ask_yes_no "Move this dedicated Eddy configuration into ${EDDY_DIR}/?" "y"; then
            copy_existing_dedicated_eddy_cfg "${source}"
            # The original include will be removed only after printer.cfg has
            # been switched to [include eddy/eddy.cfg].
            return 0
        fi
        die "The Wizard now requires the canonical ${EDDY_DIR}/ layout."
    fi

    # Mixed source file: build a canonical Eddy file from the single template,
    # but preserve the user's existing probe section verbatim in the example
    # replacement slot. This avoids copying unrelated printer.cfg content.
    warn "The native Eddy probe is inside a mixed printer configuration file."
    info "The installer will create canonical eddy/eddy.cfg and migrate only explicitly selected sections."

    # Fresh template requires connection/geometry fields. Reuse existing probe
    # offsets when present but still use the normal fresh generator for hardware
    # identity and temperature-compensation questions.
    generate_fresh_eddy_cfg

    local tmp_section
    tmp_section="$(mktemp)"
    extract_section_to_file "${source}" "${NATIVE_PROBE_SECTION}" "${tmp_section}"

    # Remove the template-generated probe section and insert the user's actual
    # native probe section in its place.
    python3 - "${DST_EDDY}" "${NATIVE_PROBE_SECTION}" "${tmp_section}" <<'PY'
import re, sys
dest, target, repl_file = sys.argv[1:]
with open(dest, encoding='utf-8') as f: lines=f.readlines()
with open(repl_file, encoding='utf-8') as f: repl=f.readlines()

# Replace the first active probe_eddy_current section, regardless of its name.
hdr=re.compile(r'^\s*\[probe_eddy_current\s+[^\]]+\]\s*(?:#.*)?$', re.I)
anyhdr=re.compile(r'^\s*\[[^\]]+\]\s*(?:#.*)?$')
start=None
for i,l in enumerate(lines):
    if hdr.match(l.rstrip('\n')):
        start=i; break
if start is None:
    raise SystemExit(2)
end=len(lines)
for i in range(start+1,len(lines)):
    if anyhdr.match(lines[i].rstrip('\n')):
        end=i; break
lines=lines[:start]+repl+['\n']+lines[end:]
with open(dest,'w',encoding='utf-8') as f:f.writelines(lines)
PY
    rm -f -- "${tmp_section}"

    backup_path "${source}" "$(basename -- "${source}").before_native_probe_migration"
    remove_section_from_file "${source}" "${NATIVE_PROBE_SECTION}"
    ok "Migrated existing [${NATIVE_PROBE_SECTION}] into canonical eddy.cfg."
}

# ---------------------------------------------------------------------------
# Optional compatible printer-section consolidation
# ---------------------------------------------------------------------------

migrate_section_to_eddy() {
    local section="$1"
    local record="$2"
    local source line actual
    local tmp_section

    IFS='|' read -r source line actual <<< "${record}"

    [[ "$(resolve_path "${source}")" != "$(resolve_path "${DST_EDDY}")" ]] || return 0

    printf '\nFound [%s] in:\n  %s\n' "${actual}" "${source}"
    if ! ask_yes_no "Move this section into eddy/eddy.cfg?" "n"; then
        info "[${actual}] will remain at its current location."
        return 0
    fi

    backup_path "${source}" "$(basename -- "${source}").before_${section}_migration"
    backup_path "${DST_EDDY}" "eddy.cfg.before_${section}_migration"

    tmp_section="$(mktemp)"
    extract_section_to_file "${source}" "${actual}" "${tmp_section}"
    replace_commented_example_with_section "${section}" "${tmp_section}"
    remove_section_from_file "${source}" "${actual}"
    rm -f -- "${tmp_section}"

    rebuild_active_tree
    ok "Migrated [${actual}] into ${DST_EDDY}"
}

offer_section_consolidation() {
    local section record
    local -a candidates=()

    [[ -f "${DST_EDDY}" ]] || return 0

    for section in "${MIGRATABLE_SECTIONS[@]}"; do
        record="$(section_record_for_active_name "${section}" || true)"
        [[ -n "${record}" ]] || continue

        local source _ _
        IFS='|' read -r source _ _ <<< "${record}"
        [[ "$(resolve_path "${source}")" == "$(resolve_path "${DST_EDDY}")" ]] && continue
        candidates+=("${section}|${record}")
    done

    (( ${#candidates[@]} > 0 )) || return 0

    printf '\n%sOptional printer-config consolidation%s\n' "${BOLD}" "${RESET}"
    printf 'The following compatible active sections exist outside eddy.cfg:\n'
    local item sec file line actual
    for item in "${candidates[@]}"; do
        IFS='|' read -r sec file line actual <<< "${item}"
        printf '  [%s] -> %s\n' "${actual}" "${file}"
    done

    if ! ask_yes_no "Review these sections for optional migration into eddy.cfg?" "n"; then
        info "Existing printer sections will remain where they are."
        return 0
    fi

    for item in "${candidates[@]}"; do
        IFS='|' read -r sec file line actual <<< "${item}"
        migrate_section_to_eddy "${sec}" "${file}|${line}|${actual}"
    done
}

# ---------------------------------------------------------------------------
# Canonical include management
# ---------------------------------------------------------------------------

remove_known_old_wizard_includes() {
    local file="$1"
    local tmp

    tmp="$(mktemp)"
    sed -E \
        -e '/^[[:space:]]*\[include[[:space:]]+eddy\.cfg\][[:space:]]*(#.*)?$/d' \
        -e '/^[[:space:]]*\[include[[:space:]]+(\.\/)?eddy\/eddy\.cfg\][[:space:]]*(#.*)?$/d' \
        -e '/^[[:space:]]*\[include[[:space:]]+eddy_setup_wizard\.cfg\][[:space:]]*(#.*)?$/d' \
        -e '/^[[:space:]]*\[include[[:space:]]+eddy_macros\.cfg\][[:space:]]*(#.*)?$/d' \
        -e '/^[[:space:]]*\[include[[:space:]]+eddy_clear_calibration\.cfg\][[:space:]]*(#.*)?$/d' \
        "${file}" > "${tmp}"
    cat "${tmp}" > "${file}"
    rm -f -- "${tmp}"
}

ensure_canonical_printer_include() {
    local tmp

    rebuild_active_tree

    # If canonical eddy.cfg is already active, no printer.cfg rewrite is needed.
    if path_is_active "${DST_EDDY}"; then
        ok "Canonical eddy/eddy.cfg is already active."
        return 0
    fi

    backup_path "${PRINTER_CFG}" "printer.cfg.before_canonical_eddy_include"
    tmp="$(mktemp)"

    # Remove installer-era flat/nested direct references only from printer.cfg,
    # then add exactly one canonical include at the top.
    cp -- "${PRINTER_CFG}" "${tmp}"
    remove_known_old_wizard_includes "${tmp}"

    {
        printf '# >>> Klipper Eddy Tap Wizard >>>\n'
        printf '[include eddy/eddy.cfg]\n'
        printf '# <<< Klipper Eddy Tap Wizard <<<\n\n'
        cat "${tmp}"
    } > "${PRINTER_CFG}"
    rm -f -- "${tmp}"

    rebuild_active_tree
    path_is_active "${DST_EDDY}" \
        || die "Canonical [include eddy/eddy.cfg] did not activate ${DST_EDDY}."

    ok "Activated canonical [include eddy/eddy.cfg]."
}

ensure_internal_wizard_includes() {
    local include

    [[ -f "${DST_EDDY}" ]] || die "Missing ${DST_EDDY}"

    for include in eddy_setup_wizard.cfg eddy_macros.cfg eddy_clear_calibration.cfg; do
        if ! grep -Eq "^[[:space:]]*\\[include[[:space:]]+${include//./\\.}\\][[:space:]]*(#.*)?$" "${DST_EDDY}"; then
            backup_path "${DST_EDDY}" "eddy.cfg.before_wizard_include_repair"
            {
                printf '[include %s]\n' "${include}"
                cat "${DST_EDDY}"
            } > "${DST_EDDY}.tmp"
            mv -- "${DST_EDDY}.tmp" "${DST_EDDY}"
            info "Added [include ${include}] to eddy.cfg."
        fi
    done
}

# ---------------------------------------------------------------------------
# Wizard config payload
# ---------------------------------------------------------------------------

install_cfg_link() {
    local src="$1"
    local dst="$2"
    local label="$3"
    local current desired

    mkdir -p "$(dirname -- "${dst}")"

    if [[ -L "${dst}" ]]; then
        current="$(readlink -f -- "${dst}" 2>/dev/null || true)"
        desired="$(readlink -f -- "${src}")"
        if [[ "${current}" == "${desired}" ]]; then
            ok "${label} already linked to repository."
            return 0
        fi
    fi

    if [[ -e "${dst}" || -L "${dst}" ]]; then
        backup_path "${dst}" "$(basename -- "${dst}").before_link"
        rm -f -- "${dst}"
    fi

    ln -s -- "${src}" "${dst}"
    [[ "$(readlink -f -- "${dst}" 2>/dev/null || true)" == "$(readlink -f -- "${src}")" ]] \
        || die "Failed to verify ${label} symlink."
    ok "Installed ${label}: ${dst}"
}

render_clear_calibration_cfg() {
    local tmp desired_hash current_hash previous_hash=""

    mkdir -p "${EDDY_DIR}" "${STATE_DIR}"
    tmp="$(mktemp)"
    cp -- "${SRC_CLEAR_TEMPLATE}" "${tmp}"

    local escaped="${SRC_CLEAR_SCRIPT//\\/\\\\}"
    escaped="${escaped//&/\\&}"
    escaped="${escaped//|/\\|}"
    sed -i "s|__EDDY_CLEAR_SCRIPT__|${escaped}|g" "${tmp}"

    grep -Fq '__EDDY_CLEAR_SCRIPT__' "${tmp}" \
        && { rm -f -- "${tmp}"; die "Clear-calibration template did not render."; }

    desired_hash="$(sha256sum "${tmp}" | awk '{print $1}')"
    [[ -f "${CLEAR_CFG_HASH_FILE}" ]] \
        && previous_hash="$(tr -d '[:space:]' < "${CLEAR_CFG_HASH_FILE}")"

    if [[ ! -e "${DST_CLEAR}" && ! -L "${DST_CLEAR}" ]]; then
        cp -- "${tmp}" "${DST_CLEAR}"
        printf '%s\n' "${desired_hash}" > "${CLEAR_CFG_HASH_FILE}"
        rm -f -- "${tmp}"
        ok "Installed eddy_clear_calibration.cfg."
        return
    fi

    if [[ -L "${DST_CLEAR}" ]]; then
        warn "${DST_CLEAR} is a foreign symlink; preserving it."
        rm -f -- "${CLEAR_CFG_HASH_FILE}" "${tmp}"
        return
    fi

    current_hash="$(sha256sum "${DST_CLEAR}" | awk '{print $1}')"
    if [[ "${current_hash}" == "${desired_hash}" ]]; then
        printf '%s\n' "${desired_hash}" > "${CLEAR_CFG_HASH_FILE}"
        rm -f -- "${tmp}"
        return
    fi

    if [[ -n "${previous_hash}" && "${current_hash}" == "${previous_hash}" ]]; then
        backup_path "${DST_CLEAR}" "eddy_clear_calibration.cfg.before_update"
        cp -- "${tmp}" "${DST_CLEAR}"
        printf '%s\n' "${desired_hash}" > "${CLEAR_CFG_HASH_FILE}"
        rm -f -- "${tmp}"
        ok "Updated managed eddy_clear_calibration.cfg."
        return
    fi

    warn "Existing eddy_clear_calibration.cfg is modified/foreign; preserving it."
    rm -f -- "${CLEAR_CFG_HASH_FILE}" "${tmp}"
}

# ---------------------------------------------------------------------------
# save_variables
# ---------------------------------------------------------------------------

active_section_count() {
    local pattern="$1"
    local count=0
    local file
    for file in "${ACTIVE_CFG_FILES[@]}"; do
        count=$((count + $(grep -Ec "${pattern}" "${file}" 2>/dev/null || true)))
    done
    printf '%d\n' "${count}"
}

ensure_save_variables() {
    local count
    count="$(active_section_count '^[[:space:]]*\[save_variables\][[:space:]]*(#.*)?$')"

    if (( count > 1 )); then
        die "Multiple active [save_variables] sections detected."
    elif (( count == 1 )); then
        ok "Existing [save_variables] preserved."
        return
    fi

    if ! ask_yes_no "No active [save_variables] found. Add one to printer.cfg?" "y"; then
        die "[save_variables] is required by the Wizard."
    fi

    backup_path "${PRINTER_CFG}" "printer.cfg.before_save_variables"
    cat >> "${PRINTER_CFG}" <<EOF

# Added by Klipper Eddy Tap Wizard
[save_variables]
filename: ${CONFIG_DIR}/saved_variables.cfg
EOF
    ok "Added [save_variables] to printer.cfg."
    rebuild_active_tree
}

# ---------------------------------------------------------------------------
# Klipper Python dependencies
# ---------------------------------------------------------------------------

temperature_probe_has_required_behavior() {
    local file="$1"
    [[ -f "${file}" ]] || return 1

    grep -Fq 'TAP_START_Z = 5.' "${file}" \
        && grep -Fq 'tool_zero_z = mpresult.bed_z' "${file}"
}

klipper_temperature_probe_head_exists() {
    git -C "${KLIPPER_DIR}" cat-file -e \
        "HEAD:${KLIPPER_TEMP_PROBE_REL}" 2>/dev/null
}

temperature_probe_head_has_required_behavior() {
    local tmp
    local rc=1

    tmp="$(mktemp)"

    if git -C "${KLIPPER_DIR}" show \
        "HEAD:${KLIPPER_TEMP_PROBE_REL}" > "${tmp}" 2>/dev/null; then
        if temperature_probe_has_required_behavior "${tmp}"; then
            rc=0
        fi
    fi

    rm -f -- "${tmp}"
    return "${rc}"
}

temperature_probe_is_pristine() {
    [[ -f "${DST_TEMP_PROBE}" ]] || return 1

    git -C "${KLIPPER_DIR}" diff --quiet -- "${KLIPPER_TEMP_PROBE_REL}" \
        && git -C "${KLIPPER_DIR}" diff --cached --quiet -- "${KLIPPER_TEMP_PROBE_REL}"
}

temperature_probe_has_staged_change() {
    ! git -C "${KLIPPER_DIR}" diff --cached --quiet -- "${KLIPPER_TEMP_PROBE_REL}"
}

temperature_probe_is_wizard_owned() {
    local recorded
    local current

    [[ -f "${TEMP_HASH_FILE}" ]] || return 1
    [[ -f "${DST_TEMP_PROBE}" ]] || return 1

    recorded="$(tr -d '[:space:]' < "${TEMP_HASH_FILE}")"
    current="$(sha256sum "${DST_TEMP_PROBE}" | awk '{print $1}')"

    [[ -n "${recorded}" && "${current}" == "${recorded}" ]]
}

temperature_probe_matches_current_wizard_patch() {
    [[ -f "${DST_TEMP_PROBE}" ]] || return 1
    cmp -s "${SRC_TEMP_PROBE}" "${DST_TEMP_PROBE}"
}

clear_temperature_probe_patch_state() {
    rm -f -- \
        "${TEMP_HASH_FILE}" \
        "${TEMP_BASE_HASH_FILE}" \
        "${TEMP_BASE_COMMIT_FILE}" \
        2>/dev/null || true
}

record_temperature_probe_base() {
    local base_hash
    local commit

    mkdir -p "${STATE_DIR}"

    base_hash="$(
        git -C "${KLIPPER_DIR}" show "HEAD:${KLIPPER_TEMP_PROBE_REL}" \
            | sha256sum \
            | awk '{print $1}'
    )"
    commit="$(git -C "${KLIPPER_DIR}" rev-parse HEAD)"

    printf '%s\n' "${base_hash}" > "${TEMP_BASE_HASH_FILE}"
    printf '%s\n' "${commit}" > "${TEMP_BASE_COMMIT_FILE}"
}

record_temperature_probe_patch() {
    local desired_hash

    mkdir -p "${STATE_DIR}"
    desired_hash="$(sha256sum "${SRC_TEMP_PROBE}" | awk '{print $1}')"

    printf '%s\n' "${desired_hash}" > "${TEMP_HASH_FILE}"
    record_temperature_probe_base
}

restore_temperature_probe_to_head() {
    local backup_label="$1"

    temperature_probe_has_staged_change \
        && die "temperature_probe.py has staged Git changes. Refusing to overwrite them."

    backup_path "${DST_TEMP_PROBE}" "${backup_label}"

    git -C "${KLIPPER_DIR}" restore \
        --source=HEAD \
        --worktree \
        -- "${KLIPPER_TEMP_PROBE_REL}" \
        || die "Failed to restore Klipper temperature_probe.py from Git HEAD."

    temperature_probe_is_pristine \
        || die "temperature_probe.py is still modified after Git restore."

    clear_temperature_probe_patch_state
}

install_managed_python_file() {
    local src="$1"
    local dst="$2"
    local hash_file="$3"
    local label="$4"
    local desired current previous=""

    mkdir -p "${STATE_DIR}"

    desired="$(sha256sum "${src}" | awk '{print $1}')"
    [[ -f "${hash_file}" ]] && previous="$(tr -d '[:space:]' < "${hash_file}")"

    if [[ ! -e "${dst}" && ! -L "${dst}" ]]; then
        cp -- "${src}" "${dst}"
        printf '%s\n' "${desired}" > "${hash_file}"
        ok "Installed ${label}."
        return
    fi

    if [[ -L "${dst}" ]]; then
        warn "${label} is a symlink managed elsewhere; preserving it."
        rm -f -- "${hash_file}"
        return
    fi

    current="$(sha256sum "${dst}" | awk '{print $1}')"
    if [[ "${current}" == "${desired}" ]]; then
        printf '%s\n' "${desired}" > "${hash_file}"
        ok "${label} already current."
        return
    fi

    if [[ -n "${previous}" && "${current}" == "${previous}" ]]; then
        backup_path "${dst}" "${label}.before_update"
        cp -- "${src}" "${dst}"
        printf '%s\n' "${desired}" > "${hash_file}"
        ok "Updated Wizard-managed ${label}."
        return
    fi

    warn "${label} differs from the Wizard copy and is not proven Wizard-owned."
    info "Preserving the existing file."
    rm -f -- "${hash_file}"
}

install_temperature_probe_compatibility() {
    local desired_hash
    local current_hash

    mkdir -p "${STATE_DIR}"

    git -C "${KLIPPER_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "Klipper directory is not a Git worktree: ${KLIPPER_DIR}"

    klipper_temperature_probe_head_exists \
        || die "Klipper HEAD does not contain ${KLIPPER_TEMP_PROBE_REL}."

    [[ -f "${DST_TEMP_PROBE}" ]] \
        || die "Installed Klipper temperature_probe.py is missing: ${DST_TEMP_PROBE}"

    desired_hash="$(sha256sum "${SRC_TEMP_PROBE}" | awk '{print $1}')"

    # ------------------------------------------------------------
    # Native Klipper now contains the behavior required by the Wizard.
    # The compatibility patch must no longer remain in the Klipper tree.
    # ------------------------------------------------------------
    if temperature_probe_head_has_required_behavior; then

        if temperature_probe_is_wizard_owned \
           || temperature_probe_matches_current_wizard_patch; then

            info "Native Klipper now provides the required Eddy Tap thermal behavior."
            info "Removing the obsolete Wizard temperature_probe.py compatibility patch."

            restore_temperature_probe_to_head \
                "temperature_probe.py.before_native_restore"

            ok "Restored native Klipper temperature_probe.py."

        elif temperature_probe_is_pristine; then

            clear_temperature_probe_patch_state

        elif temperature_probe_has_required_behavior "${DST_TEMP_PROBE}"; then

            warn "temperature_probe.py is locally modified but already contains the required Eddy Tap behavior."
            info "Preserving the compatible custom file."
            clear_temperature_probe_patch_state
            return 0

        else

            error "Native Klipper provides the required Eddy Tap behavior, but temperature_probe.py has unknown local modifications."
            die "Restore or review the custom Klipper file before continuing."

        fi

        ok "Native Klipper temperature_probe.py supports Eddy Tap thermal calibration."
        return 0
    fi

    # ------------------------------------------------------------
    # Mainline Klipper still lacks the required behavior.
    # Maintain or install the Wizard compatibility patch.
    # ------------------------------------------------------------

    if temperature_probe_is_wizard_owned; then
        current_hash="$(sha256sum "${DST_TEMP_PROBE}" | awk '{print $1}')"

        if [[ "${current_hash}" == "${desired_hash}" ]]; then
            [[ -f "${TEMP_BASE_HASH_FILE}" && -f "${TEMP_BASE_COMMIT_FILE}" ]] \
                || record_temperature_probe_base

            ok "Eddy Tap temperature_probe.py compatibility patch is current."
            warn "Klipper will appear locally modified while this compatibility patch is required."
            return 0
        fi

        temperature_probe_has_staged_change \
            && die "temperature_probe.py has staged Git changes. Refusing to overwrite them."

        backup_path \
            "${DST_TEMP_PROBE}" \
            "temperature_probe.py.before_patch_update"

        cp -- "${SRC_TEMP_PROBE}" "${DST_TEMP_PROBE}"
        printf '%s\n' "${desired_hash}" > "${TEMP_HASH_FILE}"
        [[ -f "${TEMP_BASE_HASH_FILE}" && -f "${TEMP_BASE_COMMIT_FILE}" ]] \
            || record_temperature_probe_base

        ok "Updated Wizard-managed temperature_probe.py compatibility patch."
        warn "Klipper will appear locally modified while this compatibility patch is required."
        return 0
    fi

    # An exact current Wizard patch may exist after state metadata was deleted
    # or after an older installer version installed the file.  It is safe to
    # adopt because the installed bytes exactly match the bundled patch.
    if temperature_probe_matches_current_wizard_patch; then
        record_temperature_probe_patch
        ok "Existing Wizard temperature_probe.py patch recognized and adopted."
        warn "Klipper will appear locally modified while this compatibility patch is required."
        return 0
    fi

    # Another implementation may already provide the same required behavior.
    # Preserve it, but do not claim ownership.
    if temperature_probe_has_required_behavior "${DST_TEMP_PROBE}"; then
        warn "Existing temperature_probe.py already contains the required Eddy Tap behavior."
        info "Preserving the compatible custom file."
        clear_temperature_probe_patch_state
        return 0
    fi

    # We only replace a pristine file that exactly belongs to the current
    # Klipper HEAD.  Unknown local modifications are never overwritten.
    if ! temperature_probe_is_pristine; then
        error "Klipper temperature_probe.py is already locally modified."
        error "The required Eddy Tap thermal behavior is not present."
        die "Refusing to overwrite an unknown Klipper modification."
    fi

    # First-time compatibility patch installation.
    backup_path \
        "${DST_TEMP_PROBE}" \
        "temperature_probe.py.before_eddy_patch"

    record_temperature_probe_base
    cp -- "${SRC_TEMP_PROBE}" "${DST_TEMP_PROBE}"
    printf '%s\n' "${desired_hash}" > "${TEMP_HASH_FILE}"

    ok "Installed Eddy Tap temperature_probe.py compatibility patch."
    info "Original Klipper temperature_probe.py was backed up."
    warn "Klipper will appear locally modified while this compatibility patch is required."
    warn "Use 'Remove Eddy Patch for Klipper Update' before updating Klipper."
}

prepare_klipper_update() {
    printf '\n%sRemove Eddy Patch for Klipper Update%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"
    printf '%s\n' "The Eddy Tap Wizard may use a temporary modification to Klipper's"
    printf '%s\n' "temperature_probe.py so Tap-based thermal calibration works correctly."
    printf '\n'
    printf '%s\n' "This modification can cause Klipper to appear dirty and can prevent"
    printf '%s\n' "normal Klipper updates."
    printf '\n'
    printf '%s\n' "This option will:"
    printf '%s\n' "  - Back up the currently installed Wizard patch, when present"
    printf '%s\n' "  - Restore Klipper's own temperature_probe.py from the current Git HEAD"
    printf '%s\n' "  - Leave your Eddy configuration and saved calibration unchanged"
    printf '\n'
    printf '%s\n' "After updating Klipper, run this installer again and choose"
    printf '%s\n' "Install / Repair. The Eddy compatibility patch will only be reinstalled"
    printf '%s\n' "if the updated Klipper version still requires it."
    printf '\n'

    if ! ask_yes_no "Remove the Eddy compatibility patch and prepare Klipper for update?" "n"; then
        info "No changes were made."
        return 0
    fi

    git -C "${KLIPPER_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "Klipper directory is not a Git worktree: ${KLIPPER_DIR}"

    klipper_temperature_probe_head_exists \
        || die "Klipper HEAD does not contain ${KLIPPER_TEMP_PROBE_REL}."

    if temperature_probe_is_wizard_owned \
       || temperature_probe_matches_current_wizard_patch; then

        info "Wizard-managed temperature_probe.py compatibility patch detected."
        restore_temperature_probe_to_head \
            "temperature_probe.py.before_klipper_update"
        ok "Restored Klipper's native temperature_probe.py."
        ok "Eddy Tap compatibility patch removed."

    elif temperature_probe_is_pristine; then

        clear_temperature_probe_patch_state
        ok "Klipper temperature_probe.py is already pristine."

    else

        error "temperature_probe.py contains a modification that is not proven Wizard-owned."
        die "Refusing to remove an unknown Klipper modification."

    fi

    if [[ -n "$(git -C "${KLIPPER_DIR}" status --porcelain)" ]]; then
        warn "Other local changes still exist in the Klipper repository."
        info "Moonraker may still report Klipper as dirty."
        git -C "${KLIPPER_DIR}" status --short
    else
        ok "Klipper Git working tree is clean."
    fi

    printf '\n'
    info "Klipper may now be updated normally."
    info "After the Klipper update, run this installer again with Install / Repair."
    if [[ "${BACKUP_CREATED}" -eq 1 ]]; then
        info "Backups: ${BACKUP_DIR}"
    fi
}

restore_temperature_probe_for_uninstall() {
    if temperature_probe_is_wizard_owned \
       || temperature_probe_matches_current_wizard_patch; then

        info "Restoring native Klipper temperature_probe.py before uninstall."
        restore_temperature_probe_to_head \
            "temperature_probe.py.before_wizard_uninstall"
        ok "Native Klipper temperature_probe.py restored."
        return 0
    fi

    if temperature_probe_is_pristine; then
        clear_temperature_probe_patch_state
        return 0
    fi

    if [[ -f "${TEMP_HASH_FILE}" \
       || -f "${TEMP_BASE_HASH_FILE}" \
       || -f "${TEMP_BASE_COMMIT_FILE}" ]]; then
        warn "temperature_probe.py changed after the Wizard patch was installed."
        warn "The custom Klipper file will be preserved because ownership can no longer be proven."
    fi

    clear_temperature_probe_patch_state
}

install_python_dependencies() {
    install_managed_python_file \
        "${SRC_GCODE_SHELL_COMMAND}" \
        "${DST_GCODE_SHELL_COMMAND}" \
        "${GCODE_SHELL_HASH_FILE}" \
        "gcode_shell_command.py"

    install_temperature_probe_compatibility
}

# ---------------------------------------------------------------------------
# Eddy-NG / BTT-style migration handling
# ---------------------------------------------------------------------------

handle_non_native_family() {
    case "${EDDY_STATE}" in
        eddy_ng)
            printf '\n%sEddy-NG migration candidate detected%s\n' "${BOLD}" "${RESET}"
            printf 'Source:\n'
            local record file section name
            record="${ACTIVE_EDDY_NG_RECORDS[0]}"
            IFS='|' read -r file section name <<< "${record}"
            printf '  %s\n  [%s]\n' "${file}" "${section}"
            printf '\nThe installer can identify this configuration, but automatic conversion\n'
            printf 'of Eddy-NG implementation-specific tap/homing/calibration settings is\n'
            printf 'intentionally not guessed.\n\n'
            printf 'Portable values that may be reused manually include MCU transport,\n'
            printf 'probe X/Y offsets, bed_mesh geometry, and zero_reference_position.\n'
            die "Eddy-NG conversion map must be explicitly defined before automatic migration is enabled."
            ;;
        conflict)
            die "Both native Eddy and Eddy-NG are active. Resolve the conflict before migration."
            ;;
        multiple_native)
            die "Multiple active native Eddy probes detected. The Wizard cannot choose one safely."
            ;;
        multiple_ng)
            die "Multiple active Eddy-NG probes detected. The Wizard cannot choose one safely."
            ;;
    esac

    if (( ${#BTT_STYLE_FILES[@]} > 0 )); then
        warn "BTT/Rappetor-style helper macros were detected."
        info "The underlying [probe_eddy_current] may already be mainline-native."
        info "The native hardware section can be normalized, but obsolete BTT helper macros are not deleted automatically."
    fi
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

verify_installation() {
    local count

    rebuild_active_tree

    path_is_active "${DST_EDDY}" \
        || die "Verification: canonical eddy.cfg is not active."
    path_is_active "${DST_MACROS}" \
        || die "Verification: eddy_macros.cfg is not active."
    path_is_active "${DST_WIZARD}" \
        || die "Verification: eddy_setup_wizard.cfg is not active."
    path_is_active "${DST_CLEAR}" \
        || die "Verification: eddy_clear_calibration.cfg is not active."

    count="$(active_section_count '^[[:space:]]*\[probe_eddy_current[[:space:]]+[^]]+\]')"
    (( count == 1 )) \
        || die "Verification requires exactly one active [probe_eddy_current ...]; found ${count}."

    count="$(active_section_count '^[[:space:]]*\[bed_mesh\][[:space:]]*(#.*)?$')"
    (( count == 1 )) \
        || die "Verification requires exactly one active [bed_mesh]; found ${count}."

    locate_active_bed_mesh || die "Verification could not locate [bed_mesh]."
    section_has_option "${BED_MESH_FILE}" "bed_mesh" "zero_reference_position" \
        || die "Verification: [bed_mesh] is missing zero_reference_position."

    count="$(active_section_count '^[[:space:]]*\[save_variables\][[:space:]]*(#.*)?$')"
    (( count == 1 )) \
        || die "Verification requires exactly one active [save_variables]; found ${count}."

    if (( ${#MISSING_INCLUDE_RECORDS[@]} > 0 )); then
        error "Verification found missing include targets:"
        local record file spec
        for record in "${MISSING_INCLUDE_RECORDS[@]}"; do
            IFS='|' read -r file spec <<< "${record}"
            printf '  %s -> [include %s]\n' "${file}" "${spec}" >&2
        done
        die "Fix missing include targets before Klipper is restarted."
    fi

    temperature_probe_has_required_behavior "${DST_TEMP_PROBE}" \
        || die "Verification: temperature_probe.py does not contain the required Eddy Tap thermal behavior."

    ok "Required Eddy Tap temperature_probe.py behavior verified."
    ok "Installation verification passed."
}

restart_klipper() {
    command -v systemctl >/dev/null 2>&1 \
        || die "systemctl not found; restart Klipper manually."

    info "Restarting Klipper..."
    sudo systemctl restart klipper \
        || die "Klipper restart failed. Review the configuration before retrying."
    ok "Klipper restarted."
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

remove_expected_symlink() {
    local path="$1"
    local source="$2"

    [[ -L "${path}" ]] || return 0
    [[ "$(readlink -f -- "${path}" 2>/dev/null || true)" == "$(readlink -f -- "${source}")" ]] \
        || { warn "Foreign symlink preserved: ${path}"; return 0; }

    backup_path "${path}" "$(basename -- "${path}").before_uninstall"
    rm -f -- "${path}"
    ok "Removed Wizard symlink: ${path}"
}

uninstall_wizard() {
    printf '\n%sUninstall Eddy Tap Wizard%s\n' "${BOLD}" "${RESET}"
    printf 'The canonical user-owned eddy/eddy.cfg will be preserved.\n'
    printf 'Native Eddy hardware configuration and saved calibration are preserved.\n\n'

    ask_yes_no "Continue?" "n" || exit 0

    # temperature_probe.py is a tracked Klipper source file.  If the Wizard
    # owns the compatibility patch, return Klipper to Git HEAD before removing
    # the ownership metadata.
    restore_temperature_probe_for_uninstall

    if grep -Eq '^[[:space:]]*\[include[[:space:]]+eddy/eddy\.cfg\]' "${PRINTER_CFG}"; then
        backup_path "${PRINTER_CFG}" "printer.cfg.before_eddy_wizard_uninstall"
        sed -i -E \
            '/^[[:space:]]*# >>> Klipper Eddy Tap Wizard >>>[[:space:]]*$/,/^[[:space:]]*# <<< Klipper Eddy Tap Wizard <<<[[:space:]]*$/d' \
            "${PRINTER_CFG}"
        sed -i -E \
            '/^[[:space:]]*\[include[[:space:]]+eddy\/eddy\.cfg\][[:space:]]*(#.*)?$/d' \
            "${PRINTER_CFG}"
    fi

    if [[ -f "${DST_EDDY}" ]]; then
        backup_path "${DST_EDDY}" "eddy.cfg.before_wizard_uninstall"
        # Keep native/user config; remove only Wizard support includes.
        sed -i -E \
            -e '/^[[:space:]]*\[include[[:space:]]+eddy_setup_wizard\.cfg\][[:space:]]*(#.*)?$/d' \
            -e '/^[[:space:]]*\[include[[:space:]]+eddy_macros\.cfg\][[:space:]]*(#.*)?$/d' \
            -e '/^[[:space:]]*\[include[[:space:]]+eddy_clear_calibration\.cfg\][[:space:]]*(#.*)?$/d' \
            "${DST_EDDY}"
    fi

    remove_expected_symlink "${DST_MACROS}" "${SRC_MACROS}"
    remove_expected_symlink "${DST_WIZARD}" "${SRC_WIZARD}"

    info "Preserving ${DST_EDDY}"
    info "Preserving gcode_shell_command.py by default."
    clear_temperature_probe_patch_state
    rm -f -- "${GCODE_SHELL_HASH_FILE}" "${CLEAR_CFG_HASH_FILE}" 2>/dev/null || true

    rebuild_active_tree
    restart_klipper

    ok "Wizard integration removed. Native/user Eddy configuration preserved."
    [[ "${BACKUP_CREATED}" -eq 1 ]] && info "Backups: ${BACKUP_DIR}"
    exit 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "${PREPARE_KLIPPER_UPDATE}" -eq 1 ]]; then
    prepare_klipper_update
    exit 0
fi

rebuild_active_tree
scan_all_cfg_files
scan_eddy_families
report_discovery

if [[ "${UNINSTALL}" -eq 1 ]]; then
    uninstall_wizard
fi

if [[ "${DETECT_ONLY}" -eq 1 ]]; then
    printf '\n%sActive config tree%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"
    printf '  %s\n' "${ACTIVE_CFG_FILES[@]}"
    printf '\nDetection complete. No files were modified.\n'
    exit 0
fi

handle_non_native_family

# Create canonical directory before installing support files.
mkdir -p "${EDDY_DIR}"

# First validate an existing bed_mesh. If none exists, fresh canonical
# generation will create/activate the personalized template [bed_mesh].
validate_zero_reference_position || true

case "${EDDY_STATE}" in
    none)
        if [[ -f "${DST_EDDY}" ]]; then
            if grep -Eq '^[[:space:]]*\[probe_eddy_current[[:space:]]+[^]]+\]' "${DST_EDDY}"; then
                info "Inactive canonical eddy.cfg found; preserving and activating it."
            else
                die "Existing ${DST_EDDY} does not contain a native Eddy probe."
            fi
        else
            generate_fresh_eddy_cfg
        fi
        ;;
    native)
        normalize_existing_native
        ;;
esac

# Support files always use the canonical /eddy/ directory.
install_cfg_link "${SRC_MACROS}" "${DST_MACROS}" "eddy_macros.cfg"
install_cfg_link "${SRC_WIZARD}" "${DST_WIZARD}" "eddy_setup_wizard.cfg"
render_clear_calibration_cfg
ensure_internal_wizard_includes
ensure_canonical_printer_include

# Now that canonical eddy.cfg is active, re-evaluate bed_mesh. A fresh install
# may have just activated the template's personalized bed_mesh.
rebuild_active_tree
if ! validate_zero_reference_position; then
    die "No active [bed_mesh] exists after canonical Eddy setup."
fi

# Optional user-config consolidation. zero_reference_position remains mandatory
# whether [bed_mesh] is moved or kept in its original file.
offer_section_consolidation

ensure_save_variables
install_python_dependencies
validate_tap_negative_z_travel
verify_installation

if (( ${#BTT_STYLE_FILES[@]} > 0 )); then
    warn "BTT-style helper content remains elsewhere in the config directory."
    warn "Review obsolete BTT macros after confirming the native Wizard works."
fi

if (( ${#INACTIVE_EDDY_FILES[@]} > 0 )); then
    info "Inactive Eddy-related files were left untouched."
fi

restart_klipper

printf '\n%sInstallation complete.%s\n' "${GREEN}${BOLD}" "${RESET}"
printf 'Canonical Eddy directory:\n  %s\n' "${EDDY_DIR}"

if [[ "${BACKUP_CREATED}" -eq 1 ]]; then
    printf 'Backups:\n  %s\n' "${BACKUP_DIR}"
fi

printf '\n%sNext step:%s\n' "${BOLD}" "${RESET}"
printf 'Run the following command in your Klipper console to begin Eddy calibration:\n\n'
printf '  EDDY_SETUP\n\n'
