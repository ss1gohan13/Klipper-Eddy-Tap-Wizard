:warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning:

> [!IMPORTANT]
> This project is intended to be used with the latest stable release of **mainline Klipper**.
>
> Before installing or running the Eddy Tap Wizard, update Klipper to the latest available release.
>
> Older Klipper versions may be missing Eddy Tap functionality or other required changes used by this project.

:warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning:

# Klipper Eddy Tap Wizard

## 1. Overview

<details>
<summary><strong>What This Project Does</strong></summary>

Klipper Eddy Tap Wizard provides a guided setup and calibration workflow for native Klipper Eddy current probes.

The goal is to simplify the full Eddy setup process into a structured sequence that walks the user through:

- LDC drive current calibration
- Main Eddy Z / frequency calibration
- Eddy Tap calibration
- Optional thermal compensation
- Saving and restarting between calibration stages
- Reviewing the final setup state

The Wizard is designed around a single native Klipper Eddy probe and a canonical Eddy configuration layout.

</details>

<details>
<summary><strong>Requirements</strong></summary>

The Wizard expects:

- Current mainline Klipper
- One native `[probe_eddy_current ...]` probe
- `[respond]`
- `[force_move]` with force moves enabled
- `[bed_mesh]`
- `[save_variables]`
- A valid `zero_reference_position` inside `[bed_mesh]`

</details>

<details>
<summary><strong>Supported Configurations</strong></summary>

The installer is designed to support:

- Fresh native Klipper Eddy installations
- USB-connected Eddy probes
- CAN-connected Eddy probes
- Existing native Klipper Eddy configurations
- Existing dedicated `eddy.cfg` files
- Existing canonical `config/eddy/` Wizard layouts

The installer detects the currently active Klipper configuration tree before making changes.

</details>

<details>
<summary><strong>Important Limitations</strong></summary>

The Wizard expects exactly one active native Eddy probe.

Conflicting or ambiguous probe configurations may require manual cleanup before installation can continue.

Examples include:

- Multiple active native Eddy probes
- Active Eddy-NG configurations
- Native Eddy and Eddy-NG active at the same time
- Unsupported legacy helper configurations that cannot be safely converted automatically

</details>

---

## 2. Installation & Management

<details>
<summary><strong>Installation</strong></summary>

Run the installer from the project directory:

```bash
./install.sh
```

The installer menu provides:

```text
1) Install / Repair
2) Update
3) Uninstall
4) Detect only
```

During installation, the installer:

- Scans the active Klipper configuration tree
- Searches for existing Eddy-related configuration
- Identifies the current Eddy configuration state
- Preserves user-owned configuration whenever possible
- Creates backups before modifying configuration
- Normalizes the Wizard into the canonical `config/eddy/` layout
- Installs the Wizard support files
- Verifies `zero_reference_position`
- Verifies required Python dependencies
- Restarts Klipper after successful installation

<details>
<summary>↳ <strong>Fresh Installation</strong></summary>

For a fresh Eddy setup, the installer prompts for the information it cannot safely determine automatically.

This may include:

- USB serial path or CAN UUID
- Probe X offset
- Probe Y offset
- Bed mesh geometry
- Zero reference position
- Temperature compensation defaults

The generated user-owned Eddy configuration is placed at:

```text
~/printer_data/config/eddy/eddy.cfg
```

</details>

<details>
<summary>↳ <strong>Existing Native Eddy Installation</strong></summary>

If an existing native `[probe_eddy_current ...]` configuration is found, the installer attempts to preserve the existing configuration rather than replacing it.

Dedicated Eddy configuration files may be moved into the canonical `config/eddy/` directory.

If the Eddy probe exists inside a mixed printer configuration file, only explicitly selected Eddy-related sections should be migrated.

</details>

</details>

<details>
<summary><strong>Update</strong></summary>

Run:

```bash
./install.sh --update
```

or select:

```text
2) Update
```

from the installer menu.

The updater performs a fast-forward Git update of the currently checked-out branch and then reruns the installer.

User-owned `eddy.cfg` content is preserved during normal updates.

</details>

<details>
<summary><strong>Uninstallation</strong></summary>

Run:

```bash
./install.sh --uninstall
```

or select:

```text
3) Uninstall
```

from the installer menu.

The uninstaller removes Wizard integration while preserving the user's native Eddy configuration.

Items intended to remain include:

- `eddy.cfg`
- `[mcu eddy]`
- `[probe_eddy_current ...]`
- `[temperature_probe ...]`
- `[temperature_sensor ...]`
- `[bed_mesh]`
- `zero_reference_position`
- `[save_variables]`
- Existing Eddy calibration values

Wizard-managed support files may be removed or restored as appropriate.

</details>

<details>
<summary><strong>Detect Only</strong></summary>

Run:

```bash
./install.sh --detect-only
```

or select:

```text
4) Detect only
```

from the installer menu.

Detect-only mode inspects the configuration without modifying it.

It reports:

- Active configuration files
- Configuration files analyzed
- Historical backups ignored
- Active native Eddy probes
- Active Eddy-NG probes
- Inactive Eddy migration candidates
- Final Eddy classification

</details>

---

## 3. Using the Wizard

<details>
<summary><strong>Starting the Wizard</strong></summary>

After installation, start the guided setup from the Klipper console with:

```gcode
EDDY_SETUP
```

To begin the Wizard with a target temperature:

```gcode
EDDY_SETUP TARGET=<temperature>
```

Example:

```gcode
EDDY_SETUP TARGET=60
```

</details>

<details>
<summary><strong>Calibration Workflow</strong></summary>

The Wizard guides the user through the required Eddy calibration stages in sequence.

<details>
<summary>↳ <strong>1. LDC Drive Current Calibration</strong></summary>

This stage prepares and calibrates the Eddy probe's LDC drive current.

Relevant commands include:

```gcode
EDDY_LDC_PREP
EDDY_LDC_CALIBRATE
```

The Wizard prompts the user through the required positioning and calibration process.

</details>

<details>
<summary>↳ <strong>2. Main Eddy Z / Frequency Calibration</strong></summary>

This stage performs the main native Klipper Eddy calibration.

Relevant commands include:

```gcode
EDDY_CURRENT_PREP
EDDY_CURRENT_CALIBRATE
```

This establishes the relationship between probe frequency and Z position.

</details>

<details>
<summary>↳ <strong>3. Eddy Tap Calibration</strong></summary>

This stage calibrates Eddy Tap behavior.

Relevant command:

```gcode
EDDY_TAP_CALIBRATE
```

The resulting Tap calibration is used for contact-based Z probing.

</details>

<details>
<summary>↳ <strong>4. Thermal Compensation</strong></summary>

Thermal compensation is optional and depends on the probe hardware and temperature sensing available in the installation.

Relevant command:

```gcode
EDDY_TEMP_CALIBRATE
```

The Wizard guides the user through the thermal calibration process when applicable.

</details>

</details>

<details>
<summary><strong>Saving Calibration</strong></summary>

The Wizard uses Klipper's normal configuration save and restart flow.

When instructed, run:

```gcode
SAVE_CONFIG
```

After Klipper restarts, continue with the next Wizard step.

Tap offset saving is handled with:

```gcode
SAVE_EDDY_TAP_OFFSET
```

</details>

<details>
<summary><strong>Clearing or Re-running Calibration</strong></summary>

Calibration can be cleared with:

```gcode
EDDY_CLEAR_CALIBRATION
```

Individual setup stages can also be rerun directly using the corresponding Wizard commands.

This is useful when only one calibration stage needs to be repeated instead of restarting the entire process.

</details>

---

## 4. Configuration

<details>
<summary><strong>Canonical Directory Layout</strong></summary>

The Wizard uses one canonical configuration layout:

```text
~/printer_data/config/eddy/
├── eddy.cfg
├── eddy_macros.cfg
├── eddy_setup_wizard.cfg
└── eddy_clear_calibration.cfg
```

`printer.cfg` should activate the configuration with:

```ini
[include eddy/eddy.cfg]
```

Inside `eddy/eddy.cfg`, the Wizard support files are included with:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
[include eddy_clear_calibration.cfg]
```

</details>

<details>
<summary><strong>Eddy Configuration</strong></summary>

<details>
<summary>↳ <strong>MCU Configuration</strong></summary>

The Eddy MCU may be connected by USB or CAN.

The installer collects the required connection information during fresh installation.

Typical USB configurations use a serial path.

Typical CAN configurations use a CAN UUID.

</details>

<details>
<summary>↳ <strong>Probe Configuration</strong></summary>

The native Klipper Eddy probe uses:

```ini
[probe_eddy_current <name>]
```

The default Wizard-generated probe name is typically:

```ini
[probe_eddy_current eddy]
```

Probe X and Y offsets are collected during fresh installation.

Existing native configurations should be preserved whenever possible.

</details>

<details>
<summary>↳ <strong>Temperature Configuration</strong></summary>

Temperature support may use:

```ini
[temperature_sensor eddy]
```

and:

```ini
[temperature_probe eddy]
```

Thermal compensation requires compatible temperature sensing hardware.

</details>

</details>

<details>
<summary><strong>Bed Mesh & Zero Reference</strong></summary>

The Wizard requires an active `[bed_mesh]` section with:

```ini
zero_reference_position: X, Y
```

If `[bed_mesh]` already exists, the installer preserves the existing section.

If `zero_reference_position` is missing, the installer prompts for it and offers to add it.

If no active `[bed_mesh]` exists during a fresh installation, the installer can generate a minimal bed mesh configuration using the supplied printer geometry.

</details>

<details>
<summary><strong>Optional Printer Sections</strong></summary>

The canonical `eddy.cfg` template may contain commented reference examples for compatible printer sections.

The installer can optionally consolidate existing active sections into `eddy.cfg`.

<details>
<summary>↳ <strong>bed_screws</strong></summary>

Existing `[bed_screws]` configuration may remain in its current file or optionally be moved into `eddy.cfg`.

</details>

<details>
<summary>↳ <strong>screws_tilt_adjust</strong></summary>

Existing `[screws_tilt_adjust]` configuration may remain in its current file or optionally be moved into `eddy.cfg`.

</details>

<details>
<summary>↳ <strong>safe_z_home</strong></summary>

Existing `[safe_z_home]` configuration may remain in its current file or optionally be moved into `eddy.cfg`.

</details>

<details>
<summary>↳ <strong>homing_override</strong></summary>

Existing `[homing_override]` configuration may remain in its current file or optionally be moved into `eddy.cfg`.

</details>

<details>
<summary>↳ <strong>z_tilt</strong></summary>

Existing `[z_tilt]` configuration may remain in its current file or optionally be moved into `eddy.cfg`.

</details>

<details>
<summary>↳ <strong>quad_gantry_level</strong></summary>

Existing `[quad_gantry_level]` configuration may remain in its current file or optionally be moved into `eddy.cfg`.

</details>

</details>

---

## 5. Advanced / Technical Reference

<details>
<summary><strong>Installer Discovery</strong></summary>

<details>
<summary>↳ <strong>Active Configuration Tree</strong></summary>

The installer begins with `printer.cfg` and recursively follows active Klipper `[include ...]` directives.

Active files are always inspected, even if their filenames resemble backup files.

This determines what Klipper is actually using.

</details>

<details>
<summary>↳ <strong>Recursive Configuration Scan</strong></summary>

The installer also scans the configuration directory for inactive `.cfg` files that may contain Eddy-related configuration.

This broader scan is used for migration and cleanup detection.

</details>

<details>
<summary>↳ <strong>Historical Backup Filtering</strong></summary>

Inactive historical configuration backups are excluded before expensive Eddy-content analysis.

Examples include:

```text
printer-YYYYMMDD_HHMMSS.cfg
*.bak
*.backup
*.old
*.orig
```

Backup and archive directories are also filtered when appropriate.

Active configuration files are never skipped solely because they look like backups.

</details>

</details>

<details>
<summary><strong>Configuration Migration</strong></summary>

<details>
<summary>↳ <strong>Dedicated Eddy Configurations</strong></summary>

A dedicated Eddy configuration can be moved into:

```text
~/printer_data/config/eddy/eddy.cfg
```

The installer creates backups before moving configuration.

Old exact include references are removed when the canonical include is activated.

</details>

<details>
<summary>↳ <strong>Mixed Configuration Files</strong></summary>

If the native Eddy probe is defined inside a mixed printer configuration file, the installer avoids moving unrelated printer configuration.

Only Eddy-related or explicitly selected compatible sections should be migrated.

</details>

<details>
<summary>↳ <strong>Optional Section Consolidation</strong></summary>

Compatible active printer sections can optionally be moved into `eddy.cfg`.

The default behavior is to leave them where they are unless the user chooses to consolidate them.

Before migration:

- The source file is backed up
- `eddy.cfg` is backed up
- The exact active section is copied
- The commented template example is replaced
- The original active section is removed

</details>

</details>

<details>
<summary><strong>File Ownership & Updates</strong></summary>

The Wizard distinguishes between installer-managed files and user-owned configuration.

User-owned:

```text
eddy/eddy.cfg
```

Wizard-managed support files:

```text
eddy/eddy_macros.cfg
eddy/eddy_setup_wizard.cfg
eddy/eddy_clear_calibration.cfg
```

Normal updates should preserve user-owned Eddy configuration.

Installer-managed files may be updated when the project changes.

</details>

<details>
<summary><strong>Python Modifications</strong></summary>

<details>
<summary>↳ <strong>temperature_probe.py</strong></summary>

The project includes a modified Klipper `temperature_probe.py`.

The modified copy is required for Wizard-specific Eddy Tap behavior and calibration handling.

The installer tracks whether the file is Wizard-managed before replacing or restoring it.

</details>

<details>
<summary>↳ <strong>gcode_shell_command.py</strong></summary>

The project may install `gcode_shell_command.py` when required by the Wizard.

Compatible existing copies are preserved when possible.

Installer ownership tracking is used so unrelated user files are not removed during uninstall.

</details>

</details>

<details>
<summary><strong>Backup & Recovery Behavior</strong></summary>

Installer backups are stored under:

```text
~/printer_data/config/eddy_wizard_backups/
```

Each installer run uses a timestamped backup directory.

Backups are created before configuration files are modified.

This allows manual restoration if a migration or configuration change needs to be rolled back.

</details>

---

## 6. Troubleshooting & Safety

<details>
<summary><strong>Installer Problems</strong></summary>

If installation stops unexpectedly:

1. Read the final `[FAIL]` or `[WARN]` message.
2. Run detect-only mode:

```bash
./install.sh --detect-only
```

3. Review the reported active native Eddy probes, Eddy-NG probes, and inactive Eddy candidates.
4. Check the latest timestamped backup directory before manually editing configuration.

</details>

<details>
<summary><strong>Calibration Problems</strong></summary>

If a calibration stage fails:

- Confirm the printer is homed when required
- Confirm the probe can move safely through the requested Z range
- Confirm the correct Eddy probe is active
- Confirm the printer is mechanically stable
- Re-run only the failed Wizard stage when appropriate

</details>

<details>
<summary><strong>Eddy Tap Problems</strong></summary>

Tap calibration is sensitive to mechanical and electrical noise.

Potential sources of interference include:

- Fans
- Vibration
- Loose toolhead hardware
- Probe mounting movement
- Electrical noise
- Incorrect Tap calibration values

If Tap behavior is inconsistent, eliminate obvious vibration or airflow sources before recalibrating.

</details>

<details>
<summary><strong>Temperature Compensation Problems</strong></summary>

Thermal compensation requires compatible temperature sensing.

If the Eddy hardware does not provide usable temperature data, thermal calibration should not be expected to function correctly.

Verify the active `[temperature_probe ...]` and temperature sensor configuration before attempting thermal calibration.

</details>

<details>
<summary><strong>Backup / Recovery</strong></summary>

Before manual recovery, inspect:

```text
~/printer_data/config/eddy_wizard_backups/
```

The installer creates backups before modifying user configuration.

Restore only the files required to return the printer to the previous known-good state.

</details>

---

## 7. Project Information

<details>
<summary><strong>Compatibility</strong></summary>

This project targets current mainline Klipper native Eddy support.

The Wizard is intended for native Klipper `[probe_eddy_current ...]` configurations rather than alternate Eddy implementations.

</details>

<details>
<summary><strong>Credits</strong></summary>

Klipper Eddy Tap Wizard builds on native Klipper Eddy current probe support and the work of the Klipper community.

Additional credits and references can be listed here.

</details>

<details>
<summary><strong>Contributing</strong></summary>

Issues, testing feedback, documentation improvements, and pull requests are welcome.

When reporting installer problems, include:

- Installer output
- Relevant Eddy configuration
- Klipper version
- Connection type
- Whether the installation is fresh, migrated, or existing native Eddy

</details>

<details>
<summary><strong>License</strong></summary>

Add the project's license information here.

</details>
