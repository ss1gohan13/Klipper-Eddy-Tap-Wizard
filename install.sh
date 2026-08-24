#!/usr/bin/env bash
#
# Klipper Eddy Tap Wizard Installer
#
# Installs/updates:
#   printer_data/config/eddy_macros.cfg
#   printer_data/config/eddy_setup_wizard.cfg
#   klipper/klippy/extras/temperature_probe.py
#
# The two .cfg files are symlinked to this repository so a git pull updates
# them immediately. temperature_probe.py is copied into Klipper (not symlinked)
# so the Klipper source tree is not left with a tracked file replaced by a
# symlink.
#
# Usage:
#   ./install.sh
#   ./install.sh --update
#   ./install.sh --yes
#   ./install.sh --update --yes
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
SRC_TEMP_PROBE="${SCRIPT_DIR}/klipper/klippy/extras/temperature_probe.py"

DST_MACROS="${CONFIG_DIR}/eddy_macros.cfg"
DST_WIZARD="${CONFIG_DIR}/eddy_setup_wizard.cfg"
DST_TEMP_PROBE="${KLIPPER_EXTRAS_DIR}/temperature_probe.py"
PRINTER_CFG="${CONFIG_DIR}/printer.cfg"

STATE_DIR="${XDG_CONFIG_HOME:-${HOME_DIR}/.config}/${PROJECT_SLUG}"
TEMP_HASH_FILE="${STATE_DIR}/temperature_probe.installed.sha256"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
BACKUP_ROOT="${CONFIG_DIR}/eddy_wizard_backups"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

AUTO_YES=0
DO_UPDATE=0
DO_RESTART=1
AFTER_PULL="${EDDY_WIZARD_AFTER_PULL:-0}"

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
  -y, --yes      Automatically answer yes to installer prompts.
  -h, --help     Show this help.

Environment overrides:
  PRINTER_DATA_DIR=/path/to/printer_data
  CONFIG_DIR=/path/to/config
  KLIPPER_DIR=/path/to/klipper
  KLIPPER_EXTRAS_DIR=/path/to/klippy/extras

Recommended update command:
  ./install.sh --update

The installer:
  - symlinks eddy_macros.cfg and eddy_setup_wizard.cfg into printer_data/config
  - backs up files before replacing them
  - checks/adds the required include statements when requested
  - checks/adds [save_variables] when requested and none exists
  - safely manages the project's modified temperature_probe.py
  - restarts Klipper when requested
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

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)
            DO_UPDATE=1
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

[[ -d "${CONFIG_DIR}" ]] || die "Klipper config directory not found: ${CONFIG_DIR}"
[[ -d "${KLIPPER_EXTRAS_DIR}" ]] || die "Klipper extras directory not found: ${KLIPPER_EXTRAS_DIR}"

[[ -f "${SRC_MACROS}" ]] || die "Repository file missing: ${SRC_MACROS}"
[[ -f "${SRC_WIZARD}" ]] || die "Repository file missing: ${SRC_WIZARD}"
[[ -f "${SRC_TEMP_PROBE}" ]] || die "Repository file missing: ${SRC_TEMP_PROBE}"

# Verify this looks like the expected patched temperature_probe.py.
grep -Fq 'TAP_START_Z = 5.' "${SRC_TEMP_PROBE}" \
    || die "Repository temperature_probe.py does not contain TAP_START_Z = 5."
grep -Fq 'tool_zero_z = mpresult.bed_z' "${SRC_TEMP_PROBE}" \
    || die "Repository temperature_probe.py does not contain the expected Tap bed-reference fix."
grep -Fq 'curpos[2] = self.last_zero_pos + TAP_START_Z' "${SRC_TEMP_PROBE}" \
    || die "Repository temperature_probe.py does not contain the expected safe thermal Tap start-height fix."

ok "Repository files validated."
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

    # Re-exec the possibly updated installer from disk.
    export EDDY_WIZARD_AFTER_PULL=1
    reexec_args=()
    [[ "${AUTO_YES}" -eq 1 ]] && reexec_args+=("--yes")
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
# Install the two config files as symlinks
# ---------------------------------------------------------------------------

install_cfg_link() {
    local src="$1"
    local dst="$2"
    local label="$3"

    if [[ -L "${dst}" ]]; then
        local current
        current="$(readlink -f -- "${dst}" 2>/dev/null || true)"
        local desired
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
# Detect/add include statements
# ---------------------------------------------------------------------------

cfg_tree_has_regex() {
    local regex="$1"
    grep -RIEq \
        --include='*.cfg' \
        --exclude-dir='eddy_wizard_backups' \
        --exclude='saved_variables.cfg' \
        "${regex}" "${CONFIG_DIR}" 2>/dev/null
}

wizard_include_present=0
macros_include_present=0

if cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_setup_wizard\.cfg\][[:space:]]*$'; then
    wizard_include_present=1
fi

if cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_macros\.cfg\][[:space:]]*$'; then
    macros_include_present=1
fi

if [[ "${wizard_include_present}" -eq 1 && "${macros_include_present}" -eq 1 ]]; then
    ok "Required include statements already exist in the config tree."
else
    warn "One or more Eddy Wizard include statements were not found."

    if [[ -f "${PRINTER_CFG}" ]]; then
        if ask_yes_no "Add missing Eddy Wizard include statements to the TOP of ${PRINTER_CFG}?" "y"; then
            backup_path "${PRINTER_CFG}" "printer.cfg.before_eddy_wizard"

            # Prepend the Eddy Wizard includes to the TOP of printer.cfg.
            # This keeps them above Klipper's SAVE_CONFIG autosave block.
            tmp_cfg="$(mktemp)"

            {
                printf '# >>> Klipper Eddy Tap Wizard >>>\n'
                [[ "${wizard_include_present}" -eq 0 ]] && \
                    printf '[include eddy_setup_wizard.cfg]\n'
                [[ "${macros_include_present}" -eq 0 ]] && \
                    printf '[include eddy_macros.cfg]\n'
                printf '# <<< Klipper Eddy Tap Wizard <<<\n\n'
                cat "${PRINTER_CFG}"
            } > "${tmp_cfg}"

            # Write through the existing path instead of replacing it so a
            # printer.cfg symlink, ownership, and permissions are preserved.
            cat "${tmp_cfg}" > "${PRINTER_CFG}"
            rm -f -- "${tmp_cfg}"

            ok "Added missing include statements to the TOP of ${PRINTER_CFG}."
        else
            warn "Include statements were not added. Add them manually before running EDDY_SETUP."
        fi
    else
        warn "printer.cfg was not found at ${PRINTER_CFG}."
        warn "Add these includes to a loaded Klipper config manually:"
        [[ "${wizard_include_present}" -eq 0 ]] && printf '  [include eddy_setup_wizard.cfg]\n'
        [[ "${macros_include_present}" -eq 0 ]] && printf '  [include eddy_macros.cfg]\n'
    fi
fi

# ---------------------------------------------------------------------------
# Detect/add [save_variables]
# ---------------------------------------------------------------------------

if cfg_tree_has_regex '^[[:space:]]*\[save_variables\][[:space:]]*$'; then
    ok "[save_variables] already exists in the config tree."
else
    warn "No [save_variables] section was found."

    if [[ -f "${PRINTER_CFG}" ]]; then
        if ask_yes_no "Add a [save_variables] section to ${PRINTER_CFG}?" "y"; then
            backup_path "${PRINTER_CFG}" "printer.cfg.before_save_variables"
            touch "${CONFIG_DIR}/saved_variables.cfg"

            # Keep [save_variables] above SAVE_CONFIG too. If the Eddy
            # include block was added above, insert this directly after it.
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
        else
            warn "The wizard requires [save_variables]. Add one before running EDDY_SETUP."
        fi
    else
        warn "Cannot automatically add [save_variables] because printer.cfg was not found."
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

if [[ -f "${DST_TEMP_PROBE}" || -L "${DST_TEMP_PROBE}" ]]; then
    # sha256sum follows a symlink, which is what we want for content comparison.
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
        warn "temperature_probe.py was not replaced."
        warn "Thermal Eddy Tap calibration may not behave as expected."
    fi
fi

# ---------------------------------------------------------------------------
# Final checks
# ---------------------------------------------------------------------------

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

if cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_setup_wizard\.cfg\][[:space:]]*$' \
   && cfg_tree_has_regex '^[[:space:]]*\[include[[:space:]]+eddy_macros\.cfg\][[:space:]]*$'; then
    ok "Wizard includes detected."
else
    warn "Wizard includes are not both detectable in ${CONFIG_DIR}."
fi

if cfg_tree_has_regex '^[[:space:]]*\[save_variables\][[:space:]]*$'; then
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
