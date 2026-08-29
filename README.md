:warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning:

> [!IMPORTANT]
> This project is intended to be used with the latest stable release of **mainline Klipper**.
>
> Before installing or running the Eddy Tap Wizard, update Klipper to the latest available release.
>
> Older Klipper versions may be missing Eddy Tap functionality or other required changes used by this project.

:warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning:

# Klipper Eddy Tap Wizard

> [!CAUTION]
> **Test Branch Notice**
>
> The `test` branch contains an installer and is under active testing.
> The installer is intended to handle the supported layouts documented below, but not every real-world Klipper/Eddy configuration has been validated yet.
>
> **Use the automatic installer first.** If it cannot complete your installation, see **Manual Installation / Installer Fallback** below for a configuration-only fallback and optional advanced components.
>
> Before testing installer changes, keep a known-good backup of your printer configuration.

---

## 1. Overview

<details>
<summary><strong>What This Project Does</strong></summary>

<br>

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

<br>

The Wizard expects:

- Current mainline Klipper
- One native `[probe_eddy_current ...]` probe
- `[respond]`
- `[force_move]` with force moves enabled
- `[bed_mesh]`
- `[save_variables]`
- A valid `zero_reference_position` inside `[bed_mesh]`

Example:

```ini
[respond]

[force_move]
enable_force_move: True

[save_variables]
filename: ~/printer_data/config/saved_variables.cfg
```

Your existing `[bed_mesh]` must include:

```ini
zero_reference_position: X, Y
```

The automatic installer validates several of these requirements and can assist with some missing configuration.

At this time, confirm that `[respond]` and `[force_move]` with `enable_force_move: True` are already present before starting the Wizard. The installer currently handles other setup checks such as `zero_reference_position`, `[save_variables]`, and Eddy Tap negative Z travel.

For a manual fallback installation, verify all of these requirements yourself before starting the Wizard.

</details>

<details>
<summary><strong>Minimum Eddy / Tap Configuration — What Must Exist Before Calibration</strong></summary>

<br>


> Official Klipper Eddy Reference
> This guide summarizes the configuration needed by the Wizard, but Klipper’s own Eddy documentation should be treated as the authoritative reference for native Eddy behavior, calibration, and Tap probing:
> https://github.com/Klipper3d/klipper/blob/master/docs/Eddy_Probe.md

This section is intended as a quick reference for users who are manually installing the Wizard, rebuilding an Eddy configuration, or checking why Klipper does not see the probe.

There are three useful stages to think about:

```text
1. Klipper can communicate with the Eddy MCU
                    ↓
2. Klipper can load [probe_eddy_current ...]
                    ↓
3. The probe can be calibrated and then used for METHOD=tap
```

> [!IMPORTANT]
> The examples below show the **minimum pieces that need to exist before calibration**.
>
> Do **not** manually invent saved calibration values such as `reg_drive_current`, the main Eddy `calibrate` data, or `tap_threshold`. Those are produced by Klipper's calibration commands and saved with `SAVE_CONFIG`.

### 1. Eddy MCU Connection

Klipper must first be able to communicate with the MCU that the Eddy sensor is connected to.

A USB-connected Eddy typically uses:

```ini
[mcu eddy]
serial: /dev/serial/by-id/usb-Klipper_rp2040_XXXXXXXX-if00
restart_method: command
```

A CAN-connected Eddy typically uses:

```ini
[mcu eddy]
canbus_uuid: YOUR_CAN_UUID
```

Use **one appropriate transport for your hardware**.

The MCU section does not have to be named `eddy`, but the name used by the probe's `i2c_mcu:` setting must match the MCU section name.

For example:

```ini
[mcu my_eddy]
serial: /dev/serial/by-id/usb-Klipper_rp2040_XXXXXXXX-if00

[probe_eddy_current eddy]
i2c_mcu: my_eddy
```

### 2. Minimum Native Eddy Probe Section

Current mainline Klipper requires a native:

```ini
[probe_eddy_current <name>]
```

section.

A typical BTT Eddy configuration used by this project looks like:

```ini
[probe_eddy_current eddy]
sensor_type: ldc1612
descend_z: 0.5
x_offset: YOUR_X_OFFSET
y_offset: YOUR_Y_OFFSET
i2c_mcu: eddy
i2c_bus: i2c0f
```

What these fields mean:

| Setting | Purpose |
| --- | --- |
| `sensor_type: ldc1612` | Required by Klipper for an LDC1612-based Eddy probe. |
| `descend_z` | Required by current Klipper. This is the nominal descent/contact distance used by normal Eddy probing. Klipper currently recommends `descend_z: 0.5` as the normal starting value. |
| `x_offset` / `y_offset` | Physical X/Y distance between the probe and nozzle. Estimate them if necessary, then refine them later. |
| `i2c_mcu` | MCU that owns the Eddy sensor's I2C connection. It must match an active `[mcu ...]` section. |
| `i2c_bus` | Hardware I2C bus used by the sensor. The project template uses `i2c0f` for the supported BTT Eddy configuration. Other hardware may use a different valid I2C definition. |

> [!NOTE]
> The probe does **not** have to be named `eddy`.
>
> The Wizard automatically searches for one active native `[probe_eddy_current ...]` section and uses that probe name.
>
> The Wizard intentionally stops if more than one native Eddy probe is active.

Current Klipper renamed the old Eddy `z_offset` configuration option to:

```ini
descend_z
```

Do not use the old `z_offset` name as the initial Eddy descent setting in a new configuration.

### 3. Requirements Used by the Wizard

The Eddy hardware section alone is not enough for the full Wizard workflow.

The Wizard also expects:

```ini
[respond]

[force_move]
enable_force_move: True
```

and exactly one active:

```ini
[save_variables]
filename: ~/printer_data/config/saved_variables.cfg
```

The Wizard also requires an active `[bed_mesh]` section containing:

```ini
zero_reference_position: X, Y
```

Example:

```ini
[bed_mesh]
# Keep your normal printer-specific mesh settings here.
zero_reference_position: 150, 150
```

Use coordinates that are valid for **your printer**.

The Wizard uses the configured `zero_reference_position` as its calibration reference location.

### 4. Z Travel Required for Eddy Tap

Native Klipper Tap probing must be able to command the nozzle slightly below the printer's nominal Z=0 plane.

For a typical Cartesian/CoreXY printer this is commonly configured in the existing `[stepper_z]` section as:

```ini
[stepper_z]
# Your existing stepper_z settings remain here.
position_min: -1
```

Do **not** create a second `[stepper_z]` section.

Add or adjust `position_min` inside the printer's existing Z configuration.

Some kinematics use a different equivalent minimum-Z setting. The goal is the same: Klipper must be allowed to move low enough for the nozzle to make controlled bed contact during `METHOD=tap`.

> [!WARNING]
> Negative Z travel is intentional for Tap calibration, but it also permits commanded motion below nominal Z=0.
>
> Verify the printer can mechanically make nozzle-to-bed contact safely and remain near the printer during initial Tap calibration.

### 5. Values Created by Calibration — Do Not Pre-Fill Them

A fresh Eddy configuration is **not expected** to already contain all of its final calibration values.

The calibration process creates them in stages.

#### LDC Drive Current

The Wizard runs Klipper's:

```text
LDC_CALIBRATE_DRIVE_CURRENT
```

The result is saved with:

```text
SAVE_CONFIG
```

This produces the Eddy drive-current calibration value (`reg_drive_current` in the saved configuration).

#### Main Eddy Height / Frequency Calibration

The Wizard runs:

```text
PROBE_EDDY_CURRENT_CALIBRATE
```

The result is saved with:

```text
SAVE_CONFIG
```

This creates the main Eddy height/frequency calibration data (`calibrate` in the saved configuration).

#### Eddy Tap Threshold

Tap probing is not enabled until a valid `tap_threshold` has been determined.

The Wizard runs Klipper's Tap calibration sequence:

```text
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=guess
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=refine
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=verify
```

After a successful calibration and `SAVE_CONFIG`, Klipper stores:

```text
tap_threshold
```

Once `tap_threshold` exists, native commands using:

```text
METHOD=tap
```

can use the saved threshold.

#### Tap Z Offset

`tap_z_offset` is not required to begin the first Tap calibration.

Its default is zero.

If first-layer tuning or Z babystepping later shows that a persistent Tap offset is needed, the project provides:

```text
SAVE_EDDY_TAP_OFFSET
```

which uses Klipper's:

```text
Z_OFFSET_APPLY_PROBE METHOD=tap
```

### 6. Thermal Compensation Is Optional for Basic Eddy / Tap

A matching `[temperature_probe ...]` is **not required just to load the Eddy probe or perform normal Eddy Tap calibration**.

Thermal compensation is an additional feature for hardware that provides usable probe temperature sensing.

When used, the temperature-probe name must match the native Eddy probe name.

Example:

```ini
[probe_eddy_current eddy]
# Eddy probe configuration...

[temperature_probe eddy]
sensor_type: Generic 3950
sensor_pin: eddy:gpio26
# Additional thermal calibration settings...
```

The important part is the matching name:

```text
probe_eddy_current eddy
temperature_probe eddy
```

If no matching temperature probe exists, the Wizard can still perform the non-thermal Eddy calibration stages.

### 7. Minimum Pre-Calibration Example

The following is an **example structure**, not a complete printer configuration:

```ini
[mcu eddy]
serial: /dev/serial/by-id/usb-Klipper_rp2040_XXXXXXXX-if00
restart_method: command

[probe_eddy_current eddy]
sensor_type: ldc1612
descend_z: 0.5
x_offset: YOUR_X_OFFSET
y_offset: YOUR_Y_OFFSET
i2c_mcu: eddy
i2c_bus: i2c0f

[respond]

[force_move]
enable_force_move: True

[save_variables]
filename: ~/printer_data/config/saved_variables.cfg

[bed_mesh]
# Keep the rest of your real bed_mesh settings.
zero_reference_position: YOUR_X, YOUR_Y
```

Your existing Z section must also permit the negative travel needed by Tap, for example:

```ini
[stepper_z]
# Keep the rest of your real stepper_z settings.
position_min: -1
```

> [!CAUTION]
> Do **not** paste the example above over existing `[bed_mesh]`, `[stepper_z]`, `[save_variables]`, or MCU sections if those sections already exist.
>
> Klipper configuration sections must remain unique. Merge the required settings into the existing sections instead of creating duplicates.

### 8. What a Fresh Config Should Look Like Before Running the Wizard

Before running:

```text
EDDY_SETUP
```

it is normal for a fresh configuration to have:

```text
✓ Eddy MCU connection
✓ [probe_eddy_current ...]
✓ sensor_type
✓ descend_z
✓ valid I2C connection
✓ probe X/Y offsets
✓ [respond]
✓ [force_move]
✓ one [save_variables]
✓ [bed_mesh] with zero_reference_position
✓ enough negative Z travel for Tap

NOT YET REQUIRED:
- reg_drive_current
- main Eddy calibrate data
- tap_threshold
- custom tap_z_offset
- thermal drift calibration
```

Those missing calibration values are exactly what the Wizard is intended to create.

### 9. Calibration Order

For a fresh Eddy configuration, the expected progression is:

```text
Eddy MCU / probe loads successfully
          ↓
LDC drive-current calibration
          ↓
SAVE_CONFIG / restart
          ↓
Main Eddy Z / frequency calibration
          ↓
SAVE_CONFIG / restart
          ↓
Eddy Tap threshold calibration
          ↓
SAVE_CONFIG / restart
          ↓
Optional thermal compensation
          ↓
Setup complete
```

The Wizard handles this progression through:

```text
EDDY_SETUP
```

For upstream details, see:

- [Klipper Eddy Current Inductive Probe documentation](https://www.klipper3d.org/Eddy_Probe.html)
- [Klipper Configuration Reference — probe_eddy_current](https://www.klipper3d.org/Config_Reference.html#probe_eddy_current)

</details>

<details>
<summary><strong>Supported Configurations</strong></summary>

<br>

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

<br>

The Wizard expects exactly one active native Eddy probe.

Conflicting or ambiguous probe configurations may require manual cleanup before installation can continue.

Examples include:

- Multiple active native Eddy probes
- Active Eddy-NG configurations
- Native Eddy and Eddy-NG active at the same time
- Unsupported legacy helper configurations that cannot be safely converted automatically

The **manual fallback does not convert Eddy-NG or BTT/Rappetor configurations into native Klipper Eddy**.

</details>

---

## 2. Installation & Management

<details>
<summary><strong>Automatic Installation — Recommended</strong></summary>

<br>

Run the installer from the project directory:

```bash
./install.sh
```

The current `test` installer menu provides:

```text
1) Install / Repair
2) Update Eddy Wizard
3) Uninstall Wizard Only
4) Full Eddy Uninstall
5) Detect only
6) Remove Eddy Patch for Klipper Update
7) Exit
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
- Validates Eddy Tap negative Z travel
- Verifies the resulting installation
- Restarts Klipper after successful installation

> [!IMPORTANT]
> The current `test` installer does not yet create or repair `[respond]` or `[force_move]`. Confirm those required sections are present before running `EDDY_SETUP`.

<details>
<summary>↳ <strong>Fresh Installation</strong></summary>

<br>

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

> [!NOTE]
> Fresh configuration generation uses the hardware layout represented by the bundled `eddy.cfg.template`.
>
> The current template is intended for the supported BTT Eddy-style native Klipper layout and includes values such as `sensor_type: ldc1612`, `i2c_bus: i2c0f`, and the optional `eddy:gpio26` temperature input.
>
> Existing native Klipper Eddy configurations may use different MCU, I2C, or temperature-sensor settings. When an existing native configuration is detected, the installer attempts to preserve the user's working hardware configuration rather than replacing those values.

</details>

<details>
<summary>↳ <strong>Existing Native Eddy Installation</strong></summary>

<br>

If an existing native `[probe_eddy_current ...]` configuration is found, the installer attempts to preserve the existing configuration rather than replacing it.

Dedicated Eddy configuration files may be moved into the canonical `config/eddy/` directory.

If the Eddy probe exists inside a mixed printer configuration file, only explicitly selected Eddy-related sections should be migrated.

</details>

</details>

<details>
<summary><strong>Manual Installation / Installer Fallback</strong></summary>

<br>

> [!IMPORTANT]
> **The manual fallback assumes you already have a working native Klipper Eddy configuration.**
>
> You should already have a valid `[mcu ...]`, `[probe_eddy_current ...]`, `[bed_mesh]`, and any applicable Eddy temperature configuration.
>
> **Leave that working native Eddy hardware configuration where it already is.** The manual fallback does not require moving it into the Wizard directory.
>
> Do **not** download `eddy.cfg.template`, rename it to `eddy.cfg`, and activate it without editing it. The template contains installer placeholders such as `{{EDDY_SERIAL}}`, `{{X_OFFSET}}`, `{{Y_OFFSET}}`, and printer-specific geometry values.

The manual fallback is useful when:

- `install.sh` stops on a layout the test installer does not yet recognize
- You already have native Eddy working and only want the Wizard macros/setup workflow
- You want to test the Wizard independently of the installer
- You prefer to place the configuration files yourself

### What the Core Manual Install Provides

The **Core Manual Install** adds:

```text
eddy_macros.cfg
eddy_setup_wizard.cfg
```

This is enough to add the main guided Wizard and worker macros around an existing working native Eddy configuration.

The following features require additional files and are covered separately under **Optional Full-Feature Manual Components**:

- `EDDY_CLEAR_CALIBRATION`
- `gcode_shell_command.py`
- The project's Tap thermal-calibration compatibility behavior in `temperature_probe.py`

### Before You Begin

Back up your printer configuration.

From SSH:

```bash
cp -a ~/printer_data/config ~/printer_data/config_backup_before_eddy_wizard
```

Or download/copy your configuration folder using your normal Mainsail, Fluidd, SFTP, or backup workflow.

### Files Needed for the Core Manual Install

Download these files from the **test branch**:

```text
printer_data/config/eddy_macros.cfg
printer_data/config/eddy_setup_wizard.cfg
```

They should ultimately be placed here:

```text
~/printer_data/config/eddy/
├── eddy.cfg
├── eddy_macros.cfg
└── eddy_setup_wizard.cfg
```

For the Core Manual Install, `eddy.cfg` is a small **Wizard wrapper**. Create it with:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

Your existing working native Eddy hardware configuration can remain in its current active file.

The Wizard searches the active Klipper configuration for one native `[probe_eddy_current ...]` section, so the probe does not need to physically live inside `eddy/eddy.cfg`.

> [!NOTE]
> Advanced users may reorganize a dedicated native Eddy configuration into `eddy/eddy.cfg` if desired, but relocation is **not required** for the manual fallback.

---

### Transfer Method 1 — Mainsail / Fluidd Web Interface

This is usually the easiest method.

1. Open your printer's Mainsail or Fluidd web interface.
2. Open the **Machine** / **Configuration Files** area.
3. Inside your Klipper config directory, create a folder named:

```text
eddy
```

4. Download the following files from this repository's `test` branch to your computer:

```text
printer_data/config/eddy_macros.cfg
printer_data/config/eddy_setup_wizard.cfg
```

5. Drag and drop or upload both files into the new `eddy` folder.
6. Inside the `eddy` folder, create a new file named:

```text
eddy.cfg
```

7. Put the following in `eddy.cfg`:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

8. Leave your existing working native Eddy hardware configuration active where it already is.
9. Edit `printer.cfg` and add:

```ini
[include eddy/eddy.cfg]
```

10. Confirm that the active config tree still contains exactly one `[probe_eddy_current ...]` section.
11. Save the files and restart Klipper.

---

### Transfer Method 2 — SFTP

You may use an SFTP client such as WinSCP, FileZilla, Cyberduck, or another SSH/SFTP-capable file manager.

1. Connect to the printer's Linux host using the same hostname/IP and SSH credentials you normally use.
2. Navigate to:

```text
~/printer_data/config/
```

3. Create:

```text
eddy/
```

4. Upload:

```text
eddy_macros.cfg
eddy_setup_wizard.cfg
```

into:

```text
~/printer_data/config/eddy/
```

5. Create:

```text
~/printer_data/config/eddy/eddy.cfg
```

6. Add to `eddy.cfg`:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

7. Leave the existing native Eddy hardware configuration in its current working location.
8. Add to `printer.cfg`:

```ini
[include eddy/eddy.cfg]
```

9. Confirm that the active config tree contains exactly one `[probe_eddy_current ...]` section.
10. Restart Klipper.

---

### Transfer Method 3 — SSH / Terminal / PuTTY

This method works from:

- Linux terminal
- macOS Terminal
- Windows PowerShell with OpenSSH
- Windows Terminal
- PuTTY / KiTTY
- Any normal SSH client

Clone the `test` branch on the Klipper host:

```bash
cd ~
git clone -b test https://github.com/ss1gohan13/Klipper-Eddy-Tap-Wizard.git
```

If the repository is already cloned:

```bash
cd ~/Klipper-Eddy-Tap-Wizard
git switch test
git pull --ff-only
```

Create the canonical directory:

```bash
mkdir -p ~/printer_data/config/eddy
```

Copy the Wizard configuration files:

```bash
cp ~/Klipper-Eddy-Tap-Wizard/printer_data/config/eddy_macros.cfg \
   ~/printer_data/config/eddy/

cp ~/Klipper-Eddy-Tap-Wizard/printer_data/config/eddy_setup_wizard.cfg \
   ~/printer_data/config/eddy/
```

Create the Wizard wrapper:

```bash
nano ~/printer_data/config/eddy/eddy.cfg
```

Add:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

Leave the existing working native Eddy hardware configuration in its current active file.

Edit `printer.cfg`:

```bash
nano ~/printer_data/config/printer.cfg
```

Add:

```ini
[include eddy/eddy.cfg]
```

Before restarting, confirm the active config tree contains exactly one `[probe_eddy_current ...]` section.

Then restart Klipper:

```bash
sudo systemctl restart klipper
```

---

### Transfer Method 4 — SCP From PowerShell / Terminal

If the files are already downloaded on another computer, `scp` can upload them directly.

First create the destination directory:

```bash
ssh USER@PRINTER_IP "mkdir -p ~/printer_data/config/eddy"
```

Then upload the Wizard files from Windows PowerShell, Linux, or macOS:

```bash
scp eddy_macros.cfg USER@PRINTER_IP:~/printer_data/config/eddy/
scp eddy_setup_wizard.cfg USER@PRINTER_IP:~/printer_data/config/eddy/
```

Replace:

```text
USER
PRINTER_IP
```

with the actual SSH username and printer hostname/IP.

Then SSH into the printer and create:

```text
~/printer_data/config/eddy/eddy.cfg
```

containing:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

Leave your existing native Eddy hardware configuration in its current working location, add `[include eddy/eddy.cfg]` to `printer.cfg`, and confirm there is exactly one active `[probe_eddy_current ...]` section before restarting Klipper.

---

### Core Manual Configuration Checklist

Before using this checklist, review **Minimum Eddy / Tap Configuration — What Must Exist Before Calibration** in the Overview section above.

That section separates the settings that must already exist from the values that Klipper and the Wizard intentionally generate during calibration.

Your final active layout should look like:

```text
~/printer_data/config/
├── printer.cfg
└── eddy/
    ├── eddy.cfg
    ├── eddy_macros.cfg
    └── eddy_setup_wizard.cfg
```

`printer.cfg`:

```ini
[include eddy/eddy.cfg]
```

`eddy/eddy.cfg`:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

Your existing `[mcu ...]`, `[probe_eddy_current ...]`, and related native Eddy hardware configuration may remain in its original active file.

Verify that the active config tree contains exactly one:

```ini
[probe_eddy_current <name>]
```

Verify that `[bed_mesh]` contains:

```ini
zero_reference_position: X, Y
```

Verify exactly one active:

```ini
[save_variables]
```

and confirm:

```ini
[respond]

[force_move]
enable_force_move: True
```

are available.

---

### Verify the Core Manual Install

Restart Klipper and confirm that these commands are recognized:

```text
EDDY_SETUP
EDDY_LDC_PREP
EDDY_LDC_CALIBRATE
EDDY_CURRENT_PREP
EDDY_CURRENT_CALIBRATE
EDDY_TAP_CALIBRATE
```

If Klipper reports a duplicate config section, do **not** delete random sections.

Check whether the original Eddy configuration is still included elsewhere in the active configuration tree.

If Klipper reports an unknown Wizard command, verify:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

are active through `eddy/eddy.cfg`.

---

### Optional Full-Feature Manual Components

> [!CAUTION]
> These steps modify or depend on files outside the normal printer config directory.
>
> The automatic installer performs ownership checks and backups before touching these files. A manual installation cannot reproduce all of those installer safety checks automatically.
>
> If the **Core Manual Install** is sufficient for what you are testing, stop there.

#### A. `EDDY_CLEAR_CALIBRATION`

`EDDY_CLEAR_CALIBRATION` requires all of the following:

```text
eddy_clear_calibration.cfg
scripts/clear_eddy_calibration.py
gcode_shell_command.py
```

The repository contains:

```text
printer_data/config/templates/eddy_clear_calibration.cfg.template
```

Do **not** use the template unchanged.

It contains:

```text
__EDDY_CLEAR_SCRIPT__
```

which must be replaced with the real path to `clear_eddy_calibration.py`.

If the repository is cloned at:

```text
~/Klipper-Eddy-Tap-Wizard/
```

a practical manual path is:

```text
/home/<USER>/Klipper-Eddy-Tap-Wizard/scripts/clear_eddy_calibration.py
```

Replace `<USER>` with the Linux username used on the Klipper host.

Create the real config from the template:

```bash
cp ~/Klipper-Eddy-Tap-Wizard/printer_data/config/templates/eddy_clear_calibration.cfg.template \
   ~/printer_data/config/eddy/eddy_clear_calibration.cfg
```

Then edit:

```bash
nano ~/printer_data/config/eddy/eddy_clear_calibration.cfg
```

Replace:

```text
__EDDY_CLEAR_SCRIPT__
```

with the full absolute path to:

```text
~/Klipper-Eddy-Tap-Wizard/scripts/clear_eddy_calibration.py
```

For example:

```text
/home/pi/Klipper-Eddy-Tap-Wizard/scripts/clear_eddy_calibration.py
```

Add this include to `eddy/eddy.cfg`:

```ini
[include eddy_clear_calibration.cfg]
```

#### B. `gcode_shell_command.py`

First check whether it already exists:

```bash
ls -l ~/klipper/klippy/extras/gcode_shell_command.py
```

If another project already provides it, do not blindly overwrite it.

If it is missing, the repository copy is located at:

```text
Klipper-Eddy-Tap-Wizard/klipper/klippy/extras/gcode_shell_command.py
```

Back up the Klipper extras directory/file as appropriate, then copy:

```bash
cp ~/Klipper-Eddy-Tap-Wizard/klipper/klippy/extras/gcode_shell_command.py \
   ~/klipper/klippy/extras/gcode_shell_command.py
```

Restart Klipper after installing the Python extra.

#### C. Tap Thermal Calibration / `temperature_probe.py`

The Wizard may require compatibility behavior in:

```text
~/klipper/klippy/extras/temperature_probe.py
```

for:

```text
TEMPERATURE_PROBE_CALIBRATE ... METHOD=tap
```

The automatic installer checks whether current native Klipper already contains the required behavior, detects compatible custom copies, refuses unknown local modifications, and only installs the project patch when needed.

Because of that, **manual replacement of `temperature_probe.py` is intentionally not the first fallback recommendation**.

If you only need:

- LDC calibration
- Main Eddy calibration
- Eddy Tap threshold calibration

you can use the Core Manual Install without manually replacing `temperature_probe.py`.

If you need Tap-based thermal compensation and the automatic installer cannot perform the compatibility check, first inspect your Klipper file:

```bash
cd ~/klipper
git status --short klippy/extras/temperature_probe.py
```

If that file is already modified, stop and review the existing modification before replacing it.

If you intentionally choose to use the project compatibility copy, create a backup first:

```bash
cp ~/klipper/klippy/extras/temperature_probe.py \
   ~/klipper/klippy/extras/temperature_probe.py.before_eddy_manual
```

Then copy the project version:

```bash
cp ~/Klipper-Eddy-Tap-Wizard/klipper/klippy/extras/temperature_probe.py \
   ~/klipper/klippy/extras/temperature_probe.py
```

> [!WARNING]
> This intentionally makes the Klipper Git working tree locally modified.
>
> Before updating Klipper, restore/review the modified `temperature_probe.py`. The automatic installer's **Remove Eddy Patch for Klipper Update** option normally manages this lifecycle when the installer owns the patch.

Restart Klipper after making Python-file changes:

```bash
sudo systemctl restart klipper
```

---

### Manual Install Does Not Perform Installer Safety Checks

A manual fallback bypasses several protections provided by `install.sh`, including:

- Automatic active-config-tree discovery
- Unsupported-layout classification
- Duplicate-section checks
- Automatic backups for every managed change
- Ownership hashing for managed files
- `temperature_probe.py` Git/ownership checks
- Automatic negative Z travel validation
- Automatic final installation verification

Use the manual path deliberately and keep backups.

</details>

<details>
<summary><strong>Update</strong></summary>

<br>

Run:

```bash
./install.sh --update
```

or select:

```text
2) Update Eddy Wizard
```

from the installer menu.

The updater performs a fast-forward Git update of the currently checked-out branch and then reruns the installer.

User-owned `eddy.cfg` content is preserved during normal updates.

</details>

<details>
<summary><strong>Uninstallation</strong></summary>

<br>

The current test installer provides two uninstall paths.

### Uninstall Wizard Only

Run:

```bash
./install.sh --uninstall
```

or:

```bash
./install.sh --uninstall-wizard
```

or select:

```text
3) Uninstall Wizard Only
```

This removes Wizard integration while preserving the native Eddy configuration and saved calibration.

### Full Eddy Uninstall

Run:

```bash
./install.sh --uninstall-all
```

or select:

```text
4) Full Eddy Uninstall
```

This is intended to completely remove the canonical Eddy configuration.

Before making changes, the installer preflights the current `eddy.cfg`, checks for unknown sections and duplicate restorable sections, and creates backups.

Portable printer sections stored in `eddy.cfg` may be restored to `printer.cfg`.

Klipper is **not restarted automatically** after a Full Eddy Uninstall because Eddy may have been used as the printer's Z probe/endstop.

Configure a replacement probe or physical Z endstop before restarting Klipper when applicable.

</details>

<details>
<summary><strong>Detect Only</strong></summary>

<br>

Run:

```bash
./install.sh --detect-only
```

or select:

```text
5) Detect only
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

<details>
<summary><strong>Prepare Klipper for Update</strong></summary>

<br>

Select:

```text
6) Remove Eddy Patch for Klipper Update
```

or run:

```bash
./install.sh --prepare-klipper-update
```

The Wizard may use a compatibility modification to Klipper's:

```text
klippy/extras/temperature_probe.py
```

This option restores Klipper's own current Git `HEAD` version when the Wizard-managed compatibility patch is present.

It leaves the Eddy configuration and saved calibration unchanged.

After updating Klipper, run **Install / Repair** again. The compatibility patch is only reinstalled if the updated Klipper version still requires it.

</details>

---

## 3. Using the Wizard

<details>
<summary><strong>Starting the Wizard</strong></summary>

<br>

After installation, start the guided setup from the Klipper console with:

```gcode
EDDY_SETUP
```

If no thermal target is supplied, the Wizard defaults to **80°C**. The target can be adjusted from the Wizard before thermal calibration begins.

To begin the Wizard with a specific starting target:

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

<br>

The Wizard guides the user through the required Eddy calibration stages in sequence.

<details>
<summary>↳ <strong>1. LDC Drive Current Calibration</strong></summary>

<br>

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

<br>

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

<br>

This stage calibrates Eddy Tap behavior.

Relevant command:

```gcode
EDDY_TAP_CALIBRATE
```

The resulting Tap calibration is used for contact-based Z probing.

</details>

<details>
<summary>↳ <strong>4. Thermal Compensation</strong></summary>

<br>

Thermal compensation is optional and depends on the probe hardware and temperature sensing available in the installation.

The standalone thermal calibration macro defaults to **80°C** when no target is supplied:

```gcode
EDDY_TEMP_CALIBRATE
```

To use a different target manually:

```gcode
EDDY_TEMP_CALIBRATE TARGET=70
```

The guided `EDDY_SETUP` workflow also defaults to 80°C and allows the user to adjust the target before thermal calibration begins.

> [!NOTE]
> If a matching `[temperature_probe <name>]` is added **after** the main Eddy Z calibration was performed, rerun `EDDY_CURRENT_CALIBRATE` and `SAVE_CONFIG` before thermal calibration. Klipper must record `calibration_temp` for the matching temperature probe before `EDDY_TEMP_CALIBRATE` can proceed.

The Wizard guides the user through the thermal calibration process when applicable.

</details>

</details>

<details>
<summary><strong>Saving Calibration</strong></summary>

<br>

The Wizard uses Klipper's normal configuration save and restart flow.

When instructed, run:

```gcode
SAVE_CONFIG
```

After Klipper restarts, continue with the next Wizard step.

Tap offset saving is handled with:

```gcode
SAVE_EDDY_TAP_OFFSET
SAVE_CONFIG
```

`SAVE_EDDY_TAP_OFFSET` applies the current Tap Z offset to Klipper's pending configuration. `SAVE_CONFIG` then writes that value permanently and restarts Klipper.

</details>

<details>
<summary><strong>Clearing or Re-running Calibration</strong></summary>

<br>

When the clear-calibration support files are installed, calibration can be cleared with:

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

<br>

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

Inside `eddy/eddy.cfg`, the full Wizard installation uses:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
[include eddy_clear_calibration.cfg]
```

A Core Manual Install may omit `eddy_clear_calibration.cfg` until the optional clear-calibration helper is installed.

</details>

<details>
<summary><strong>Eddy Configuration</strong></summary>

<br>

<details>
<summary>↳ <strong>MCU Configuration</strong></summary>

<br>

The Eddy MCU may be connected by USB or CAN.

The installer collects the required connection information during fresh installation.

Typical USB configurations use a serial path.

Typical CAN configurations use a CAN UUID.

</details>

<details>
<summary>↳ <strong>Probe Configuration</strong></summary>

<br>

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

<br>

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

<br>

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

<br>

The canonical `eddy.cfg` template may contain commented reference examples for compatible printer sections.

The installer can optionally consolidate existing active sections into `eddy.cfg`.

<details>
<summary>↳ <strong>bed_screws</strong></summary>

<br>

Existing `[bed_screws]` configuration may remain in its current file or optionally be moved into `eddy.cfg`.

</details>

<details>
<summary>↳ <strong>screws_tilt_adjust</strong></summary>

<br>

Existing `[screws_tilt_adjust]` configuration may remain in its current file or optionally be moved into `eddy.cfg`.

</details>

<details>
<summary>↳ <strong>safe_z_home</strong></summary>

<br>

Existing `[safe_z_home]` configuration may remain in its current file or optionally be moved into `eddy.cfg`.

</details>

<details>
<summary>↳ <strong>homing_override</strong></summary>

<br>

Existing `[homing_override]` configuration may remain in its current file or optionally be moved into `eddy.cfg`.

</details>

<details>
<summary>↳ <strong>z_tilt</strong></summary>

<br>

Existing `[z_tilt]` configuration may remain in its current file or optionally be moved into `eddy.cfg`.

</details>

<details>
<summary>↳ <strong>quad_gantry_level</strong></summary>

<br>

Existing `[quad_gantry_level]` configuration may remain in its current file or optionally be moved into `eddy.cfg`.

</details>

</details>

---

## 5. Advanced / Technical Reference

<details>
<summary><strong>Installer Discovery</strong></summary>

<br>

<details>
<summary>↳ <strong>Active Configuration Tree</strong></summary>

<br>

The installer begins with `printer.cfg` and recursively follows active Klipper `[include ...]` directives.

Active files are always inspected, even if their filenames resemble backup files.

This determines what Klipper is actually using.

</details>

<details>
<summary>↳ <strong>Recursive Configuration Scan</strong></summary>

<br>

The installer also scans the configuration directory for inactive `.cfg` files that may contain Eddy-related configuration.

This broader scan is used for migration and cleanup detection.

</details>

<details>
<summary>↳ <strong>Historical Backup Filtering</strong></summary>

<br>

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

<br>

<details>
<summary>↳ <strong>Dedicated Eddy Configurations</strong></summary>

<br>

A dedicated Eddy configuration can be moved into:

```text
~/printer_data/config/eddy/eddy.cfg
```

The installer creates backups before moving configuration.

Old exact include references are removed when the canonical include is activated.

</details>

<details>
<summary>↳ <strong>Mixed Configuration Files</strong></summary>

<br>

If the native Eddy probe is defined inside a mixed printer configuration file, the installer avoids moving unrelated printer configuration.

Only Eddy-related or explicitly selected compatible sections should be migrated.

</details>

<details>
<summary>↳ <strong>Optional Section Consolidation</strong></summary>

<br>

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

<br>

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

<br>

<details>
<summary>↳ <strong>temperature_probe.py</strong></summary>

<br>

The project includes a modified Klipper `temperature_probe.py`.

The compatibility copy is used only while native Klipper lacks the behavior required by the Wizard's Tap-based thermal calibration.

The installer checks the current Klipper Git `HEAD`, detects Wizard-owned or compatible custom copies, and refuses to overwrite unknown local modifications.

</details>

<details>
<summary>↳ <strong>gcode_shell_command.py</strong></summary>

<br>

The project may install `gcode_shell_command.py` when required by the Wizard.

Compatible existing copies are preserved when possible.

Installer ownership tracking is used so unrelated user files are not removed during uninstall.

</details>

</details>

<details>
<summary><strong>Backup & Recovery Behavior</strong></summary>

<br>

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

<br>

If installation stops unexpectedly:

1. Read the final `[FAIL]` or `[WARN]` message.
2. Run detect-only mode:

```bash
./install.sh --detect-only
```

3. Review the reported active native Eddy probes, Eddy-NG probes, and inactive Eddy candidates.
4. Check the latest timestamped backup directory before manually editing configuration.
5. If the failure is installer-specific and your native Eddy configuration is already functional, use the **Manual Installation / Installer Fallback** section above.

</details>

<details>
<summary><strong>Calibration Problems</strong></summary>

<br>

If a calibration stage fails:

- Confirm the printer is homed when required
- Confirm the probe can move safely through the requested Z range
- Confirm the correct Eddy probe is active
- Confirm the printer is mechanically stable
- Re-run only the failed Wizard stage when appropriate

</details>

<details>
<summary><strong>Eddy Tap Problems</strong></summary>

<br>

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

<br>

Thermal compensation requires compatible temperature sensing.

If the Eddy hardware does not provide usable temperature data, thermal calibration should not be expected to function correctly.

Verify the active `[temperature_probe ...]` and temperature sensor configuration before attempting thermal calibration.

</details>

<details>
<summary><strong>Backup / Recovery</strong></summary>

<br>

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

<br>

This project targets current mainline Klipper native Eddy support.

The Wizard is intended for native Klipper `[probe_eddy_current ...]` configurations rather than alternate Eddy implementations.

</details>

<details>
<summary><strong>Credits</strong></summary>

<br>

Klipper Eddy Tap Wizard builds on native Klipper Eddy current probe support and the work of the Klipper community.

Additional credits and references can be listed here.

</details>

<details>
<summary><strong>Contributing</strong></summary>

<br>

Issues, testing feedback, documentation improvements, and pull requests are welcome.

When reporting installer problems, include:

- Installer output
- Relevant Eddy configuration
- Klipper version
- Connection type
- Whether the installation is fresh, migrated, or existing native Eddy
- Whether the automatic installer or manual fallback was used

</details>

<details>
<summary><strong>License</strong></summary>

<br>

Add the project's license information here.

</details>
