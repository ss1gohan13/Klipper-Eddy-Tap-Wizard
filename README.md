# Klipper Eddy Tap Setup Wizard

A guided setup and calibration workflow for Klipper Eddy current probes using Eddy Tap.

The goal of this project is to simplify first-time Eddy setup, recalibration, and ongoing maintenance by walking the user through the required calibration steps in the correct order while using Klipper's own calibration commands wherever possible.

The project includes an installer that can create a new Eddy configuration, integrate with an existing native Klipper Eddy configuration, update the Wizard, manage the required Klipper Python extras, and safely preserve user-owned configuration files.

---

# What This Project Does

The Wizard guides the user through:

1. **LDC drive-current calibration**
2. **Main Eddy Z / frequency calibration**
3. **Eddy Tap threshold calibration**
4. **Thermal drift compensation**
5. **SAVE_CONFIG / restart progression**
6. **Final calibration summary**

The Wizard automatically detects a single configured:

```ini
[probe_eddy_current <name>]
```

The probe does not need to be named `eddy`.

For example:

```ini
[probe_eddy_current eddy]
```

or:

```ini
[probe_eddy_current probe1]
```

The Wizard uses the detected probe name automatically.

> The installer currently supports one native Eddy probe at a time.

---

# Features

- Guided setup through Klipper/Mainsail/Fluidd prompts
- Automatic Eddy probe-name detection
- Fresh Eddy configuration generation
- Full and Minimal configuration templates
- USB and CAN Eddy support for newly generated configurations
- Support for existing mainline/native Klipper Eddy configurations
- Support for previous Klipper Eddy Tap Wizard installations
- Safe legacy `config/eddy/` layout migration
- Initial LDC calibration before normal Eddy Z homing is available
- Native Klipper manual-probe controls for initial Z positioning
- Native Klipper paper-test calibration
- Automatic Eddy Tap calibration:
  - `guess`
  - `refine`
  - `verify`
- Optional thermal drift calibration
- Default thermal target of **80°C**
- Custom thermal target support:

```text
EDDY_SETUP TARGET=<temperature>
```

- Thermal calibration controls:
  - **Force Next Sample**
  - **Finish at Current Temperature**
  - **Abort Thermal Calibration**
- Setup state survives `SAVE_CONFIG` restarts
- Automatic continuation after required restarts
- Final calibration summary
- Eddy calibration reset command:

```text
EDDY_CLEAR_CALIBRATION
```

- Installer-managed backups
- Safe update support through:

```bash
./install.sh --update
```

---

# Supported Configurations

The installer currently supports:

- Fresh mainline/native Klipper Eddy installations
- Existing mainline/native:

```ini
[probe_eddy_current <name>]
```

configurations

- Previous Klipper Eddy Tap Wizard installations using the older:

```text
~/printer_data/config/eddy/
```

layout

- USB Eddy connections
- CAN Eddy connections

For fresh installations, the installer can generate either a **Full** or **Minimal** Eddy configuration.

---

# Unsupported Configurations

The installer intentionally stops before modifying printer or Klipper files when it detects configurations that are not currently supported.

These include:

- **Eddy-NG**
- **BIGTREETECH/Rappetor-style legacy Eddy configurations**
- Mixed native Eddy + Eddy-NG configurations
- Multiple configured native Eddy probes

Automatic conversion of these configurations is not currently implemented.

If an unsupported configuration is detected, the installer reports the condition and exits without continuing installation.

---

# Repository Structure

```text
Klipper-Eddy-Tap-Wizard/
│
├── install.sh
├── README.md
│
├── printer_data/
│   └── config/
│       ├── eddy_macros.cfg
│       ├── eddy_setup_wizard.cfg
│       └── templates/
│           ├── eddy.cfg.template
│           ├── eddy-minimal.cfg.template
│           └── eddy_clear_calibration.cfg.template
│
├── scripts/
│   └── clear_eddy_calibration.py
│
└── klipper/
    └── klippy/
        └── extras/
            ├── gcode_shell_command.py
            └── temperature_probe.py
```

## `eddy_setup_wizard.cfg`

Contains the guided setup system, prompt handling, setup state, automatic resume logic, and calibration completion tracking.

## `eddy_macros.cfg`

Contains the worker macros used by the Wizard, including:

```text
EDDY_LDC_PREP
EDDY_LDC_CALIBRATE
EDDY_CURRENT_PREP
EDDY_CURRENT_CALIBRATE
EDDY_TAP_CALIBRATE
EDDY_TEMP_CALIBRATE
SAVE_EDDY_TAP_OFFSET
SET_Z_FROM_PROBE
```

## `temperature_probe.py`

Contains the modified Klipper temperature-probe implementation currently required by this project for Eddy Tap thermal calibration behavior.

## `gcode_shell_command.py`

Provides the Klipper:

```text
RUN_SHELL_COMMAND
```

extension used by:

```text
EDDY_CLEAR_CALIBRATION
```

## `clear_eddy_calibration.py`

Safely removes the saved Eddy calibration values managed by `SAVE_CONFIG` while preserving unrelated printer configuration.

---

# Requirements

The Wizard expects the following Klipper features to be available:

```ini
[respond]

[force_move]
enable_force_move: True
```

A valid:

```ini
[bed_mesh]
```

configuration is also required.

Eddy calibration requires:

```ini
zero_reference_position: X, Y
```

inside `[bed_mesh]`.

The installer detects this value and can help configure it when necessary.

The Wizard also requires one valid:

```ini
[save_variables]
```

section.

If none exists, the installer can create one automatically.

---

# Installation

## 1. SSH Into the Klipper Host

Connect to the Linux host running Klipper.

Run the installer as the normal Klipper user.

> Do **not** run `install.sh` itself with `sudo`.

---

## 2. Clone the Repository

```bash
cd ~
git clone https://github.com/ss1gohan13/Klipper-Eddy-Tap-Wizard.git
```

Then enter the repository:

```bash
cd ~/Klipper-Eddy-Tap-Wizard
```

---

## 3. Run the Installer

```bash
./install.sh
```

If executable permissions were stripped during a ZIP download, Windows transfer, or another copy operation, use:

```bash
bash install.sh
```

---

# What the Installer Does

The installer:

- Discovers the active Klipper configuration tree starting from `printer.cfg`
- Detects existing native Eddy configurations
- Detects previous Eddy Tap Wizard installations
- Detects unsupported BTT/Rappetor and Eddy-NG configurations
- Creates a new Eddy configuration when one does not already exist
- Supports Full and Minimal templates
- Supports USB and CAN for generated configurations
- Preserves existing user-owned `eddy.cfg`
- Validates `[bed_mesh]`
- Validates or configures `zero_reference_position`
- Installs:

```text
eddy_macros.cfg
eddy_setup_wizard.cfg
eddy_clear_calibration.cfg
```

- Detects/adds `[save_variables]`
- Installs or validates `gcode_shell_command.py`
- Installs or validates the required `temperature_probe.py`
- Creates backups before managed files are replaced or configuration files are modified
- Verifies the resulting installation before restarting Klipper
- Restarts Klipper after a successful installation

---

# Fresh Installation

When no active Eddy configuration is detected, the installer can create:

```text
~/printer_data/config/eddy.cfg
```

You will be asked to choose:

```text
1) Full
2) Minimal
```

The **Full** template includes the core Eddy configuration plus additional commented examples.

The **Minimal** template contains the core Eddy, temperature-compensation, and bed-mesh configuration.

The installer then asks whether Eddy is connected using:

```text
1) USB
2) CAN
```

For USB, you will provide the Eddy serial path.

Example:

```text
/dev/serial/by-id/usb-Klipper_rp2040_XXXXXXXX-if00
```

For CAN, you will provide the Eddy CAN UUID.

The installer also asks for printer-specific values including:

- Probe X offset
- Probe Y offset
- Zero reference X/Y
- Bed-mesh minimum X/Y
- Bed-mesh maximum X/Y
- Calibration bed temperature
- Calibration extruder temperature
- Maximum validation temperature

These values are used to render the new `eddy.cfg`.

---

# Your `eddy.cfg` Is User-Owned

This is an important installer rule.

Once:

```text
~/printer_data/config/eddy.cfg
```

has been generated or an existing `eddy.cfg` has been adopted, it is considered **user-owned**.

Normal project updates do **not** regenerate or overwrite it.

This allows you to customize your Eddy configuration without having later Wizard updates erase those changes.

---

# Existing Native Eddy Configuration

If you already have a valid mainline Klipper configuration containing:

```ini
[probe_eddy_current <name>]
```

the installer can use it in-place.

Your existing Eddy hardware configuration is preserved.

The installer adds the Wizard components around the existing configuration rather than replacing the probe or MCU settings.

This is useful for users who already have a functional Eddy installation and only want the guided Tap setup/calibration system.

---

# Previous Wizard Installations

Older versions of this project may use:

```text
~/printer_data/config/eddy/
```

with files such as:

```text
eddy.cfg
eddy_macros.cfg
eddy_setup_wizard.cfg
```

When this layout is detected, the installer can offer:

```text
1) Keep the existing config/eddy/ layout
2) Migrate to the flat config/ layout
```

## Keep Existing Layout

The existing nested configuration remains active.

The installer updates the Wizard integration around that layout without forcing migration.

## Migrate to Flat Layout

The installer can migrate the configuration to:

```text
~/printer_data/config/eddy.cfg
~/printer_data/config/eddy_macros.cfg
~/printer_data/config/eddy_setup_wizard.cfg
~/printer_data/config/eddy_clear_calibration.cfg
```

Before migration, the existing legacy Eddy directory is backed up.

The old directory is removed only after the new configuration has been verified as active.

If migration cannot be performed safely, the installer stops rather than deleting the old configuration.

---

# Backups

Installer backups are stored under:

```text
~/printer_data/config/eddy_wizard_backups/<timestamp>/
```

Depending on the operation, backups may include:

- `printer.cfg`
- Existing Wizard files
- `temperature_probe.py`
- Legacy `config/eddy/`
- Clear-calibration configuration

The installer creates backups before managed destructive changes.

---

# `[save_variables]`

The Wizard requires one active `[save_variables]` section.

The installer searches the active Klipper config tree first.

If one already exists, it is preserved.

If none exists, the installer can create:

```ini
[save_variables]
filename: ~/printer_data/config/saved_variables.cfg
```

The actual path follows the configured Klipper config directory when installer path overrides are used.

Do not create multiple `[save_variables]` sections.

---

# Updating the Wizard

After installation:

```bash
cd ~/Klipper-Eddy-Tap-Wizard
./install.sh --update
```

The installer:

1. Determines the currently checked-out Git branch
2. Performs a fast-forward-only pull
3. Re-runs the updated installer
4. Updates project-managed files when appropriate
5. Preserves user-owned configuration
6. Re-validates the installation
7. Restarts Klipper

Your user-owned:

```text
eddy.cfg
```

is not regenerated during a normal update.

---

# Useful Installer Options

## Detect Only

```bash
./install.sh --detect-only
```

This scans and reports the current Eddy/Klipper configuration without modifying printer configuration or Klipper files.

This is useful for checking how the installer classifies an existing setup before installation.

## Automatically Accept Normal Yes/No Prompts

```bash
./install.sh --yes
```

This automatically accepts normal yes/no prompts.

> Fresh `eddy.cfg` generation still requires interactive printer geometry and connection information. Do not use `--yes` for a new Eddy configuration.

## Update

```bash
./install.sh --update
```

## Update With Automatic Yes/No Responses

```bash
./install.sh --update --yes
```

## Help

```bash
./install.sh --help
```

---

# Starting the Wizard

After installation and a successful Klipper restart, run:

```text
EDDY_SETUP
```

The Wizard checks the current configuration and determines the first missing calibration.

A fresh setup normally progresses through:

```text
LDC Calibration
      ↓
Main Eddy Z Calibration
      ↓
Eddy Tap Calibration
      ↓
Thermal Drift Calibration
      ↓
Setup Complete
```

If no matching temperature probe is configured, the thermal step is skipped.

---

# Custom Thermal Target

The default thermal calibration target is:

```text
80°C
```

To specify another target:

```text
EDDY_SETUP TARGET=70
```

or:

```text
EDDY_SETUP TARGET=90
```

The selected target survives the `SAVE_CONFIG` restarts that occur while the Wizard is active.

When setup completes or is cancelled, the stored target is cleared.

The next fresh setup returns to the default **80°C** unless another target is supplied.

---

# Setup Flow

## 1. LDC Drive-Current Calibration

On a fresh Eddy installation, the main Eddy Z calibration does not yet exist, so normal Eddy-based Z homing may not be available.

The Wizard prepares the printer for the initial LDC setup.

Typical flow:

```text
EDDY_SETUP
      ↓
Begin LDC Setup
      ↓
Home X/Y
      ↓
Move Eddy sensor near machine center
      ↓
Establish temporary Z coordinate
      ↓
Native Klipper Z-positioning interface
      ↓
Position Eddy approximately 20 mm above the bed
      ↓
ACCEPT
      ↓
Continue LDC Calibration
      ↓
LDC_CALIBRATE_DRIVE_CURRENT
```

After the native Z-positioning interface is accepted, the Wizard presents the continuation prompt for LDC calibration.

When calibration completes successfully, the Wizard detects the pending result and presents:

```text
Save & Continue
```

This runs `SAVE_CONFIG`, restarts Klipper, and allows the Wizard to resume at the next required step.

---

## 2. Main Eddy Z / Frequency Calibration

The Wizard next performs the main Eddy calibration using:

```text
PROBE_EDDY_CURRENT_CALIBRATE
```

This invokes Klipper's normal manual-probe / paper-test interface.

Use the Klipper adjustment controls until the nozzle-to-bed distance is correct and then select:

```text
ACCEPT
```

The resulting Eddy frequency-to-height calibration is staged for `SAVE_CONFIG`.

The Wizard then presents:

```text
Save & Continue
```

---

## 3. Eddy Tap Calibration

After the main Eddy calibration has been saved, the Wizard performs automatic Tap calibration.

The included wrapper runs:

```text
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=guess
```

followed by:

```text
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=refine
```

and then:

```text
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=verify
```

The printer re-homes Z between Tap calibration stages.

When the calibrated Tap values are ready, the Wizard presents:

```text
Save & Continue
```

---

## 4. Thermal Drift Calibration

If a matching:

```ini
[temperature_probe <eddy name>]
```

exists, thermal drift compensation becomes the final setup step.

The Wizard starts:

```text
TEMPERATURE_PROBE_CALIBRATE PROBE=<name> TARGET=<target> METHOD=tap
```

The default target is:

```text
80°C
```

During thermal calibration, three additional controls are available.

### Force Next Sample

```text
TEMPERATURE_PROBE_NEXT
```

Forces the next thermal drift sample before the normal temperature step is reached.

### Finish at Current Temperature

```text
TEMPERATURE_PROBE_COMPLETE
```

Attempts to complete thermal calibration using the samples already collected.

Klipper still requires enough valid samples to construct the drift calibration.

This option can be useful if the Eddy temperature plateaus below the requested target.

### Abort Thermal Calibration

```text
ABORT
```

Discards the current thermal calibration and returns the Wizard to the thermal setup stage.

---

# Matching Eddy Temperature Probe

For thermal compensation, the Eddy temperature probe must use the same name as the Eddy probe.

Example:

```ini
[probe_eddy_current eddy]
...
```

and:

```ini
[temperature_probe eddy]
sensor_type: Generic 3950
sensor_pin: eddy:gpio26

calibration_position: 117.5,117.5,5
calibration_bed_temp: 95
calibration_extruder_temp: 150
extruder_heating_z: 10
max_validation_temp: 100
```

The names must match:

```text
probe_eddy_current eddy
temperature_probe eddy
```

If no matching temperature probe exists, the Wizard completes after Eddy Tap calibration.

---

# Setup Completion

After all applicable calibrations have been saved, the Wizard displays a final summary.

Depending on the installed hardware and saved data, the summary may include values such as:

```text
LDC drive current: <value>
Tap threshold: <value>

Eddy Z calibration temp: <value>C
Thermal target: <value>C
Thermal calibration minimum temp: <value>C
Thermal compensation: OK
```

If no matching Eddy temperature probe exists:

```text
Thermal compensation: Not applicable
```

Use:

```text
Finish
```

to close the Wizard.

---

# Running Individual Calibration Macros

The worker macros may also be run independently.

## LDC Preparation

```text
EDDY_LDC_PREP
```

## LDC Calibration

```text
EDDY_LDC_CALIBRATE
```

## Main Eddy Calibration Preparation

```text
EDDY_CURRENT_PREP
```

## Main Eddy Z Calibration

```text
EDDY_CURRENT_CALIBRATE
```

## Eddy Tap Calibration

```text
EDDY_TAP_CALIBRATE
```

## Thermal Drift Calibration

Default target:

```text
EDDY_TEMP_CALIBRATE
```

Custom target:

```text
EDDY_TEMP_CALIBRATE TARGET=70
```

---

# Saving a Tap Z Offset

After first-layer tuning or Z baby stepping, the Tap Z offset can be applied using:

```text
SAVE_EDDY_TAP_OFFSET
```

This uses Klipper's:

```text
Z_OFFSET_APPLY_PROBE METHOD=tap
```

Follow the normal Klipper `SAVE_CONFIG` workflow after applying the offset.

---

# Clearing Eddy Calibration

The project provides:

```text
EDDY_CLEAR_CALIBRATION
```

This is intended for users who want to return Eddy to an uncalibrated state and run the setup process again.

The command displays a confirmation prompt before modifying the configuration.

It clears the saved Eddy calibration values associated with:

```text
LDC drive current
Main Eddy calibration
Tap threshold
Tap Z offset
Thermal compensation calibration
```

It does **not** intentionally remove unrelated printer configuration such as:

```text
Probe X/Y offsets
zero_reference_position
bed_mesh settings
MCU connection settings
```

Before changing `printer.cfg`, the helper creates a backup under:

```text
~/printer_data/config/eddy_wizard_backups/<timestamp>/
```

The command will also refuse to proceed when certain unsafe states are detected, including:

- An active or paused print
- Pending unrelated `SAVE_CONFIG` changes
- An active manual-probe operation
- No native Eddy probe
- Multiple Eddy probes

After clearing the calibration, Eddy must be calibrated again before normal use.

Run:

```text
EDDY_SETUP
```

to begin the setup process again.

---

# Modified Klipper `temperature_probe.py`

This project includes:

```text
Klipper-Eddy-Tap-Wizard/klipper/klippy/extras/temperature_probe.py
```

which corresponds to:

```text
~/klipper/klippy/extras/temperature_probe.py
```

on a typical Klipper installation.

The included version contains behavior required by this project for repeated Eddy Tap thermal sampling.

Notable changes include:

- Starting subsequent thermal Tap attempts from a known safe height above the previous Tap contact position
- Using the actual Tap result / bed reference instead of the post-Tap toolhead pullback position

The implementation currently uses:

```python
TAP_START_Z = 5.
```

The installer checks the installed file before replacing it.

If another installed `temperature_probe.py` already contains the required behavior but differs from the repository copy, the installer does not blindly overwrite it.

When the installer owns the installed copy, updates can be applied safely using its stored ownership hash.

---

# `gcode_shell_command.py`

`EDDY_CLEAR_CALIBRATION` requires the Klipper:

```text
RUN_SHELL_COMMAND
```

extension.

The project includes:

```text
Klipper-Eddy-Tap-Wizard/klipper/klippy/extras/gcode_shell_command.py
```

The installer checks whether an existing copy is already installed.

If the file is missing, the required copy is installed.

If another project or the user already manages a different copy, the installer preserves that copy rather than blindly replacing it.

---

# Important Safety Notes

## Back Up Your Printer

The installer creates targeted backups before managed changes, but maintaining your own known-good printer backup is still recommended.

Example:

```bash
cp -r ~/printer_data/config ~/printer_data/config_backup
```

## Remain Near the Printer During Initial Setup

Initial Eddy calibration can occur before normal Eddy-based Z homing is available.

The Wizard uses temporary positioning during the bootstrap process.

Remain near the printer during first-time setup and calibration.

## Verify Printer Geometry

The installer asks for printer-specific geometry when creating a fresh configuration.

Verify all entered values carefully, particularly:

- Probe offsets
- Zero reference position
- Mesh boundaries
- Safe motion area

Do not copy geometry values from another printer unless the hardware and dimensions actually match.

## One Eddy Probe

The installer and Wizard currently expect exactly one native Eddy probe.

If multiple probes are detected, installation/setup stops instead of guessing which probe to use.

---

# Troubleshooting

## `No [probe_eddy_current <name>] configuration was found`

The Wizard could not locate a native Eddy probe.

Confirm that a section similar to:

```ini
[probe_eddy_current eddy]
```

is active in the Klipper config tree.

---

## Multiple Eddy Probes Detected

The Wizard currently supports one configured native Eddy probe at a time.

Remove or disable the additional Eddy probe configuration before continuing.

---

## BTT/Rappetor Configuration Detected

The installer detected a BIGTREETECH/Rappetor-style Eddy configuration that is not currently supported by the automatic installer.

The installer intentionally exits before changing printer or Klipper files.

Automatic conversion is not currently implemented.

---

## Eddy-NG Configuration Detected

The Wizard is designed around Klipper's native:

```ini
[probe_eddy_current <name>]
```

implementation.

Eddy-NG configurations are not automatically converted.

---

## Unknown Command: `EDDY_SETUP`

Confirm that:

```text
eddy_setup_wizard.cfg
```

is active in the Klipper configuration tree.

A normal installer run verifies this before completion.

---

## Unknown Command: `EDDY_TAP_CALIBRATE`

Confirm that:

```ini
[include eddy_macros.cfg]
```

is active and that the installed `eddy_macros.cfg` is current.

---

## Duplicate `[save_variables]`

Klipper allows only one `[save_variables]` section.

If your configuration already contains one, do not create another.

The installer searches the active configuration tree before adding one.

---

## Thermal Calibration Is Skipped

Thermal drift calibration only runs when a matching temperature probe exists.

Example:

```ini
[probe_eddy_current eddy]
```

must match:

```ini
[temperature_probe eddy]
```

---

## Thermal Calibration Does Not Reach Target

The probe may reach thermal equilibrium before the requested target.

Use:

```text
Force Next Sample
```

or:

```text
Finish at Current Temperature
```

when appropriate.

Klipper still requires enough samples to construct a valid thermal drift model.

---

## Tap Calibration Fails Intermittently

Mechanical vibration and electrical noise can affect Eddy Tap detection.

Check:

- Probe mounting
- Toolhead rigidity
- Wiring
- Cable routing
- Fans or other devices introducing vibration
- Tap starting height
- Existing Tap calibration values

Do not arbitrarily increase the Tap threshold without understanding the effect on sensitivity.

---

# Updating Klipper

Eddy support continues to evolve in Klipper.

Klipper updates may change:

- Eddy G-code commands
- Status objects
- Calibration storage
- Thermal compensation
- Tap behavior
- `temperature_probe.py`

Before updating Klipper on a working printer:

1. Back up the current configuration.
2. Keep a copy of any modified Python files.
3. Review relevant upstream Eddy changes.
4. Run the Eddy Tap Wizard installer again after the Klipper update.
5. Confirm the installer still detects the required thermal Tap behavior.
6. Retest calibration before relying on the printer unattended.

---

# Contributing

Pull requests are welcome for fixes and improvements.

A typical workflow:

```bash
git switch -c my-eddy-change

# Make and test changes

git add .
git commit -m "Describe the Eddy wizard change"
git push -u origin my-eddy-change
```

Then open a Pull Request against the project repository.

---

# Credits

This project builds on Klipper's Eddy current probe, Tap probing, manual-probe, and temperature drift calibration systems.

Klipper:

https://github.com/Klipper3d/klipper

Klipper Eddy documentation:

https://www.klipper3d.org/Eddy_Probe.html

---

# License

This repository distributes modified Klipper source components.

Applicable upstream copyright and GPLv3 licensing information must remain preserved in modified Klipper files.

---

# Disclaimer

This project modifies printer calibration and Z probing behavior.

Use it at your own risk.

Review your printer configuration before running calibration, remain near the printer during initial setup, and maintain backups of a known-good Klipper configuration.
