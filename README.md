:warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning:

> [!IMPORTANT]
> This project is intended for the latest stable release of **mainline Klipper**.
>
> Before installing or running the Eddy Tap Wizard, update Klipper and review the current upstream Eddy documentation.
>
> Older Klipper versions may be missing Eddy Tap functionality or other required behavior used by this project.

:warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning::warning:

# Klipper Eddy Tap Wizard

A guided setup and calibration workflow for native Klipper Eddy current probes using Eddy Tap.

The goal of this project is to simplify Eddy calibration by guiding the user through the required native Klipper calibration steps in the correct order.

This `main` branch uses a **manual installation workflow**. It does not require moving or replacing an already-working native Eddy hardware configuration.

> [!NOTE]
> Development of the automatic installer takes place on the [`test`](https://github.com/ss1gohan13/Klipper-Eddy-Tap-Wizard/tree/test) branch.
>
> The `test` branch may contain installer behavior or configuration changes that have not yet been promoted to `main`.

After installation and a successful Klipper restart, start the Wizard with:

```gcode
EDDY_SETUP
```

---

## 1. Overview

<details>
<summary><strong>What This Project Does</strong></summary>

<br>

Klipper Eddy Tap Wizard provides a guided setup and calibration workflow around Klipper's native:

```ini
[probe_eddy_current <name>]
```

support.

The Wizard guides the user through:

1. LDC drive-current calibration
2. Main Eddy Z / frequency calibration
3. Eddy Tap threshold calibration
4. Optional thermal drift compensation
5. `SAVE_CONFIG` / restart progression
6. Final calibration status

The Wizard automatically searches the active Klipper configuration for one native Eddy probe.

The probe does **not** need to be named `eddy`.

For example:

```ini
[probe_eddy_current eddy]
```

or:

```ini
[probe_eddy_current probe1]
```

are both valid as long as exactly one native Eddy probe is active.

</details>

<details>
<summary><strong>Requirements</strong></summary>

<br>

The Wizard expects:

- Current mainline Klipper
- Exactly one active native `[probe_eddy_current ...]`
- `[respond]`
- `[force_move]` with force moves enabled
- `[save_variables]`
- `[bed_mesh]`
- A valid `zero_reference_position` inside `[bed_mesh]`
- Enough negative Z travel for controlled Eddy Tap contact

Required support sections include:

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

For a typical Cartesian/CoreXY printer, Eddy Tap also commonly requires:

```ini
[stepper_z]
position_min: -1
```

Do **not** duplicate existing Klipper sections.

If `[respond]`, `[force_move]`, `[save_variables]`, `[bed_mesh]`, or `[stepper_z]` already exists, merge the required option into the existing section.

</details>

<details>
<summary><strong>Minimum Eddy / Tap Configuration — What Must Exist Before Calibration</strong></summary>

<br>

> [!TIP]
> **Official Klipper Eddy Reference**
>
> This README describes the Wizard workflow, but Klipper's own Eddy documentation should be treated as the authoritative reference for native Eddy behavior, calibration, and Tap probing:
>
> https://github.com/Klipper3d/klipper/blob/master/docs/Eddy_Probe.md

This section is a quick reference for users manually installing the Wizard, rebuilding an Eddy configuration, or checking why Klipper cannot load the probe.

Think of Eddy setup in three stages:

```text
1. Klipper can communicate with the Eddy MCU
                    ↓
2. Klipper can load [probe_eddy_current ...]
                    ↓
3. The probe can be calibrated and used with METHOD=tap
```

> [!IMPORTANT]
> The examples below show the **minimum pieces that need to exist before calibration**.
>
> Do **not** manually invent calibration values such as `reg_drive_current`, `calibrate`, or `tap_threshold`. Klipper creates those values during calibration and stores them through `SAVE_CONFIG`.

### 1. Eddy MCU Connection

Klipper must first be able to communicate with the MCU that owns the Eddy sensor.

A USB-connected Eddy may look similar to:

```ini
[mcu eddy]
serial: /dev/serial/by-id/usb-Klipper_rp2040_XXXXXXXX-if00
restart_method: command
```

A CAN-connected Eddy may look similar to:

```ini
[mcu eddy]
canbus_uuid: YOUR_CAN_UUID
```

Use the transport appropriate for your hardware.

The MCU section does not have to be named `eddy`, but the probe's `i2c_mcu:` must match the MCU section name.

Example:

```ini
[mcu my_eddy]
serial: /dev/serial/by-id/usb-Klipper_rp2040_XXXXXXXX-if00

[probe_eddy_current eddy]
i2c_mcu: my_eddy
```

### 2. Native Eddy Probe Section

Current mainline Klipper uses:

```ini
[probe_eddy_current <name>]
```

A typical **BTT Eddy-style** configuration may look like:

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
| `sensor_type: ldc1612` | LDC1612 sensor type used by supported Eddy hardware. |
| `descend_z` | Required by current Klipper. Klipper recommends `descend_z: 0.5` as the normal starting value. |
| `x_offset` / `y_offset` | Physical X/Y distance between the probe and nozzle. |
| `i2c_mcu` | MCU that owns the Eddy sensor's I2C connection. |
| `i2c_bus` | Hardware-specific I2C bus used by the sensor. `i2c0f` is common on the BTT Eddy-style configuration used by this project. |

> [!CAUTION]
> The example above is **not a universal Eddy hardware configuration**.
>
> Other native Klipper Eddy hardware may use different MCU, I2C, pin, or temperature-sensor settings. Use the correct values for your hardware.

Current Klipper uses:

```ini
descend_z
```

instead of the older Eddy `z_offset` configuration name.

### 3. Wizard Requirements

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

The Wizard also requires an active `[bed_mesh]` containing:

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

### 4. Negative Z Travel for Tap

Native Klipper Tap probing must be able to command the nozzle slightly below the nominal Z=0 plane.

For a typical Cartesian/CoreXY printer:

```ini
[stepper_z]
# Keep your existing stepper_z settings.
position_min: -1
```

Do **not** create a second `[stepper_z]` section.

Some kinematics use an equivalent setting with another name. The requirement is the same: the printer must be allowed to move far enough for controlled nozzle-to-bed contact during Tap.

> [!WARNING]
> Negative Z travel is intentional for Tap calibration, but it also permits commanded movement below nominal Z=0.
>
> Verify the printer can mechanically make nozzle-to-bed contact safely and remain near the printer during initial Tap calibration.

### 5. Calibration Values — Do Not Pre-Fill Them

A fresh Eddy configuration is **not expected** to contain all final calibration values.

#### LDC Drive Current

Klipper runs:

```text
LDC_CALIBRATE_DRIVE_CURRENT
```

and `SAVE_CONFIG` stores the resulting drive-current calibration as:

```text
reg_drive_current
```

#### Main Eddy Height / Frequency Calibration

Klipper runs:

```text
PROBE_EDDY_CURRENT_CALIBRATE
```

and `SAVE_CONFIG` stores the main Eddy height/frequency calibration as:

```text
calibrate
```

#### Eddy Tap Threshold

Tap calibration uses:

```text
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=guess
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=refine
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=verify
```

After a successful calibration and `SAVE_CONFIG`, Klipper stores:

```text
tap_threshold
```

Once a valid `tap_threshold` exists, native commands using:

```text
METHOD=tap
```

can use the saved threshold.

#### Tap Z Offset

`tap_z_offset` is not required to begin the first Tap calibration.

If first-layer tuning later shows that a persistent Tap offset is needed, the project provides:

```gcode
SAVE_EDDY_TAP_OFFSET
SAVE_CONFIG
```

`SAVE_EDDY_TAP_OFFSET` uses Klipper's:

```text
Z_OFFSET_APPLY_PROBE METHOD=tap
```

### 6. Thermal Compensation Is Optional

A matching `[temperature_probe ...]` is **not required** simply to load an Eddy probe or perform normal Eddy Tap calibration.

Thermal compensation is an additional feature for hardware with usable probe-temperature sensing.

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

If no matching temperature probe exists, the Wizard can complete after the non-thermal Eddy calibration stages.

### 7. Pre-Calibration Checklist

Before running:

```gcode
EDDY_SETUP
```

a fresh configuration should have:

```text
✓ Eddy MCU connection
✓ [probe_eddy_current ...]
✓ valid sensor_type
✓ descend_z
✓ valid I2C connection
✓ probe X/Y offsets
✓ [respond]
✓ [force_move] with enable_force_move: True
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

Those missing calibration values are what Klipper and the Wizard create during setup.

</details>

<details>
<summary><strong>Supported / Unsupported Configurations</strong></summary>

<br>

This project is designed around **native mainline Klipper**:

```ini
[probe_eddy_current <name>]
```

configuration.

The Wizard currently expects exactly one active native Eddy probe.

Configurations that are outside the intended manual-install workflow include:

- Eddy-NG
- Multiple active native Eddy probes
- Mixed native Eddy + Eddy-NG configurations
- Vendor-specific helper systems that replace or significantly alter native Klipper Eddy behavior

The manual installation described below does **not** convert those systems into a native Klipper Eddy configuration.

</details>

---

## 2. Manual Installation

<details>
<summary><strong>Manual Installation — Recommended Main Branch Method</strong></summary>

<br>

The `main` branch uses a manual installation workflow.

The safest approach is:

```text
Keep the existing working native Eddy hardware configuration where it is
                              +
Create a small Wizard wrapper under config/eddy/
```

The intended layout is:

```text
~/printer_data/config/
├── printer.cfg
└── eddy/
    ├── eddy.cfg
    ├── eddy_macros.cfg
    └── eddy_setup_wizard.cfg
```

Your existing native Eddy hardware configuration may remain in `printer.cfg`, another included configuration file, or another dedicated Eddy hardware file.

The Wizard searches the **active Klipper configuration tree** for the native `[probe_eddy_current ...]` section.

### Step 1 — Back Up Your Configuration

Before making changes:

```bash
cp -a ~/printer_data/config ~/printer_data/config_backup_before_eddy_wizard
```

or use your normal Mainsail, Fluidd, SFTP, or backup workflow.

### Step 2 — Get the Project Files

Clone the `main` branch:

```bash
cd ~
git clone https://github.com/ss1gohan13/Klipper-Eddy-Tap-Wizard.git
```

If it is already cloned:

```bash
cd ~/Klipper-Eddy-Tap-Wizard
git switch main
git pull --ff-only
```

The two core Wizard files are:

```text
printer_data/config/eddy_macros.cfg
printer_data/config/eddy_setup_wizard.cfg
```

### Step 3 — Create the Wizard Directory

```bash
mkdir -p ~/printer_data/config/eddy
```

### Step 4 — Copy the Core Wizard Files

```bash
cp ~/Klipper-Eddy-Tap-Wizard/printer_data/config/eddy_macros.cfg \
   ~/printer_data/config/eddy/

cp ~/Klipper-Eddy-Tap-Wizard/printer_data/config/eddy_setup_wizard.cfg \
   ~/printer_data/config/eddy/
```

### Step 5 — Create `eddy/eddy.cfg`

Create:

```bash
nano ~/printer_data/config/eddy/eddy.cfg
```

with:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

This file is the **Wizard wrapper**.

It does not need to contain your native Eddy hardware configuration.

### Step 6 — Include the Wrapper From `printer.cfg`

Add:

```ini
[include eddy/eddy.cfg]
```

to:

```text
~/printer_data/config/printer.cfg
```

### Step 7 — Verify the Required Klipper Sections

Confirm exactly one active:

```ini
[probe_eddy_current <name>]
```

and exactly one:

```ini
[save_variables]
```

Confirm:

```ini
[respond]

[force_move]
enable_force_move: True
```

are available.

Confirm `[bed_mesh]` contains:

```ini
zero_reference_position: X, Y
```

and confirm the printer allows the negative Z travel required by Tap.

### Step 8 — Restart Klipper

```bash
sudo systemctl restart klipper
```

If Klipper restarts without a configuration error, the core manual installation is complete.

### Step 9 — Start the Wizard

```gcode
EDDY_SETUP
```

</details>

<details>
<summary><strong>Install Through Mainsail / Fluidd</strong></summary>

<br>

1. Open the **Machine** / **Configuration Files** section.
2. Inside your Klipper configuration directory, create:

```text
eddy
```

3. Download these files from the repository:

```text
printer_data/config/eddy_macros.cfg
printer_data/config/eddy_setup_wizard.cfg
```

4. Upload both files into:

```text
eddy/
```

5. Inside the `eddy` folder, create:

```text
eddy.cfg
```

6. Add:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

7. Leave your existing native Eddy hardware configuration in its current working location.
8. Edit `printer.cfg` and add:

```ini
[include eddy/eddy.cfg]
```

9. Confirm the active config contains exactly one `[probe_eddy_current ...]`.
10. Confirm the requirements listed above are present.
11. Save and restart Klipper.

</details>

<details>
<summary><strong>Install Through SFTP</strong></summary>

<br>

Use WinSCP, FileZilla, Cyberduck, or another SFTP-capable client.

1. Connect to the Klipper host.
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

to:

```text
~/printer_data/config/eddy/
```

5. Create:

```text
~/printer_data/config/eddy/eddy.cfg
```

with:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

6. Leave your existing native Eddy hardware configuration where it already works.
7. Add to `printer.cfg`:

```ini
[include eddy/eddy.cfg]
```

8. Restart Klipper after verifying there is exactly one active native Eddy probe.

</details>

<details>
<summary><strong>Install Through SCP</strong></summary>

<br>

First create the destination directory:

```bash
ssh USER@PRINTER_IP "mkdir -p ~/printer_data/config/eddy"
```

Then upload the two Wizard files:

```bash
scp eddy_macros.cfg USER@PRINTER_IP:~/printer_data/config/eddy/
scp eddy_setup_wizard.cfg USER@PRINTER_IP:~/printer_data/config/eddy/
```

Replace:

```text
USER
PRINTER_IP
```

with the correct SSH username and printer hostname/IP.

Then create:

```text
~/printer_data/config/eddy/eddy.cfg
```

containing:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

Leave the existing native Eddy hardware configuration in its current working location.

Add:

```ini
[include eddy/eddy.cfg]
```

to `printer.cfg`, verify the required Klipper sections, and restart Klipper.

</details>

<details>
<summary><strong>Core Manual Installation Checklist</strong></summary>

<br>

The final Wizard files should look like:

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

Your existing native Eddy hardware configuration can remain in its original active file.

Verify exactly one active:

```ini
[probe_eddy_current <name>]
```

Verify exactly one active:

```ini
[save_variables]
```

Verify:

```ini
[respond]

[force_move]
enable_force_move: True
```

Verify `[bed_mesh]` contains:

```ini
zero_reference_position: X, Y
```

Verify the printer allows the required negative Z travel for Tap.

Restart Klipper and confirm these commands are recognized:

```text
EDDY_SETUP
EDDY_LDC_PREP
EDDY_LDC_CALIBRATE
EDDY_CURRENT_PREP
EDDY_CURRENT_CALIBRATE
EDDY_TAP_CALIBRATE
EDDY_TEMP_CALIBRATE
SAVE_EDDY_TAP_OFFSET
```

</details>

<details>
<summary><strong>Updating a Manual Installation</strong></summary>

<br>

If the repository was cloned:

```bash
cd ~/Klipper-Eddy-Tap-Wizard
git switch main
git pull --ff-only
```

Then copy the updated core files again:

```bash
cp ~/Klipper-Eddy-Tap-Wizard/printer_data/config/eddy_macros.cfg \
   ~/printer_data/config/eddy/

cp ~/Klipper-Eddy-Tap-Wizard/printer_data/config/eddy_setup_wizard.cfg \
   ~/printer_data/config/eddy/
```

Restart Klipper:

```bash
sudo systemctl restart klipper
```

Your user-created:

```text
~/printer_data/config/eddy/eddy.cfg
```

wrapper does not normally need to be replaced during a core update.

If you installed any optional Python compatibility files, review the **Optional Advanced Components** section before updating Klipper.

</details>

<details>
<summary><strong>Manual Uninstall</strong></summary>

<br>

To remove only the core Wizard integration:

1. Remove or comment:

```ini
[include eddy/eddy.cfg]
```

from `printer.cfg`.

2. Restart Klipper and confirm the native Eddy configuration still loads normally.
3. Remove the Wizard directory if it contains only Wizard files:

```bash
rm -rf ~/printer_data/config/eddy
```

> [!CAUTION]
> Do not delete `~/printer_data/config/eddy/` if you intentionally placed unrelated files or your native Eddy hardware configuration there.

The core manual uninstall does **not** remove the native `[probe_eddy_current ...]` configuration or its saved Klipper calibration values.

Optional Python modifications and clear-calibration support must be removed separately if you installed them.

</details>

---

## 3. Using the Wizard

<details>
<summary><strong>Starting the Wizard</strong></summary>

<br>

After installation and a successful Klipper restart:

```gcode
EDDY_SETUP
```

The Wizard checks the current configuration and continues from the first missing calibration stage.

A fresh setup normally progresses through:

```text
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
Optional thermal drift calibration
          ↓
Setup complete
```

If no matching temperature probe exists, thermal drift calibration is not applicable and the Wizard completes after Tap calibration.

</details>

<details>
<summary><strong>Thermal Target</strong></summary>

<br>

The guided Wizard defaults to:

```text
80°C
```

when no target is supplied.

Start normally:

```gcode
EDDY_SETUP
```

or supply another starting target:

```gcode
EDDY_SETUP TARGET=70
```

The selected target is saved while the Wizard is active so it can survive required `SAVE_CONFIG` restarts.

The Wizard allows the thermal target to be adjusted before thermal calibration begins.

> [!NOTE]
> On the current `main` branch, the standalone `EDDY_TEMP_CALIBRATE` macro requires an explicit `TARGET=`.
>
> Example:
>
> ```gcode
> EDDY_TEMP_CALIBRATE TARGET=80
> ```

</details>

<details>
<summary><strong>Calibration Workflow</strong></summary>

<br>

<details>
<summary>↳ <strong>1. LDC Drive-Current Calibration</strong></summary>

<br>

The first stage determines the appropriate Eddy LDC drive current.

Relevant Wizard/worker commands include:

```gcode
EDDY_LDC_PREP
EDDY_LDC_CALIBRATE
```

During a fresh setup, normal Eddy-based Z homing may not yet be available.

The Wizard uses the initial setup preparation flow and asks the user to position the sensor approximately 20mm above the bed before running Klipper's native:

```text
LDC_CALIBRATE_DRIVE_CURRENT
```

When calibration completes, save the result when the Wizard prompts you.

</details>

<details>
<summary>↳ <strong>2. Main Eddy Z / Frequency Calibration</strong></summary>

<br>

The second stage establishes the relationship between Eddy frequency and Z height.

Relevant commands include:

```gcode
EDDY_CURRENT_PREP
EDDY_CURRENT_CALIBRATE
```

The worker macro runs Klipper's:

```text
PROBE_EDDY_CURRENT_CALIBRATE
```

and uses Klipper's normal paper-test/manual-probe workflow.

Follow the adjustment controls until the nozzle-to-bed distance is correct, then select:

```text
ACCEPT
```

When Klipper produces the calibration result, save it through the Wizard.

</details>

<details>
<summary>↳ <strong>3. Eddy Tap Calibration</strong></summary>

<br>

After the main Eddy calibration has been saved, the Wizard performs Tap threshold calibration.

The included wrapper runs:

```text
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=guess
```

then:

```text
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=refine
```

and finally:

```text
PROBE_EDDY_CURRENT_TAP_CALIBRATE TAP=verify
```

The printer re-homes Z between Tap stages.

> [!WARNING]
> Before Tap calibration, make sure the nozzle and bed are clean, the toolhead and probe mount are secure, and the nozzle can physically make controlled contact with the bed.
>
> Remain near the printer and be prepared to use Emergency Stop if contact is not detected correctly.

When a valid `tap_threshold` is ready, save it through the Wizard.

</details>

<details>
<summary>↳ <strong>4. Optional Thermal Drift Calibration</strong></summary>

<br>

Thermal drift calibration is only applicable when a matching:

```ini
[temperature_probe <eddy-name>]
```

exists.

The guided Wizard uses its selected thermal target and starts:

```text
TEMPERATURE_PROBE_CALIBRATE PROBE=<name> TARGET=<target> METHOD=tap
```

The Wizard default target is 80°C.

Thermal calibration controls may include:

```text
Force Next Sample
Finish at Current Temperature
Abort Thermal Calibration
```

Thermal compensation depends on the Eddy hardware having usable temperature sensing.

</details>

</details>

<details>
<summary><strong>Running Individual Worker Macros</strong></summary>

<br>

The worker macros may also be run independently.

### LDC Preparation

```gcode
EDDY_LDC_PREP
```

### LDC Calibration

```gcode
EDDY_LDC_CALIBRATE
```

### Main Eddy Calibration Preparation

```gcode
EDDY_CURRENT_PREP
```

### Main Eddy Z Calibration

```gcode
EDDY_CURRENT_CALIBRATE
```

### Eddy Tap Calibration

```gcode
EDDY_TAP_CALIBRATE
```

### Thermal Drift Calibration

On the current `main` branch, specify the target:

```gcode
EDDY_TEMP_CALIBRATE TARGET=80
```

### Save a Tap Z Offset

```gcode
SAVE_EDDY_TAP_OFFSET
SAVE_CONFIG
```

</details>

<details>
<summary><strong>Setup Completion</strong></summary>

<br>

After all applicable calibrations have been saved, the Wizard displays a final setup summary.

Depending on the installed hardware and saved configuration, the summary may include:

```text
LDC Drive Current: Calibrated
Eddy Z Height Calibration: Calibrated
Eddy Tap Calibration: Calibrated
Thermal Compensation: Calibrated
```

or:

```text
Thermal Compensation: Not applicable
```

when no matching Eddy temperature probe is configured.

</details>

---

## 4. Optional Advanced Components

<details>
<summary><strong>Optional Components Overview</strong></summary>

<br>

The **core manual installation** only requires:

```text
eddy_macros.cfg
eddy_setup_wizard.cfg
```

The repository also contains optional components for:

- `EDDY_CLEAR_CALIBRATION`
- `gcode_shell_command.py`
- Tap-based thermal calibration compatibility in `temperature_probe.py`

These components modify or depend on files outside the normal Klipper configuration directory.

> [!CAUTION]
> The manual workflow cannot perform the ownership and Git-state checks that an automatic installer can perform.
>
> Back up existing files and inspect local Klipper modifications before replacing Python files.

</details>

<details>
<summary><strong>Optional: EDDY_CLEAR_CALIBRATION</strong></summary>

<br>

The project provides:

```gcode
EDDY_CLEAR_CALIBRATION
```

to remove Eddy calibration values written by Klipper's `SAVE_CONFIG` block while preserving unrelated printer configuration.

It requires:

```text
printer_data/config/templates/eddy_clear_calibration.cfg.template
scripts/clear_eddy_calibration.py
klipper/klippy/extras/gcode_shell_command.py
```

### 1. Create the Real Clear-Calibration Config

Copy the template:

```bash
cp ~/Klipper-Eddy-Tap-Wizard/printer_data/config/templates/eddy_clear_calibration.cfg.template \
   ~/printer_data/config/eddy/eddy_clear_calibration.cfg
```

Edit:

```bash
nano ~/printer_data/config/eddy/eddy_clear_calibration.cfg
```

Replace:

```text
__EDDY_CLEAR_SCRIPT__
```

with the **absolute path** to:

```text
~/Klipper-Eddy-Tap-Wizard/scripts/clear_eddy_calibration.py
```

For example:

```text
/home/pi/Klipper-Eddy-Tap-Wizard/scripts/clear_eddy_calibration.py
```

Do not use `~` inside the shell-command path.

### 2. Install `gcode_shell_command.py` if Needed

First check whether it already exists:

```bash
ls -l ~/klipper/klippy/extras/gcode_shell_command.py
```

If another project already provides it, do **not** blindly overwrite it.

If it is missing:

```bash
cp ~/Klipper-Eddy-Tap-Wizard/klipper/klippy/extras/gcode_shell_command.py \
   ~/klipper/klippy/extras/gcode_shell_command.py
```

### 3. Add the Include

Add to:

```text
~/printer_data/config/eddy/eddy.cfg
```

the line:

```ini
[include eddy_clear_calibration.cfg]
```

The full wrapper then becomes:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
[include eddy_clear_calibration.cfg]
```

### 4. Restart Klipper

```bash
sudo systemctl restart klipper
```

### What the Clear Command Removes

The helper targets saved Eddy calibration values such as:

```text
reg_drive_current
calibrate
tap_threshold
tap_z_offset
calibration_temp
drift_calibration
drift_calibration_min_temp
```

It is intended to preserve:

```text
Probe X/Y offsets
zero_reference_position
bed_mesh settings
MCU connection settings
unrelated printer configuration
```

The helper creates a backup of `printer.cfg` before writing changes.

</details>

<details>
<summary><strong>Optional: Tap Thermal Calibration Compatibility</strong></summary>

<br>

The repository includes a modified:

```text
klipper/klippy/extras/temperature_probe.py
```

used by this project for repeated Tap-based thermal sampling.

On a typical Klipper installation, the destination is:

```text
~/klipper/klippy/extras/temperature_probe.py
```

> [!WARNING]
> Replacing this file modifies Klipper's tracked source tree.
>
> This can cause Klipper/Moonraker to report the repository as dirty and may interfere with normal Klipper updates.

### Before Replacing the File

Check the Git state:

```bash
cd ~/klipper
git status --short klippy/extras/temperature_probe.py
```

If the file is already modified, stop and review that modification first.

Back up the installed file:

```bash
cp ~/klipper/klippy/extras/temperature_probe.py \
   ~/klipper/klippy/extras/temperature_probe.py.before_eddy_tap
```

Then, if you intentionally want the project compatibility copy:

```bash
cp ~/Klipper-Eddy-Tap-Wizard/klipper/klippy/extras/temperature_probe.py \
   ~/klipper/klippy/extras/temperature_probe.py
```

Restart Klipper:

```bash
sudo systemctl restart klipper
```

### Before Updating Klipper

Restore the tracked upstream file before a normal Klipper update:

```bash
cd ~/klipper
git restore --source=HEAD --worktree -- klippy/extras/temperature_probe.py
```

Then verify:

```bash
git status --short klippy/extras/temperature_probe.py
```

After updating Klipper, review whether native Klipper now provides equivalent Tap thermal behavior before reapplying the project copy.

> [!NOTE]
> This Python modification is only relevant to Tap-based thermal compensation.
>
> LDC calibration, main Eddy calibration, and Eddy Tap threshold calibration do not require this manual Python replacement.

</details>

---

## 5. Configuration Reference

<details>
<summary><strong>Recommended Wizard Directory</strong></summary>

<br>

The manual `main` installation uses:

```text
~/printer_data/config/eddy/
├── eddy.cfg
├── eddy_macros.cfg
├── eddy_setup_wizard.cfg
└── eddy_clear_calibration.cfg    # optional
```

`printer.cfg` activates the wrapper with:

```ini
[include eddy/eddy.cfg]
```

The core wrapper is:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
```

If optional clear-calibration support is installed:

```ini
[include eddy_setup_wizard.cfg]
[include eddy_macros.cfg]
[include eddy_clear_calibration.cfg]
```

Your native Eddy hardware configuration may remain elsewhere in the active Klipper config tree.

</details>

<details>
<summary><strong>Matching Temperature-Probe Naming</strong></summary>

<br>

For thermal compensation, the native Eddy probe and temperature probe must use the same postfix name.

Example:

```ini
[probe_eddy_current eddy]
...
```

and:

```ini
[temperature_probe eddy]
...
```

The important relationship is:

```text
probe_eddy_current eddy
temperature_probe eddy
```

If the names do not match, the Wizard does not treat the temperature probe as the Eddy thermal-compensation sensor.

</details>

<details>
<summary><strong>Repository Files Used by Manual Installation</strong></summary>

<br>

Core Wizard files:

```text
printer_data/config/eddy_macros.cfg
printer_data/config/eddy_setup_wizard.cfg
```

Reference templates:

```text
printer_data/config/templates/eddy.cfg.template
printer_data/config/templates/eddy-minimal.cfg.template
printer_data/config/templates/eddy_clear_calibration.cfg.template
```

Clear-calibration helper:

```text
scripts/clear_eddy_calibration.py
```

Optional Klipper extras:

```text
klipper/klippy/extras/gcode_shell_command.py
klipper/klippy/extras/temperature_probe.py
```

> [!CAUTION]
> `eddy.cfg.template` and `eddy-minimal.cfg.template` contain hardware- and printer-specific placeholders.
>
> Do **not** rename either template to `eddy.cfg` and activate it unchanged.

</details>

---

## 6. Troubleshooting & Safety

<details>
<summary><strong>Important Safety Notes</strong></summary>

<br>

### Back Up the Printer

Maintain a known-good copy of the Klipper configuration before changing Eddy or Z probing behavior.

Example:

```bash
cp -a ~/printer_data/config ~/printer_data/config_backup
```

### Remain Near the Printer During Initial Calibration

Initial Eddy setup can occur before normal Eddy-based Z homing is available.

Remain near the printer during first-time calibration.

### Keep the Nozzle and Bed Clean for Tap

Debris or filament on the nozzle can affect Tap detection.

Clean the nozzle and bed before Tap calibration.

### Verify Mechanical Contact Is Possible

The nozzle must be able to physically contact the bed before another carriage stop, endstop, or mechanical limit is reached.

### Verify Negative Z Travel

Tap calibration intentionally needs enough negative Z travel for controlled contact.

Do not copy Z limits from another printer without verifying your own hardware.

</details>

<details>
<summary><strong>Unknown Command: EDDY_SETUP</strong></summary>

<br>

Confirm that:

```text
eddy_setup_wizard.cfg
```

is active through:

```ini
[include eddy/eddy.cfg]
```

and that the wrapper contains:

```ini
[include eddy_setup_wizard.cfg]
```

Restart Klipper after correcting the include.

</details>

<details>
<summary><strong>Unknown Command: EDDY_TAP_CALIBRATE</strong></summary>

<br>

Confirm the wrapper contains:

```ini
[include eddy_macros.cfg]
```

and verify the current:

```text
eddy_macros.cfg
```

was copied into the Wizard directory.

</details>

<details>
<summary><strong>No Native Eddy Probe Found</strong></summary>

<br>

If the Wizard reports:

```text
No [probe_eddy_current <name>] configuration was found.
```

confirm an active native section similar to:

```ini
[probe_eddy_current eddy]
```

exists in the active Klipper config tree.

The Wizard does not create the native hardware configuration during manual installation.

</details>

<details>
<summary><strong>Multiple Eddy Probes Detected</strong></summary>

<br>

The Wizard currently supports one active native Eddy probe.

Disable or remove the additional active `[probe_eddy_current ...]` configuration before continuing.

</details>

<details>
<summary><strong>Duplicate Klipper Sections</strong></summary>

<br>

Klipper configuration sections must remain unique.

Common mistakes during manual installation include creating a second:

```text
[save_variables]
[bed_mesh]
[stepper_z]
[force_move]
[mcu ...]
[probe_eddy_current ...]
```

instead of editing the existing section.

If Klipper reports a duplicate section, inspect the active includes and merge the required option into the original section.

</details>

<details>
<summary><strong>Tap Calibration Problems</strong></summary>

<br>

Tap calibration can be affected by:

- Dirty nozzle or bed
- Mechanical vibration
- Loose toolhead hardware
- Probe mounting movement
- Electrical noise
- Fans or airflow
- Incorrect starting height
- Incorrect or stale Tap calibration values

If the nozzle contacts the bed and does not stop as expected, use Emergency Stop.

Do not arbitrarily increase `tap_threshold` without understanding how the threshold affects detection sensitivity.

For upstream Tap troubleshooting guidance, see:

https://github.com/Klipper3d/klipper/blob/master/docs/Eddy_Probe.md

</details>

<details>
<summary><strong>Thermal Calibration Problems</strong></summary>

<br>

Thermal compensation requires a matching temperature probe and usable temperature sensing hardware.

Verify:

```text
[probe_eddy_current <name>]
[temperature_probe <same-name>]
```

match.

Tap-based thermal calibration also depends on the compatible `temperature_probe.py` behavior described in the optional installation section.

If your Eddy hardware has no usable probe-temperature sensor, thermal compensation should be treated as not applicable.

</details>

<details>
<summary><strong>Updating Klipper</strong></summary>

<br>

Eddy support continues to evolve in mainline Klipper.

Before updating Klipper:

1. Back up the printer configuration.
2. Review local changes in the Klipper repository.
3. Restore any manually replaced tracked Python file, especially `temperature_probe.py`.
4. Update Klipper.
5. Review current upstream Eddy changes.
6. Reapply project compatibility behavior only if it is still required.
7. Restart Klipper and retest Eddy calibration behavior before relying on the printer unattended.

Useful check:

```bash
cd ~/klipper
git status --short
```

</details>

---

## 7. Project Information

<details>
<summary><strong>Development Branch</strong></summary>

<br>

The `main` branch is intended to provide the stable manual-install workflow documented in this README.

Development of the next-generation automatic installer takes place on:

```text
test
```

Branch:

https://github.com/ss1gohan13/Klipper-Eddy-Tap-Wizard/tree/test

Users who only want the stable manual Wizard workflow should remain on `main`.

Users intentionally helping test installer development may use `test`, understanding that its installation and migration behavior can change before promotion to `main`.

</details>

<details>
<summary><strong>Credits</strong></summary>

<br>

Klipper Eddy Tap Wizard builds on native Klipper Eddy current probe, Tap probing, manual-probe, and temperature drift calibration systems.

Klipper:

https://github.com/Klipper3d/klipper

Official Klipper Eddy documentation:

https://github.com/Klipper3d/klipper/blob/master/docs/Eddy_Probe.md

Rendered Klipper Eddy documentation:

https://www.klipper3d.org/Eddy_Probe.html

</details>

<details>
<summary><strong>Contributing</strong></summary>

<br>

Issues, testing feedback, documentation improvements, and pull requests are welcome.

When reporting a problem, include:

- Klipper version
- Relevant Eddy configuration
- Eddy connection type
- Exact console error
- Whether thermal compensation is configured
- Whether optional Python compatibility files were installed
- Whether the issue is on `main` or `test`

</details>

<details>
<summary><strong>License</strong></summary>

<br>

This repository distributes modified Klipper source components.

Applicable upstream copyright and GPLv3 licensing information must remain preserved in modified Klipper files.

</details>

<details>
<summary><strong>Disclaimer</strong></summary>

<br>

This project modifies printer calibration and Z probing behavior.

Use it at your own risk.

Review your printer configuration before running calibration, remain near the printer during initial setup, and maintain backups of a known-good Klipper configuration.

</details>
