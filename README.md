# Klipper Eddy Tap Setup Wizard

A guided setup and calibration workflow for Klipper Eddy current probes using Eddy Tap.

The goal of this project is to make first-time Eddy setup and recalibration easier by walking the user through the required calibration steps in the correct order, using Klipper's own calibration commands wherever possible.

> **Project status:** Active development / testing.  
> Back up your Klipper configuration and any modified Klipper source files before installing or testing this project.

---

## What This Project Does

The wizard guides the user through:

1. **LDC drive-current calibration**
2. **Main Eddy Z / frequency calibration**
3. **Eddy Tap threshold calibration**
4. **Thermal drift compensation**
5. **SAVE_CONFIG / restart progression**
6. **Final calibration summary**

The wizard automatically detects a single configured:

```ini
[probe_eddy_current <name>]
```

so the Eddy probe does not have to be named `eddy`.

For example, all of the following are valid:

```ini
[probe_eddy_current eddy]
```

```ini
[probe_eddy_current btt_eddy]
```

```ini
[probe_eddy_current probe1]
```

The setup macros discover the configured Eddy probe automatically.

---

## Features

- Guided setup through Klipper/Mainsail/Fluidd prompts
- Automatic Eddy probe-name detection
- Initial LDC calibration support before normal Z homing is available
- Native Klipper manual-probe controls for Z positioning
- Native Klipper paper-test calibration
- Automatic Eddy Tap calibration:
  - `guess`
  - `refine`
  - `verify`
- Optional thermal drift calibration
- Default thermal calibration target of **80°C**
- User-selectable thermal target with:

```text
EDDY_SETUP TARGET=<temperature>
```

- Thermal calibration controls while calibration is running:
  - **Force Next Sample**
  - **Finish at Current Temperature**
  - **Abort Thermal Calibration**
- Setup state survives `SAVE_CONFIG` restarts
- Automatically resumes the next required setup step after restart
- Final setup summary showing available calibration values
- Final **Finish** button to close the wizard

---

# Repository Structure

The repository is intentionally arranged to mirror the relevant Klipper installation directories:

```text
Klipper-Eddy-Tap-Wizard/
│
├── install.sh
├── README.md
│
├── printer_data/
│   └── config/
│       ├── eddy_macros.cfg
│       └── eddy_setup_wizard.cfg
│
└── klipper/
    └── klippy/
        └── extras/
            └── temperature_probe.py
```

This layout makes it clear where each file belongs on a normal Klipper installation.

## `printer_data/config/eddy_setup_wizard.cfg`

Contains the guided setup system, prompt handling, setup state, automatic resume logic, and calibration completion tracking.

Install to:

```text
~/printer_data/config/eddy_setup_wizard.cfg
```

## `printer_data/config/eddy_macros.cfg`

Contains the worker macros used by the wizard, including:

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

Install to:

```text
~/printer_data/config/eddy_macros.cfg
```

## `klipper/klippy/extras/temperature_probe.py`

Contains the modified Klipper temperature-probe implementation currently used by this project for Eddy Tap thermal calibration behavior.

Install to:

```text
~/klipper/klippy/extras/temperature_probe.py
```

> **Important:** Back up the original Klipper file before replacing it. See [Modified Klipper `temperature_probe.py`](#modified-klipper-temperature_probepy).

---

# Requirements

The wizard expects the following Klipper features to be available:

```ini
[respond]

[force_move]
enable_force_move: True
```

The project also uses:

```ini
[save_variables]
filename: ~/printer_data/config/saved_variables.cfg
```

> If `[save_variables]` already exists elsewhere in your configuration, do **not** define it a second time.

The exact filename is not important as long as Klipper has one valid `[save_variables]` section.

---

# Installation

The recommended installation method is the included `install.sh` script.

The installer automates the parts of the installation that are safe to automate while leaving printer-specific Eddy hardware configuration to the user.

## What the Installer Does

The installer will:

- Detect the normal Klipper paths:
  - `~/printer_data/config`
  - `~/klipper`
- Validate that the required project files exist
- Install `eddy_macros.cfg`
- Install `eddy_setup_wizard.cfg`
- Create backups before replacing existing files
- Check for the required include statements
- Offer to add missing includes to `printer.cfg`
- Check for an existing `[save_variables]` section
- Offer to add `[save_variables]` if one is not already configured
- Check the installed Klipper `temperature_probe.py`
- Detect whether the required Eddy Tap thermal changes are already present
- Back up and install the project's modified `temperature_probe.py` when required
- Avoid blindly overwriting an already-modified/newer `temperature_probe.py`
- Restart Klipper when installation is complete

The installer does **not** attempt to create your printer-specific:

```ini
[probe_eddy_current <name>]
```

or:

```ini
[temperature_probe <name>]
```

sections. MCU IDs, I2C settings, sensor pins, probe offsets, machine geometry, and similar hardware-specific values must still be configured for your printer.

---

## 1. SSH Into the Klipper Host

Connect to the Linux host running Klipper using SSH.

The following commands should be run as the normal Klipper user.

> Do **not** run the installer itself with `sudo`.

---

## 2. Clone the Repository

The current development version is on the `test` branch:

```bash
cd ~
git clone --branch test --single-branch \
  https://github.com/ss1gohan13/Klipper-Eddy-Tap-Wizard.git
```

This creates:

```text
~/Klipper-Eddy-Tap-Wizard/
```

---

## 3. Run the Installer

Enter the repository:

```bash
cd ~/Klipper-Eddy-Tap-Wizard
```

Then run:

```bash
./install.sh
```

No `chmod +x` step should be necessary when the repository is cloned normally because `install.sh` is stored in Git as an executable file.

If the executable permission was stripped by a ZIP download, Windows copy, or another transfer method, it can still be run with:

```bash
bash install.sh
```

---

## Installer Prompts

During installation you may be asked whether the script should:

- Add missing Eddy Wizard include statements
- Add `[save_variables]` if none exists
- Replace the installed `temperature_probe.py` when the required Eddy Tap changes are missing
- Restart Klipper when installation is complete

Existing files are backed up before the installer replaces or modifies them.

Backups are stored under:

```text
~/printer_data/config/eddy_wizard_backups/<timestamp>/
```

---

## Required Includes

The installer checks for:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

If they are missing, the installer can add them to:

```text
~/printer_data/config/printer.cfg
```

If you choose not to let the installer add them, add the includes manually before running `EDDY_SETUP`.

---

## `[save_variables]`

The wizard requires one valid `[save_variables]` section.

The installer checks the Klipper config tree first and will not intentionally create a duplicate.

If none exists, it can add:

```ini
[save_variables]
filename: ~/printer_data/config/saved_variables.cfg
```

---

# Updating the Wizard

After the initial installation, future project updates can be handled by the same installer.

Run:

```bash
cd ~/Klipper-Eddy-Tap-Wizard
./install.sh --update
```

The installer will:

1. Detect the currently checked-out Git branch
2. Run a fast-forward-only `git pull` from that branch
3. Re-run the updated installer
4. Update the managed project files as needed
5. Re-check `temperature_probe.py`
6. Restart Klipper when requested

While testing the project on the `test` branch, this updates from `test`.

If the project is later installed from `main`, the same command updates from `main`.

---

## Useful Installer Options

### Automatically accept normal prompts

```bash
./install.sh --yes
```

### Update and automatically accept prompts

```bash
./install.sh --update --yes
```

### Install/update without restarting Klipper

```bash
./install.sh --no-restart
```

### Show installer help

```bash
./install.sh --help
```

---

# Checking the Installed Files

The wizard configuration files are installed at:

```text
~/printer_data/config/eddy_macros.cfg
~/printer_data/config/eddy_setup_wizard.cfg
```

The modified Klipper file, when required, is installed at:

```text
~/klipper/klippy/extras/temperature_probe.py
```

The two `.cfg` files are linked to the repository checkout so project updates are immediately reflected in those files.

`temperature_probe.py` is managed as a copied file rather than a symlink. This avoids replacing a Git-tracked Klipper source file with a symlink while still allowing the installer to safely update the project-managed version.

---

# Manual Installation

Manual installation is still possible if you do not want to use `install.sh`.

Copy:

```text
Klipper-Eddy-Tap-Wizard/printer_data/config/eddy_macros.cfg
```

to:

```text
~/printer_data/config/eddy_macros.cfg
```

and:

```text
Klipper-Eddy-Tap-Wizard/printer_data/config/eddy_setup_wizard.cfg
```

to:

```text
~/printer_data/config/eddy_setup_wizard.cfg
```

Then add:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

to a loaded Klipper configuration file.

If the required Eddy Tap thermal fixes are not already present in your Klipper installation, back up:

```text
~/klipper/klippy/extras/temperature_probe.py
```

and replace it with:

```text
Klipper-Eddy-Tap-Wizard/klipper/klippy/extras/temperature_probe.py
```

Restart Klipper after manual installation.

---

# Contributing Changes With a Pull Request

A Pull Request is only needed if you want to propose changes back to the project.

A typical contribution workflow is:

1. Fork the repository on GitHub.
2. Clone your fork.
3. Create a new branch.
4. Make and test your changes.
5. Commit the changes.
6. Push the branch to your fork.
7. Open a Pull Request against this repository.

Example local workflow:

```bash
git switch -c my-eddy-change

# Make and test changes

git add .
git commit -m "Describe the Eddy wizard change"
git push -u origin my-eddy-change
```

Then use GitHub to open a Pull Request from `my-eddy-change` into the appropriate project branch.

---

# Manual Installation

If you do not want the repository files linked directly into your Klipper installation, use the manual copy method below.

## 1. Back Up Your Existing Files

Before installing, back up your configuration:

```bash
cp -r ~/printer_data/config ~/printer_data/config_backup
```

If you will be installing the included modified `temperature_probe.py`, also back up the original:

```bash
cp ~/klipper/klippy/extras/temperature_probe.py \
   ~/klipper/klippy/extras/temperature_probe.py.backup
```

---

## 2. Copy the Wizard Configuration Files

Copy:

```text
Klipper-Eddy-Tap-Wizard/printer_data/config/eddy_macros.cfg
```

to:

```text
~/printer_data/config/eddy_macros.cfg
```

and copy:

```text
Klipper-Eddy-Tap-Wizard/printer_data/config/eddy_setup_wizard.cfg
```

to:

```text
~/printer_data/config/eddy_setup_wizard.cfg
```

If the repository was cloned into your home directory, this can be done with:

```bash
cp ~/Klipper-Eddy-Tap-Wizard/printer_data/config/eddy_macros.cfg \
   ~/printer_data/config/eddy_macros.cfg

cp ~/Klipper-Eddy-Tap-Wizard/printer_data/config/eddy_setup_wizard.cfg \
   ~/printer_data/config/eddy_setup_wizard.cfg
```

---

## 3. Include the Wizard Files

Add the following to your Eddy configuration or `printer.cfg`:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

Restart Klipper after adding the includes.

---

## 4. Copy the Modified `temperature_probe.py`

If your current Klipper installation does not yet contain the required Eddy Tap thermal-calibration fixes, copy:

```text
Klipper-Eddy-Tap-Wizard/klipper/klippy/extras/temperature_probe.py
```

to:

```text
~/klipper/klippy/extras/temperature_probe.py
```

If the repository was cloned into your home directory:

```bash
cp ~/Klipper-Eddy-Tap-Wizard/klipper/klippy/extras/temperature_probe.py \
   ~/klipper/klippy/extras/temperature_probe.py
```

Then restart Klipper.

> Do not replace this file blindly after future Klipper updates. Compare the project version against current Klipper mainline first, as these fixes may eventually be merged upstream.

---

# Minimum Eddy Configuration

A typical Eddy USB/Duo configuration may look similar to:

```ini
[mcu eddy]
serial: /dev/serial/by-id/usb-Klipper_rp2040_XXXXXXXX-if00
restart_method: command

[probe_eddy_current eddy]
sensor_type: ldc1612
descend_z: 0.5

x_offset: 0
y_offset: 0

i2c_mcu: eddy
i2c_bus: i2c0f
```

The actual MCU, I2C configuration, probe offsets, and machine geometry must match your hardware.

---

# Optional Eddy Temperature Probe

If the Eddy has a usable thermistor and thermal drift compensation is desired, configure a matching temperature probe using the **same name** as the Eddy probe.

Example:

```ini
[probe_eddy_current eddy]
...

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

If no matching `[temperature_probe <name>]` exists, the wizard skips thermal calibration and completes setup after Eddy Tap calibration.

---

# Starting the Wizard

Run:

```text
EDDY_SETUP
```

The wizard checks the current configuration and determines the first missing calibration.

A fresh Eddy setup normally progresses through:

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

---

# Thermal Target

The default thermal calibration target is:

```text
80°C
```

To use a different target:

```text
EDDY_SETUP TARGET=70
```

or:

```text
EDDY_SETUP TARGET=90
```

The chosen target is saved while the wizard is active so it survives the `SAVE_CONFIG` restarts between setup steps.

After the wizard completes or is cancelled, the stored target is cleared.

The next fresh setup returns to the default of **80°C** unless another target is supplied.

---

# Setup Flow

## 1. LDC Drive-Current Calibration

On a fresh Eddy installation, the main Eddy Z calibration does not yet exist, so normal Eddy-based Z homing may not be available.

The wizard therefore prepares the printer for initial LDC setup.

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

After the native Z-positioning interface is accepted, the wizard presents a continuation prompt for the LDC calibration.

After successful calibration, the wizard detects the pending result and presents:

```text
Save & Continue
```

This runs `SAVE_CONFIG`, restarts Klipper, and automatically resumes the setup wizard.

---

## 2. Main Eddy Z / Frequency Calibration

The wizard next performs the main Eddy calibration.

The worker macro uses:

```text
PROBE_EDDY_CURRENT_CALIBRATE
```

This invokes Klipper's normal manual-probe / paper-test interface.

Use the normal Klipper adjustment controls until the nozzle-to-bed distance is correct, then select:

```text
ACCEPT
```

The resulting Eddy frequency-to-height calibration is staged for `SAVE_CONFIG`.

The wizard detects completion and prompts:

```text
Save & Continue
```

---

## 3. Eddy Tap Calibration

Once the main Eddy calibration is saved, the wizard runs automatic Tap calibration.

The included wrapper performs:

```text
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=guess
```

followed by:

```text
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=refine
```

and finally:

```text
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=verify
```

The printer re-homes Z between Tap-calibration stages.

When the calibrated `tap_threshold` is ready, the wizard again presents:

```text
Save & Continue
```

---

## 4. Thermal Drift Calibration

If a matching:

```ini
[temperature_probe <eddy name>]
```

exists, thermal drift calibration becomes the final setup step.

The wizard starts:

```text
TEMPERATURE_PROBE_CALIBRATE PROBE=<name> TARGET=<target> METHOD=tap
```

The default target is **80°C**.

While thermal calibration is running, the wizard provides three controls.

### Force Next Sample

Runs:

```text
TEMPERATURE_PROBE_NEXT
```

This forces the next drift sample before the normal temperature step is reached.

### Finish at Current Temperature

Runs:

```text
TEMPERATURE_PROBE_COMPLETE
```

This tells Klipper to finish thermal calibration using the samples collected so far.

Klipper still requires enough valid samples to generate the drift calibration.

This is useful if the Eddy temperature plateaus below the requested target.

### Abort Thermal Calibration

Runs Klipper's active calibration:

```text
ABORT
```

The current thermal calibration is discarded and the wizard returns to the thermal setup stage.

---

# Setup Completion

After all applicable calibrations are saved, the wizard displays a final summary.

Depending on the configured hardware and saved calibration data, the completion screen may show values such as:

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

The completion screen includes a:

```text
Finish
```

button which closes the wizard.

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

Defaults to 80°C:

```text
EDDY_TEMP_CALIBRATE
```

Custom target:

```text
EDDY_TEMP_CALIBRATE TARGET=70
```

---

# Saving a Tap Z Offset

After first-layer tuning / baby stepping, the Tap Z offset can be written using:

```text
SAVE_EDDY_TAP_OFFSET
```

This runs:

```text
Z_OFFSET_APPLY_PROBE METHOD=tap
```

Follow Klipper's normal `SAVE_CONFIG` workflow after applying the offset.

---

# Modified Klipper `temperature_probe.py`

This project currently includes:

```text
Klipper-Eddy-Tap-Wizard/klipper/klippy/extras/temperature_probe.py
```

which corresponds to:

```text
~/klipper/klippy/extras/temperature_probe.py
```

on a typical Klipper installation.

The modified implementation contains behavior intended to make repeated Eddy Tap thermal sampling safer and more consistent.

Notable changes include:

- Starting subsequent thermal Tap attempts from a known safe height above the previous Tap contact position
- Using the actual Tap result / bed reference rather than the post-Tap toolhead pullback position

The modified implementation uses a Tap start height of:

```python
TAP_START_Z = 5.
```

Before replacing the Klipper file:

1. Back up the original file.
2. Confirm the modified file matches the Klipper version you are running.
3. Restart the Klipper service after replacement.
4. Re-check upstream Klipper before updating, as these changes may eventually be incorporated into mainline.

Example backup:

```bash
cp ~/klipper/klippy/extras/temperature_probe.py \
   ~/klipper/klippy/extras/temperature_probe.py.backup
```

> Do not assume the included Python file should permanently replace future Klipper versions. Re-check upstream whenever Klipper is updated.

---

# Important Safety Notes

## Back Up Your Configuration

Before testing:

```bash
cp -r ~/printer_data/config ~/printer_data/config_backup
```

or make an equivalent backup through your preferred method.

## Verify Z Motion

Initial Eddy setup may occur before normal Eddy Z homing is available.

The wizard uses temporary Z positioning during the bootstrap process.

Remain near the printer during initial testing.

## Do Not Blindly Copy Geometry

This project cannot automatically determine all printer geometry, including:

- Physical bed size
- Gantry pivot locations
- Z-stepper locations
- Probe mounting offset
- Safe mesh area
- Safe homing location

These values remain printer-specific.

## One Eddy Probe

Automatic discovery currently expects exactly one configured:

```ini
[probe_eddy_current <name>]
```

If multiple Eddy probes are configured, the wizard intentionally stops instead of guessing which one to use.

---

# Troubleshooting

## `No [probe_eddy_current <name>] configuration was found`

The wizard could not locate an Eddy probe section.

Confirm that a section similar to this exists:

```ini
[probe_eddy_current eddy]
```

---

## `EDDY_SETUP currently supports one configured Eddy probe`

More than one `[probe_eddy_current ...]` section was detected.

The wizard currently supports one Eddy probe at a time.

---

## Unknown Command: `EDDY_TAP_CALIBRATE`

Confirm that:

```ini
[include eddy_macros.cfg]
```

is loaded and that `eddy_macros.cfg` contains:

```ini
[gcode_macro EDDY_TAP_CALIBRATE]
```

Restart Klipper after modifying includes.

---

## Unknown Command: `EDDY_CURRENT_PREP`

The installed `eddy_macros.cfg` is incomplete or an older version.

Make sure the full worker-macro file is installed.

---

## Duplicate `[save_variables]`

Klipper allows only one `[save_variables]` section.

If your existing configuration already contains one, remove the duplicate from the Eddy setup files.

---

## Thermal Calibration Is Skipped

The wizard only performs thermal calibration when a matching temperature probe exists.

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

The wizard provides:

```text
Force Next Sample
```

and:

```text
Finish at Current Temperature
```

to handle this situation.

Do not finish too early; Klipper still requires enough samples to generate a valid drift model.

---

## Tap Calibration Fails Intermittently

Mechanical vibration and electrical noise can affect Tap detection.

Check:

- Probe mounting
- Toolhead rigidity
- Wiring
- Cable routing
- Fans or other devices that may introduce vibration/noise
- Tap starting height
- Existing `tap_threshold`

Do not arbitrarily increase the threshold without understanding the effect on Tap sensitivity.

---

# Updating Upstream Klipper

Because Eddy support is actively evolving, Klipper updates may change:

- Eddy G-code commands
- Status objects
- Calibration storage
- Thermal compensation behavior
- Tap behavior

Before updating Klipper on a working printer:

1. Back up the current configuration.
2. Back up any modified Python files.
3. Review upstream Eddy changes.
4. Compare the bundled `temperature_probe.py` against the new upstream version.
5. Retest the wizard before relying on it unattended.

---

# Development Status

This project is intended to reduce the amount of manual command sequencing required to configure Eddy probes, but it should still be considered under active testing.

Recommended release status during early testing:

```text
v0.1.0-alpha
```

A full clean-install test should include:

```text
No Eddy calibrations
      ↓
EDDY_SETUP
      ↓
LDC calibration
      ↓
SAVE_CONFIG / restart
      ↓
Main Eddy Z calibration
      ↓
SAVE_CONFIG / restart
      ↓
Tap calibration
      ↓
SAVE_CONFIG / restart
      ↓
Thermal calibration
      ↓
SAVE_CONFIG / restart
      ↓
Setup Complete
```

---

# Credits

This project builds on Klipper's Eddy current probe, Tap probing, manual probe, and temperature drift calibration systems.

Klipper:

https://github.com/Klipper3d/klipper

Klipper Eddy documentation:

https://www.klipper3d.org/Eddy_Probe.html

---

# License

Choose a license appropriate for your project before publishing.

If this repository distributes modified Klipper source files, preserve the applicable Klipper copyright and GPLv3 licensing information in those files and ensure the repository's distribution practices comply with the GPLv3.

---

# Disclaimer

This project modifies printer calibration and Z probing behavior.

Use it at your own risk, review the configuration before running it, remain near the printer during initial testing, and maintain backups of known-good Klipper configuration and source files.
