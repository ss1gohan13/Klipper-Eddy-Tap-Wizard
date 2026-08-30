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
#   - fresh USB, CAN, and Eddy Coil (existing-MCU I2C) configuration support
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
UNINSTALL_WIZARD=0
FULL_UNINSTALL=0
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
  ./install.sh --uninstall-wizard
  ./install.sh --uninstall-all
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

Fresh configuration generation remains interactive because hardware connection,
I2C identity, probe-offset, and geometry information cannot be safely guessed.
EOF
}

# ---------------------------------------------------------------------------
# Arguments / menu
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update) DO_UPDATE=1; shift ;;
        --detect-only) DETECT_ONLY=1; shift ;;

        --uninstall|--uninstall-wizard)
            UNINSTALL_WIZARD=1
            shift
            ;;

        --uninstall-all)
            FULL_UNINSTALL=1
            shift
            ;;

        --prepare-klipper-update)
            PREPARE_KLIPPER_UPDATE=1
            shift
            ;;

        -y|--yes) AUTO_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

selected_actions=$(( \
        DO_UPDATE
        + DETECT_ONLY
        + UNINSTALL_WIZARD
        + FULL_UNINSTALL
        + PREPARE_KLIPPER_UPDATE
    ))

(( selected_actions <= 1 )) \
    || die "--update, --detect-only, --uninstall-wizard, --uninstall-all, and --prepare-klipper-update are mutually exclusive."

if [[ "${AFTER_PULL}" -ne 1 \
   && "${DO_UPDATE}" -eq 0 \
   && "${DETECT_ONLY}" -eq 0 \
   && "${UNINSTALL_WIZARD}" -eq 0 \
   && "${FULL_UNINSTALL}" -eq 0 \
   && "${PREPARE_KLIPPER_UPDATE}" -eq 0 ]]; then
    clear_screen

	printf '\n%sChoose action%s\n' "${BOLD}" "${RESET}"
	printf '%s\n' "------------------------------------------------------------"
	printf '  1) Install / Repair\n'
	printf '  2) Update Eddy Wizard\n'
	printf '  3) Uninstall Wizard Only\n'
	printf '  4) Full Eddy Uninstall\n'
	printf '  5) Detect only\n'
	printf '  6) Remove Eddy Patch for Klipper Update\n'
	printf '  7) Exit\n'

	ask_choice "Action" "1" "1" "7"

	case "${ANSWER}" in
		1) ;;
		2) DO_UPDATE=1 ;;
		3) UNINSTALL_WIZARD=1 ;;
		4) FULL_UNINSTALL=1 ;;
		5) DETECT_ONLY=1 ;;
		6) PREPARE_KLIPPER_UPDATE=1 ;;
		7)
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

if [[ "${DETECT_ONLY}" -eq 0 \
   && "${UNINSTALL_WIZARD}" -eq 0 \
   && "${FULL_UNINSTALL}" -eq 0 \
   && "${PREPARE_KLIPPER_UPDATE}" -eq 0 ]]; then
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


collect_active_mcu_names() {
    # Print unique active Klipper MCU object names.  The unnamed [mcu] section
    # is represented by the object name "mcu"; [mcu EBBCan] becomes "EBBCan".
    python3 - "${ACTIVE_CFG_FILES[@]}" <<'PY'
import re, sys
rx = re.compile(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$')
seen = set()
for path in sys.argv[1:]:
    try:
        fh = open(path, encoding='utf-8')
    except OSError:
        continue
    with fh:
        for line in fh:
            m = rx.match(line.rstrip('\n'))
            if not m:
                continue
            section = m.group(1).strip()
            low = section.lower()
            if low == 'mcu':
                name = 'mcu'
            elif low.startswith('mcu '):
                name = section.split(None, 1)[1].strip()
            else:
                continue
            key = name.lower()
            if key not in seen:
                seen.add(key)
                print(name)
PY
}

ask_active_mcu_name() {
    local -a names=()
    local selection max_choice selected section_name

    mapfile -t names < <(collect_active_mcu_names)

    printf '\nExisting MCU for Eddy Coil I2C\n'
    info "Eddy Coil does not create a dedicated [mcu eddy] section."
    info "Select the already-configured MCU/toolboard whose I2C port is wired to the coil."

    if (( ${#names[@]} > 0 )); then
        local i
        for i in "${!names[@]}"; do
            printf '  %d) %s\n' "$((i + 1))" "${names[$i]}"
        done
        max_choice=$(( ${#names[@]} + 1 ))
        printf '  %d) Enter another active MCU name\n' "${max_choice}"
        ask_choice "I2C MCU" "1" "1" "${max_choice}"
        selection="${ANSWER}"

        if (( selection <= ${#names[@]} )); then
            selected="${names[$((selection - 1))]}"
        else
            ask_required "Existing MCU name (for example: mcu, EBBCan, toolhead)"
            selected="${ANSWER}"
        fi
    else
        warn "No active [mcu ...] sections were discovered automatically."
        ask_required "Existing MCU name (for example: mcu, EBBCan, toolhead)"
        selected="${ANSWER}"
    fi

    if [[ "${selected,,}" == "mcu" ]]; then
        section_name="mcu"
    else
        section_name="mcu ${selected}"
    fi

    section_record_for_active_name "${section_name}" >/dev/null \
        || die "Active [${section_name}] was not found. Eddy Coil must reference an existing active MCU."

    ANSWER="${selected}"
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
    newline = '\n' if s.endswith('\n') else ''
    body = s[:-1] if newline else s
    m = re.match(r'^(\s*)#( ?)(.*)$', body)
    if m:
        lines[i] = m.group(1) + m.group(3) + newline

with open(output, 'w', encoding='utf-8') as f:
    f.writelines(lines)
PY
    cat "${tmp}" > "${DST_EDDY}"
    rm -f -- "${tmp}"
}

generate_fresh_eddy_cfg() {
    local connection serial_value="" can_uuid=""
    local coil_mcu="" coil_i2c_bus=""
    local x_offset y_offset
    local zero_x zero_y
    local mesh_min_x="" mesh_min_y="" mesh_max_x="" mesh_max_y=""
    local cal_bed_temp="" cal_extruder_temp="" max_validation_temp=""
    local tmp_cfg
    local create_bed_mesh=0

    [[ "${AUTO_YES}" -eq 0 && -t 0 ]] \
        || die "Fresh Eddy configuration requires interactive input."

    printf '\n%sCreate canonical Eddy configuration%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "Destination: ${DST_EDDY}"

    printf '\nEddy hardware / connection:\n'
    printf '  1) USB-connected Eddy / Eddy Duo\n'
    printf '  2) CAN-connected Eddy / Eddy Duo\n'
    printf '  3) Eddy Coil - I2C on an existing printer/toolboard MCU\n'
    ask_choice "Hardware" "1" "1" "3"
    connection="${ANSWER}"

    case "${connection}" in
        1)
            ask_required "Eddy USB serial path"
            serial_value="${ANSWER}"
            ;;
        2)
            while true; do
                ask_required "Eddy CAN UUID"
                can_uuid="${ANSWER}"
                validate_can_uuid "${can_uuid}" && break
                warn "Expected a hexadecimal CAN UUID."
            done
            ;;
        3)
            printf '\n%sEddy Coil configuration%s\n' "${BOLD}" "${RESET}"
            info "Eddy Coil is an I2C sensor and does not have its own USB/CAN MCU connection."
            ask_active_mcu_name
            coil_mcu="${ANSWER}"
            ask_required "I2C bus used by Eddy Coil on ${coil_mcu} (for example: i2c1, i2c1a, i2c0f)"
            coil_i2c_bus="${ANSWER}"
            ;;
    esac

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

    if [[ "${connection}" -ne 3 ]]; then
        printf '\nTemperature compensation settings\n'
        ask_number "Calibration bed temperature" "95"
        cal_bed_temp="${ANSWER}"
        ask_number "Calibration extruder temperature" "150"
        cal_extruder_temp="${ANSWER}"
        ask_number "Maximum validation temperature" "100"
        max_validation_temp="${ANSWER}"
    fi

    printf '\n%sConfiguration summary%s\n' "${BOLD}" "${RESET}"
    printf 'Destination:                  %s\n' "${DST_EDDY}"
    case "${connection}" in
        1)
            printf 'Hardware:                     USB-connected Eddy\n'
            printf 'Eddy serial:                  %s\n' "${serial_value}"
            ;;
        2)
            printf 'Hardware:                     CAN-connected Eddy\n'
            printf 'Eddy CAN UUID:                %s\n' "${can_uuid}"
            ;;
        3)
            printf 'Hardware:                     Eddy Coil (existing-MCU I2C)\n'
            printf 'I2C MCU:                      %s\n' "${coil_mcu}"
            printf 'I2C bus:                      %s\n' "${coil_i2c_bus}"
            printf 'Temperature compensation:     not generated for Eddy Coil\n'
            ;;
    esac
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

    case "${connection}" in
        1)
            replace_placeholder "${tmp_cfg}" "CALIBRATION_BED_TEMP" "${cal_bed_temp}"
            replace_placeholder "${tmp_cfg}" "CALIBRATION_EXTRUDER_TEMP" "${cal_extruder_temp}"
            replace_placeholder "${tmp_cfg}" "MAX_VALIDATION_TEMP" "${max_validation_temp}"
            replace_placeholder "${tmp_cfg}" "EDDY_SERIAL" "${serial_value}"
            ;;
        2)
            replace_placeholder "${tmp_cfg}" "CALIBRATION_BED_TEMP" "${cal_bed_temp}"
            replace_placeholder "${tmp_cfg}" "CALIBRATION_EXTRUDER_TEMP" "${cal_extruder_temp}"
            replace_placeholder "${tmp_cfg}" "MAX_VALIDATION_TEMP" "${max_validation_temp}"
            replace_placeholder "${tmp_cfg}" "EDDY_CANBUS_UUID" "${can_uuid}"
            sed -i -E 's|^serial:[[:space:]].*$|#serial: {{EDDY_SERIAL}}|' "${tmp_cfg}"
            sed -i -E 's|^restart_method:[[:space:]]*command[[:space:]]*$|#restart_method: command|' "${tmp_cfg}"
            sed -i -E 's|^#canbus_uuid:[[:space:]]*|canbus_uuid: |' "${tmp_cfg}"
            ;;
        3)
            # Eddy Coil is only the LDC coil/sensor.  It uses an existing MCU's
            # I2C bus, so remove the dedicated-board MCU/temperature blocks while
            # preserving the remainder of the canonical template (including the
            # commented [bed_mesh] and optional printer-section examples).
            python3 - "${tmp_cfg}" "${coil_mcu}" "${coil_i2c_bus}" <<'PY'
import re
import sys

path, coil_mcu, coil_i2c_bus = sys.argv[1:]
with open(path, encoding='utf-8') as f:
    lines = f.readlines()


def label_index(label):
    target = '# ' + label
    for i, line in enumerate(lines):
        if line.strip() == target:
            return i
    raise SystemExit(f"Coil template render failed: heading '{label}' was not found")


def banner_start(label):
    i = label_index(label)
    if i > 0 and re.match(r'^\s*#{20,}\s*$', lines[i - 1].rstrip('\n')):
        return i - 1
    return i

# Remove the dedicated Eddy MCU + MCU-temperature blocks, but retain the Eddy
# Probe heading and probe section that follow them.
start_mcu = banner_start('Eddy MCU')
start_probe = banner_start('Eddy Probe')
if start_probe <= start_mcu:
    raise SystemExit('Coil template render failed: unexpected Eddy MCU/Probe block order')
lines = lines[:start_mcu] + lines[start_probe:]

# Recalculate indexes after the first splice, then remove the dedicated
# temperature-compensation block.  Eddy Coil has no eddy:gpio26 temperature
# input, so the Wizard should naturally treat thermal calibration as N/A.
start_temp = banner_start('Temperature Calibration Settings')
start_bed = banner_start('Bed Mesh')
if start_bed <= start_temp:
    raise SystemExit('Coil template render failed: unexpected temperature/bed-mesh block order')
lines = lines[:start_temp] + lines[start_bed:]

mcu_rx = re.compile(r'^\s*i2c_mcu\s*:\s*.*$', re.IGNORECASE)
bus_rx = re.compile(r'^\s*i2c_bus\s*:\s*.*$', re.IGNORECASE)
mcu_done = False
bus_done = False
for i, line in enumerate(lines):
    if mcu_rx.match(line.rstrip('\n')):
        lines[i] = f'i2c_mcu: {coil_mcu}\n'
        mcu_done = True
    elif bus_rx.match(line.rstrip('\n')):
        lines[i] = f'i2c_bus: {coil_i2c_bus}\n'
        bus_done = True

if not (mcu_done and bus_done):
    raise SystemExit('Coil template render failed: probe i2c_mcu/i2c_bus options were not found')

with open(path, 'w', encoding='utf-8') as f:
    f.writelines(lines)
PY
            ;;
    esac

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

    if [[ "${connection}" -eq 3 ]]; then
        info "Eddy Coil uses active [mcu ${coil_mcu}] I2C settings; that MCU remains in its existing config file."
        info "No [temperature_probe eddy] was generated, so thermal compensation will be treated as not applicable."
    fi

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

    # Judge ownership by active section content, not by the filename.  An Eddy
    # Coil config is often named eddy.cfg while referencing a shared toolboard
    # MCU such as [mcu EBBCan].  Treating the filename alone as proof of Eddy
    # ownership could move that shared MCU into the Wizard directory and later
    # make Full Eddy Uninstall unsafe.
    #
    # If every active section in the file is clearly Eddy/Wizard related,
    # consider it a dedicated Eddy config.
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

    # Mixed source file: preserve the working hardware dependencies where they
    # already live and migrate only the native probe section into the canonical
    # Wizard file.  This is important for Eddy Coil, whose i2c_mcu normally
    # points at an existing printer/toolboard MCU rather than a dedicated Eddy MCU.
    warn "The native Eddy probe is inside a mixed printer configuration file."
    info "Only [${NATIVE_PROBE_SECTION}] will be moved into canonical eddy/eddy.cfg."
    info "Existing MCU, I2C owner, temperature, and unrelated printer sections will remain in place."

    local tmp_section
    tmp_section="$(mktemp)"
    extract_section_to_file "${source}" "${NATIVE_PROBE_SECTION}" "${tmp_section}"

    [[ ! -e "${DST_EDDY}" && ! -L "${DST_EDDY}" ]] \
        || { rm -f -- "${tmp_section}"; die "${DST_EDDY} already exists and will not be overwritten."; }

    mkdir -p "${EDDY_DIR}"
    {
        printf '%s\n' '[include eddy_setup_wizard.cfg]'
        printf '%s\n' '[include eddy_macros.cfg]'
        printf '%s\n' '[include eddy_clear_calibration.cfg]'
        printf '\n'
        printf '%s\n' '# Native Eddy probe migrated from the existing active configuration.'
        cat "${tmp_section}"
    } > "${DST_EDDY}"
    chmod 0644 "${DST_EDDY}" 2>/dev/null || true
    rm -f -- "${tmp_section}"

    backup_path "${source}" "$(basename -- "${source}").before_native_probe_migration"
    remove_section_from_file "${source}" "${NATIVE_PROBE_SECTION}"
    ok "Migrated existing [${NATIVE_PROBE_SECTION}] into canonical eddy.cfg."
    info "Its existing hardware/MCU dependencies were preserved in ${source}."
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

remove_managed_clear_cfg() {
    local recorded_hash=""
    local current_hash=""

    [[ -e "${DST_CLEAR}" || -L "${DST_CLEAR}" ]] || return 0

    if [[ -L "${DST_CLEAR}" ]]; then
        warn "Symlinked eddy_clear_calibration.cfg is not being removed automatically:"
        warn "  ${DST_CLEAR}"
        return 0
    fi

    if [[ ! -f "${CLEAR_CFG_HASH_FILE}" ]]; then
        warn "Cannot prove ownership of ${DST_CLEAR}; preserving it."
        return 0
    fi

    recorded_hash="$(tr -d '[:space:]' < "${CLEAR_CFG_HASH_FILE}")"
    current_hash="$(sha256sum "${DST_CLEAR}" | awk '{print $1}')"

    if [[ -n "${recorded_hash}" && "${recorded_hash}" == "${current_hash}" ]]; then
        backup_path \
            "${DST_CLEAR}" \
            "eddy_clear_calibration.cfg.before_uninstall"

        rm -f -- "${DST_CLEAR}"
        ok "Removed Wizard-managed eddy_clear_calibration.cfg."
    else
        warn "eddy_clear_calibration.cfg differs from the Wizard-managed version."
        warn "Preserving user-modified file: ${DST_CLEAR}"
    fi
}

	uninstall_wizard_only() {
		printf '\n%sUninstall Wizard Only%s\n' "${BOLD}" "${RESET}"
		printf '%s\n' "------------------------------------------------------------"
		printf '%s\n' "This removes the Eddy Tap Wizard integration while keeping"
		printf '%s\n' "your native Eddy configuration active."
		printf '\n'
		printf '%s\n' "This will:"
		printf '%s\n' "  - Restore native Klipper temperature_probe.py when Wizard-owned"
		printf '%s\n' "  - Remove Wizard macro/setup/clear-calibration integration"
		printf '%s\n' "  - Keep eddy/eddy.cfg"
		printf '%s\n' "  - Keep the active [include eddy/eddy.cfg]"
		printf '%s\n' "  - Keep Eddy hardware configuration and saved calibration"
		printf '\n'

		ask_yes_no "Uninstall the Eddy Tap Wizard only?" "n" || exit 0

		restore_temperature_probe_for_uninstall

		if [[ -f "${DST_EDDY}" ]]; then
			backup_path "${DST_EDDY}" "eddy.cfg.before_wizard_uninstall"

			sed -i -E \
				-e '/^[[:space:]]*\[include[[:space:]]+eddy_setup_wizard\.cfg\][[:space:]]*(#.*)?$/d' \
				-e '/^[[:space:]]*\[include[[:space:]]+eddy_macros\.cfg\][[:space:]]*(#.*)?$/d' \
				-e '/^[[:space:]]*\[include[[:space:]]+eddy_clear_calibration\.cfg\][[:space:]]*(#.*)?$/d' \
				"${DST_EDDY}"
		fi

		remove_expected_symlink "${DST_MACROS}" "${SRC_MACROS}"
		remove_expected_symlink "${DST_WIZARD}" "${SRC_WIZARD}"

		remove_managed_clear_cfg

		clear_temperature_probe_patch_state

		rm -f -- \
			"${GCODE_SHELL_HASH_FILE}" \
			"${CLEAR_CFG_HASH_FILE}" \
			2>/dev/null || true

		rebuild_active_tree

		path_is_active "${DST_EDDY}" \
			|| die "Wizard uninstall removed Eddy from the active config tree unexpectedly."

		restart_klipper

		ok "Wizard integration removed."
		ok "Native Eddy configuration remains active."

		[[ "${BACKUP_CREATED}" -eq 1 ]] \
			&& info "Backups: ${BACKUP_DIR}"

		exit 0
	}

full_uninstall_eddy() {
    local workdir plan_file restore_bundle new_printer
    local probe_name="" eddy_mcu=""
    local section file record
    local -a restore_sections=()
    local -a unknown_sections=()
    local -a unknown_entries=()
    local -a duplicate_records=()

    printf '\n%sFull Eddy Uninstall%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"
    printf '%s\n' "This removes the Eddy Tap Wizard and the canonical Eddy configuration."
    printf '%s\n' "General printer sections currently stored in eddy/eddy.cfg will be"
    printf '%s\n' "restored to printer.cfg before the Eddy directory is removed."
    printf '\n'
    printf '%s\n' "This will:"
    printf '%s\n' "  - Back up printer.cfg"
    printf '%s\n' "  - Back up the complete eddy/ directory"
    printf '%s\n' "  - Restore portable printer sections from eddy/eddy.cfg"
    printf '%s\n' "  - Restore native Klipper temperature_probe.py when Wizard-owned"
    printf '%s\n' "  - Remove Eddy/Wizard include references from printer.cfg"
    printf '%s\n' "  - Remove the complete eddy/ directory"
    printf '%s\n' "  - Preserve gcode_shell_command.py"
    printf '%s\n' "  - NOT restart Klipper automatically"
    printf '\n'
    warn "If Eddy is your Z endstop/probe, configure a replacement before restarting Klipper."
    printf '\n'

    ask_yes_no "Perform a Full Eddy Uninstall?" "n" || exit 0

    [[ -d "${EDDY_DIR}" ]] \
        || die "Canonical Eddy directory not found: ${EDDY_DIR}"
    [[ -f "${DST_EDDY}" ]] \
        || die "Canonical Eddy configuration not found: ${DST_EDDY}"

    # Full uninstall removes the entire canonical directory. Refuse to silently
    # delete files that are not part of the known Wizard layout.
    mapfile -t unknown_entries < <(
        find "${EDDY_DIR}" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
            | awk '
                $0 != "eddy.cfg" &&
                $0 != "eddy_macros.cfg" &&
                $0 != "eddy_setup_wizard.cfg" &&
                $0 != "eddy_clear_calibration.cfg" { print }
            '
    )

    if (( ${#unknown_entries[@]} > 0 )); then
        error "Full uninstall found files in ${EDDY_DIR} that are not part of the canonical Wizard layout:"
        for file in "${unknown_entries[@]}"; do
            printf '  %s/%s\n' "${EDDY_DIR}" "${file}" >&2
        done
        die "Review or move these files before retrying Full Eddy Uninstall. Nothing was changed."
    fi

    workdir="$(mktemp -d)"
    plan_file="${workdir}/plan"
    restore_bundle="${workdir}/restore.cfg"
    new_printer="${workdir}/printer.cfg"

    # Read-only preflight. Classify every active section in eddy.cfg and build
    # a bundle containing only sections that are safe to restore to printer.cfg.
    if ! python3 - "${DST_EDDY}" "${plan_file}" "${restore_bundle}" <<'PY'
import re
import sys

source, plan_path, restore_path = sys.argv[1:]

with open(source, encoding="utf-8") as f:
    lines = f.readlines()

header_rx = re.compile(r'^\s*\[([^\]]+)\]\s*(?:#.*)?$', re.IGNORECASE)
banner_rx = re.compile(r'^\s*#{20,}\s*$')
option_rx_cache = {}

sections = []
for index, line in enumerate(lines):
    match = header_rx.match(line.rstrip("\n"))
    if match:
        sections.append({
            "name": match.group(1).strip(),
            "start": index,
            "end": len(lines),
        })

for i, section in enumerate(sections):
    if i + 1 < len(sections):
        section["end"] = sections[i + 1]["start"]


def option(section, name):
    key = name.lower()
    rx = option_rx_cache.get(key)
    if rx is None:
        rx = re.compile(
            r'^\s*' + re.escape(name) + r'\s*:\s*(.*?)\s*(?:#.*)?$',
            re.IGNORECASE,
        )
        option_rx_cache[key] = rx
    for line in lines[section["start"] + 1:section["end"]]:
        match = rx.match(line.rstrip("\n"))
        if match:
            return match.group(1).strip()
    return ""

probe_sections = [
    section for section in sections
    if section["name"].lower().startswith("probe_eddy_current ")
]

if len(probe_sections) != 1:
    print(
        "Full uninstall requires exactly one active [probe_eddy_current ...] "
        f"section in {source}; found {len(probe_sections)}.",
        file=sys.stderr,
    )
    raise SystemExit(2)

probe_section = probe_sections[0]
probe_name = probe_section["name"].split(None, 1)[1].strip()
eddy_mcu = option(probe_section, "i2c_mcu")

if not eddy_mcu:
    print(
        f"Unable to determine i2c_mcu from [{probe_section['name']}].",
        file=sys.stderr,
    )
    raise SystemExit(2)

restore_names = {
    "bed_mesh",
    "bed_screws",
    "screws_tilt_adjust",
    "safe_z_home",
    "homing_override",
    "z_tilt",
    "quad_gantry_level",
    "save_variables",
}

wizard_includes = {
    "eddy_setup_wizard.cfg",
    "eddy_macros.cfg",
    "eddy_clear_calibration.cfg",
}

probe_key = f"probe_eddy_current {probe_name}".lower()
temp_probe_key = f"temperature_probe {probe_name}".lower()
mcu_key = f"mcu {eddy_mcu}".lower()

# A native Eddy/Duo normally owns its dedicated MCU, but Eddy Coil references
# an existing printer/toolboard MCU.  If the referenced MCU name is not
# clearly Eddy-owned, preserve it during Full Eddy Uninstall instead of
# risking deletion of a shared toolboard configuration.
mcu_name_lower = eddy_mcu.lower()
mcu_is_clearly_eddy_owned = "eddy" in mcu_name_lower

plan = []
restore_sections = []

for section in sections:
    name = section["name"]
    lower = name.lower()
    classification = None

    if lower in restore_names:
        classification = "RESTORE"
        restore_sections.append(section)

    elif lower.startswith("include "):
        include_spec = name.split(None, 1)[1].strip()
        if include_spec in wizard_includes:
            classification = "EDDY"
        else:
            classification = "UNKNOWN"

    elif lower == probe_key:
        classification = "EDDY"

    elif lower == temp_probe_key:
        classification = "EDDY"

    elif lower == mcu_key:
        if mcu_is_clearly_eddy_owned:
            classification = "EDDY"
        else:
            classification = "RESTORE"
            restore_sections.append(section)

    elif lower.startswith("temperature_sensor "):
        sensor_mcu = option(section, "sensor_mcu")
        if sensor_mcu.lower() == eddy_mcu.lower():
            if mcu_is_clearly_eddy_owned:
                classification = "EDDY"
            else:
                classification = "RESTORE"
                restore_sections.append(section)
        else:
            classification = "UNKNOWN"

    else:
        classification = "UNKNOWN"

    plan.append((classification, name))

with open(plan_path, "w", encoding="utf-8") as f:
    f.write(f"PROBE|{probe_name}\n")
    f.write(f"MCU|{eddy_mcu}\n")
    for classification, name in plan:
        f.write(f"{classification}|{name}\n")

with open(restore_path, "w", encoding="utf-8") as out:
    for section in restore_sections:
        end = section["end"]

        # Canonical eddy.cfg uses large comment banners between optional
        # template blocks. Do not drag the following commented example into
        # the section being restored.
        for index in range(section["start"] + 1, end):
            if banner_rx.match(lines[index].rstrip("\n")):
                end = index
                break

        chunk = lines[section["start"]:end]
        while chunk and not chunk[-1].strip():
            chunk.pop()

        if chunk:
            out.writelines(chunk)
            out.write("\n\n")
PY
    then
        rm -rf -- "${workdir}"
        die "Unable to build a safe Full Eddy Uninstall plan. Nothing was changed."
    fi

    probe_name="$(awk -F'|' '$1 == "PROBE" {print $2; exit}' "${plan_file}")"
    eddy_mcu="$(awk -F'|' '$1 == "MCU" {print $2; exit}' "${plan_file}")"
    mapfile -t restore_sections < <(awk -F'|' '$1 == "RESTORE" {print $2}' "${plan_file}")
    mapfile -t unknown_sections < <(awk -F'|' '$1 == "UNKNOWN" {print $2}' "${plan_file}")

    if (( ${#unknown_sections[@]} > 0 )); then
        error "Full uninstall found active sections/includes in eddy.cfg that are not proven Eddy-specific"
        error "and are not in the safe printer-section restoration list:"
        for section in "${unknown_sections[@]}"; do
            printf '  [%s]\n' "${section}" >&2
        done
        rm -rf -- "${workdir}"
        die "Review these entries before retrying Full Eddy Uninstall. Nothing was changed."
    fi

    # Read-only duplicate preflight. A restorable section may not already be
    # active anywhere outside the canonical eddy.cfg.
    for section in "${restore_sections[@]}"; do
        duplicate_records=()

        for file in "${ACTIVE_CFG_FILES[@]}"; do
            [[ "$(resolve_path "${file}")" == "$(resolve_path "${DST_EDDY}")" ]] && continue

            if grep -Eqi "^[[:space:]]*\\[${section}\\][[:space:]]*(#.*)?$" "${file}" 2>/dev/null; then
                duplicate_records+=("${file}")
            fi
        done

        if (( ${#duplicate_records[@]} > 0 )); then
            error "Cannot restore [${section}] to printer.cfg because an active copy already exists:"
            for file in "${duplicate_records[@]}"; do
                printf '  %s [%s]\n' "${file}" "${section}" >&2
            done
            rm -rf -- "${workdir}"
            die "Resolve the duplicate before retrying Full Eddy Uninstall. Nothing was changed."
        fi
    done

    # Build the desired printer.cfg completely in temporary storage before
    # modifying the user's configuration.
    if ! python3 - "${PRINTER_CFG}" "${EDDY_DIR}" "${restore_bundle}" "${new_printer}" <<'PY'
import os
import re
import sys

printer, eddy_dir, restore_bundle, output = sys.argv[1:]

with open(printer, encoding="utf-8") as f:
    lines = f.readlines()

marker_start = "# >>> Klipper Eddy Tap Wizard >>>"
marker_end = "# <<< Klipper Eddy Tap Wizard <<<"
start_markers = [
    i for i, line in enumerate(lines)
    if line.strip() == marker_start
]

end_markers = [
    i for i, line in enumerate(lines)
    if line.strip() == marker_end
]

if len(start_markers) != len(end_markers):
    print(
        "Malformed Klipper Eddy Tap Wizard marker block in printer.cfg: "
        "opening/closing marker count does not match.",
        file=sys.stderr,
    )
    raise SystemExit(2)

if len(start_markers) > 1:
    print(
        "Multiple Klipper Eddy Tap Wizard marker blocks were found in printer.cfg.",
        file=sys.stderr,
    )
    raise SystemExit(2)

if start_markers and start_markers[0] > end_markers[0]:
    print(
        "Malformed Klipper Eddy Tap Wizard marker block in printer.cfg: "
        "closing marker appears before opening marker.",
        file=sys.stderr,
    )
    raise SystemExit(2)
include_rx = re.compile(r'^\s*\[include\s+([^\]]+)\]\s*(?:#.*)?$', re.IGNORECASE)

result = []
skipping_marker = False

for line in lines:
    stripped = line.strip()

    if stripped == marker_start:
        skipping_marker = True
        continue

    if skipping_marker:
        if stripped == marker_end:
            skipping_marker = False
        continue

    match = include_rx.match(line.rstrip("\n"))
    if match:
        spec = match.group(1).strip()
        normalized = spec[2:] if spec.startswith("./") else spec

        # Remove only includes scoped to the canonical Eddy directory.
        if normalized.startswith("eddy/"):
            continue

        if os.path.isabs(spec):
            prefix = os.path.normpath(eddy_dir) + os.sep
            if os.path.normpath(spec).startswith(prefix):
                continue

    result.append(line)

with open(restore_bundle, encoding="utf-8") as f:
    restored = f.read().rstrip()

if restored:
    while result and not result[-1].strip():
        result.pop()

    result.extend([
        "\n",
        "\n",
        "#####################################################################\n",
        "# Restored by Klipper Eddy Tap Wizard Full Uninstall\n",
        "#####################################################################\n",
        "\n",
        restored + "\n",
    ])

with open(output, "w", encoding="utf-8") as f:
    f.writelines(result)
PY
    then
        rm -rf -- "${workdir}"
        die "Unable to prepare the restored printer.cfg. Nothing was changed."
    fi

    # Verify the temporary printer.cfg contains every planned restored section
    # before the first modification is made.
    for section in "${restore_sections[@]}"; do
        grep -Eqi "^[[:space:]]*\\[${section}\\][[:space:]]*(#.*)?$" "${new_printer}" \
            || {
                rm -rf -- "${workdir}"
                die "Preflight verification failed for restored [${section}]. Nothing was changed."
            }
    done

    printf '\n%sFull uninstall plan%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"
    printf 'Eddy probe:                  %s\n' "${probe_name}"
    printf 'Probe I2C MCU:               %s\n' "${eddy_mcu}"

    if [[ "${eddy_mcu,,}" != *eddy* ]]; then
        warn "The probe references MCU '${eddy_mcu}', which is not clearly Eddy-owned."
        warn "If that MCU section is stored in eddy.cfg, Full Uninstall will restore it to printer.cfg instead of deleting it."
    fi

    if (( ${#restore_sections[@]} > 0 )); then
        printf 'Sections restored to printer.cfg:\n'
        for section in "${restore_sections[@]}"; do
            printf '  [%s]\n' "${section}"
        done
    else
        printf 'Sections restored to printer.cfg: none\n'
    fi

    printf '\n'
    ask_yes_no "Apply this Full Eddy Uninstall plan?" "n" \
        || { rm -rf -- "${workdir}"; exit 0; }

    # No configuration changes occur before this point.
    backup_path "${PRINTER_CFG}" "printer.cfg.before_full_eddy_uninstall"
    backup_path "${EDDY_DIR}" "eddy.before_full_uninstall"

    restore_temperature_probe_for_uninstall

    cat "${new_printer}" > "${PRINTER_CFG}" \
        || die "Failed to write restored printer.cfg. Backups are available at ${BACKUP_DIR}."

    rm -rf -- "${EDDY_DIR}" \
        || die "Failed to remove ${EDDY_DIR}. Backups are available at ${BACKUP_DIR}."

    # gcode_shell_command.py is intentionally preserved because another user
    # configuration may depend on it. Full uninstall only removes project state.
    clear_temperature_probe_patch_state
    rm -rf -- "${STATE_DIR}" 2>/dev/null || true

    rebuild_active_tree

    for section in "${restore_sections[@]}"; do
        record="$(section_record_for_active_name "${section}" || true)"
        [[ -n "${record}" ]] \
            || die "Post-uninstall verification could not find restored [${section}]. Backups are available at ${BACKUP_DIR}."
    done

    [[ ! -e "${EDDY_DIR}" && ! -L "${EDDY_DIR}" ]] \
        || die "Post-uninstall verification found ${EDDY_DIR} still present."

    rm -rf -- "${workdir}"

    printf '\n%sFull Eddy Uninstall complete.%s\n' "${GREEN}${BOLD}" "${RESET}"
    printf 'Backups:\n  %s\n' "${BACKUP_DIR}"
    printf '\n'
    printf '%s\n' "Klipper was NOT restarted automatically."
    printf '%s\n' "gcode_shell_command.py was preserved."
    printf '\n'
    warn "If Eddy was your Z endstop/probe, configure a replacement probe or physical Z endstop before restarting Klipper."
    printf '\n'

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

if [[ "${UNINSTALL_WIZARD}" -eq 1 ]]; then
    uninstall_wizard_only
fi

if [[ "${FULL_UNINSTALL}" -eq 1 ]]; then
    full_uninstall_eddy
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
