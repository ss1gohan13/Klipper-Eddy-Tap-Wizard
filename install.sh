#!/usr/bin/env bash
#
# Klipper Eddy Tap Wizard Installer - rough draft
#
# This draft extends the existing installer with:
#   - active Klipper config-tree discovery
#   - native Eddy / BTT-style Eddy / Eddy-NG detection
#   - legacy BIGTREETECH Klipper-fork warning
#   - Full / Minimal eddy.cfg template generation for fresh installs
#   - preservation of an existing user-owned eddy.cfg
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
#   eddy.cfg is USER-OWNED once generated. Normal updates never overwrite it.
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
SRC_TEMP_PROBE="${SCRIPT_DIR}/klipper/klippy/extras/temperature_probe.py"

DST_MACROS="${CONFIG_DIR}/eddy_macros.cfg"
DST_WIZARD="${CONFIG_DIR}/eddy_setup_wizard.cfg"
DST_EDDY="${CONFIG_DIR}/eddy.cfg"
DST_TEMP_PROBE="${KLIPPER_EXTRAS_DIR}/temperature_probe.py"
PRINTER_CFG="${CONFIG_DIR}/printer.cfg"

STATE_DIR="${XDG_CONFIG_HOME:-${HOME_DIR}/.config}/${PROJECT_SLUG}"
TEMP_HASH_FILE="${STATE_DIR}/temperature_probe.installed.sha256"

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
CONFIG_MODE=""

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
  - detects native Eddy, BTT-style Eddy, Eddy-NG, and common conflicts
  - generates ~/printer_data/config/eddy.cfg from a Full or Minimal template
    on a fresh setup
  - never overwrites an existing eddy.cfg during a normal install/update
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
    [[ -f "${SRC_TEMP_PROBE}" ]] || die "Repository file missing: ${SRC_TEMP_PROBE}"

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
EDDY_STATE="none"
BTT_STYLE=0

scan_eddy_sections() {
    local file
    local result
    local line_no
    local text
    local probe_name

    NATIVE_EDDY_RECORDS=()
    EDDY_NG_RECORDS=()
    BTT_STYLE=0

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
        if path_is_active "${DST_EDDY}" \
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

report_eddy_state() {
    printf '\n%sEddy configuration discovery%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"

    case "${EDDY_STATE}" in
        wizard)
            ok "Existing Klipper Eddy Tap Wizard configuration detected."
            print_probe_record "${NATIVE_EDDY_RECORDS[0]}"
            info "User configuration: ${DST_EDDY}"
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
# Initial discovery
# ---------------------------------------------------------------------------

rebuild_cfg_tree
scan_eddy_sections
check_klipper_origin
report_eddy_state

if [[ "${DETECT_ONLY}" -eq 1 ]]; then
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

    printf '\nBed reference / calibration position\n'
    ask_number "Bed center/reference X"
    bed_center_x="${ANSWER}"
    ask_number "Bed center/reference Y"
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
    printf 'Bed center/reference:        X=%s Y=%s\n' "${bed_center_x}" "${bed_center_y}"
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

    ok "Generated user-owned Eddy configuration: ${DST_EDDY}"
}

# ---------------------------------------------------------------------------
# Choose installation mode from discovered state
# ---------------------------------------------------------------------------

case "${EDDY_STATE}" in
    wizard)
        CONFIG_MODE="generated"
        ok "Existing ${DST_EDDY} will be preserved exactly as-is."
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

install_cfg_link "${SRC_MACROS}" "${DST_MACROS}" "eddy_macros.cfg"
install_cfg_link "${SRC_WIZARD}" "${DST_WIZARD}" "eddy_setup_wizard.cfg"

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

if [[ "${CONFIG_MODE}" == "generated" ]]; then
    [[ -f "${DST_EDDY}" ]] || die "Generated-mode installation selected but ${DST_EDDY} does not exist."
    ensure_generated_eddy_include
elif [[ "${CONFIG_MODE}" == "existing_eddy_file" ]]; then
    [[ -f "${DST_EDDY}" ]] || die "Existing-eddy-file mode selected but ${DST_EDDY} does not exist."
    ensure_existing_eddy_file_include
    # Because this was not generated from our template, do not assume it
    # contains the wizard includes. Ensure them independently.
    ensure_direct_wizard_includes
else
    ensure_direct_wizard_includes
fi

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

# ---------------------------------------------------------------------------
# Final checks
# ---------------------------------------------------------------------------

rebuild_cfg_tree
scan_eddy_sections

printf '\n%sInstallation summary%s\n' "${BOLD}" "${RESET}"
printf '%s\n' "------------------------------------------------------------"

if [[ -L "${DST_MACROS}" ]]; then
    ok "eddy_macros.cfg installed."
else
    warn "eddy_macros.cfg is not a symlink."
fi

if [[ -L "${DST_WIZARD}" ]]; then
    ok "eddy_setup_wizard.cfg installed."
else
    warn "eddy_setup_wizard.cfg is not a symlink."
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
