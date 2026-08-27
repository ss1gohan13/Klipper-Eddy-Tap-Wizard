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
GCODE_SHELL_HASH_FILE="${STATE_DIR}/gcode_shell_command.installed.sha256"
CLEAR_CFG_HASH_FILE="${STATE_DIR}/eddy_clear_calibration.installed.sha256"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_ROOT="${CONFIG_DIR}/eddy_wizard_backups"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
BACKUP_CREATED=0

AUTO_YES=0
DO_UPDATE=0
DETECT_ONLY=0
UNINSTALL=0
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
  ./install.sh --yes

Canonical installed layout:
  ~/printer_data/config/eddy/
    eddy.cfg
    eddy_macros.cfg
    eddy_setup_wizard.cfg
    eddy_clear_calibration.cfg

Options:
  --update       Fast-forward the currently checked-out branch, then rerun.
  --detect-only  Scan active and inactive config files without modifying them.
  --uninstall    Remove Wizard integration while preserving user Eddy config.
  -y, --yes      Automatically accept normal yes/no prompts.
  -h, --help     Show this help.

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
        -y|--yes) AUTO_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

if [[ "${UNINSTALL}" -eq 1 && ( "${DO_UPDATE}" -eq 1 || "${DETECT_ONLY}" -eq 1 ) ]]; then
    die "--uninstall cannot be combined with --update or --detect-only."
fi

if [[ "${AFTER_PULL}" -ne 1 \
   && "${DO_UPDATE}" -eq 0 \
   && "${DETECT_ONLY}" -eq 0 \
   && "${UNINSTALL}" -eq 0 ]]; then
    printf '\n%sChoose action%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"
    printf '  1) Install / Repair\n'
    printf '  2) Update\n'
    printf '  3) Uninstall\n'
    printf '  4) Detect only\n'
    ask_choice "Action" "1" "1" "4"
    case "${ANSWER}" in
        1) ;;
        2) DO_UPDATE=1 ;;
        3) UNINSTALL=1 ;;
        4) DETECT_ONLY=1 ;;
    esac
fi

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

printf '\n%s%s Installer%s\n' "${BOLD}" "${PROJECT_NAME}" "${RESET}"
printf '%s\n\n' "------------------------------------------------------------"

[[ -z "${SUDO_USER:-}" ]] \
    || die "Do not run install.sh with sudo. Run it as the normal Klipper user."

for cmd in git grep awk sed sha256sum readlink find mktemp python3; do
    command -v "${cmd}" >/dev/null 2>&1 || die "${cmd} is required."
done

[[ -d "${CONFIG_DIR}" ]] || die "Config directory not found: ${CONFIG_DIR}"
[[ -f "${PRINTER_CFG}" ]] || die "printer.cfg not found: ${PRINTER_CFG}"

if [[ "${DETECT_ONLY}" -eq 0 && "${UNINSTALL}" -eq 0 ]]; then
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
    local file

    wanted="$(resolve_path "$1")"
    for file in "${ACTIVE_CFG_FILES[@]}"; do
        [[ "$(resolve_path "${file}")" == "${wanted}" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Broad config-directory scan
# ---------------------------------------------------------------------------

scan_all_cfg_files() {
    ALL_CFG_FILES=()

    while IFS= read -r file; do
        ALL_CFG_FILES+=("$(resolve_path "${file}")")
    done < <(
        find "${CONFIG_DIR}" -type f -name '*.cfg' \
            ! -path "${BACKUP_ROOT}/*" \
            ! -path '*/.git/*' \
            -print 2>/dev/null | sort
    )
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

scan_eddy_families() {
    local file
    local line
    local section
    local name
    local active

    ACTIVE_NATIVE_PROBE_RECORDS=()
    ACTIVE_EDDY_NG_RECORDS=()
    INACTIVE_EDDY_FILES=()
    HISTORICAL_CFG_FILES=()
    BTT_STYLE_FILES=()

    for file in "${ALL_CFG_FILES[@]}"; do
        active=0
        path_is_active "${file}" && active=1

        # Ignore historical/backup configs only when they are inactive.
        # Active files are always inspected.
        if [[ "${active}" -eq 0 ]] && is_historical_backup_cfg "${file}"; then
            HISTORICAL_CFG_FILES+=("${file}")
            continue
        fi

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
}

report_discovery() {
    printf '\n%sConfiguration discovery%s\n' "${BOLD}" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"
    printf 'Active config files:          %d\n' "${#ACTIVE_CFG_FILES[@]}"
	printf 'Active config files:          %d\n' "${#ACTIVE_CFG_FILES[@]}"
	printf 'All config files discovered:  %d\n' "${#ALL_CFG_FILES[@]}"
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

install_managed_python_file() {
    local src="$1"
    local dst="$2"
    local hash_file="$3"
    local label="$4"
    local compatibility_mode="${5:-hash}"
    local desired current previous=""

    mkdir -p "${STATE_DIR}"

    if [[ "${compatibility_mode}" == "temperature_probe" ]] \
        && [[ -f "${dst}" ]] \
        && temperature_probe_has_required_behavior "${dst}"; then
        if cmp -s "${src}" "${dst}"; then
            desired="$(sha256sum "${src}" | awk '{print $1}')"
            printf '%s\n' "${desired}" > "${hash_file}"
            ok "${label} already matches repository."
        else
            warn "${label} differs from repository but already contains required Tap behavior."
            info "Preserving compatible existing file."
            rm -f -- "${hash_file}"
        fi
        return 0
    fi

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

install_python_dependencies() {
    install_managed_python_file \
        "${SRC_GCODE_SHELL_COMMAND}" \
        "${DST_GCODE_SHELL_COMMAND}" \
        "${GCODE_SHELL_HASH_FILE}" \
        "gcode_shell_command.py"

    install_managed_python_file \
        "${SRC_TEMP_PROBE}" \
        "${DST_TEMP_PROBE}" \
        "${TEMP_HASH_FILE}" \
        "temperature_probe.py" \
        "temperature_probe"
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
    info "Preserving Klipper Python dependencies by default."
    rm -f -- "${TEMP_HASH_FILE}" "${GCODE_SHELL_HASH_FILE}" "${CLEAR_CFG_HASH_FILE}" 2>/dev/null || true

    rebuild_active_tree
    restart_klipper

    ok "Wizard integration removed. Native/user Eddy configuration preserved."
    [[ "${BACKUP_CREATED}" -eq 1 ]] && info "Backups: ${BACKUP_DIR}"
    exit 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

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
[[ "${BACKUP_CREATED}" -eq 1 ]] && printf 'Backups:\n  %s\n' "${BACKUP_DIR}"
printf '\n'
