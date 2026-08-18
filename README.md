# gmktec-m5-fan-control

Fan control for the **GMKtec M5 PLUS** mini PC (AMD Ryzen 7 5825U) on Linux, by
talking directly to its **ITE IT5570E** embedded controller.

Out of the box this machine gives Linux no way at all to see or change the fan:

- `/sys/class/hwmon` exposes only `k10temp`, `amdgpu`, `nvme` and `mt7921_phy0` —
  there is no `pwm*` attribute anywhere.
- The ACPI DSDT has an EC device (`PNP0C09`, `\_SB_.PCI0.SBRG.EC0_`) with a
  256-byte `EmbeddedControl` region, but **no** `_FST`/`_FSL`/fan methods and no
  `PNP0C0B` fan object. There are no `thermal_zone*` entries either.
- `sensors-detect` finds the chip but has no driver for it:

  ```
  Probing for Super-I/O at 0x4e/0x4f
  Trying family `National Semiconductor/ITE'...               Yes
  Found unknown chip with ID 0x5570
  ```

- The in-tree `it87` driver does **not** support the IT5570E, and neither does
  the out-of-tree [frankcrawford/it87](https://github.com/frankcrawford/it87)
  fork ([issue #49](https://github.com/frankcrawford/it87/issues/49)): the
  IT5570E is a programmable 8051-based EC, not a fixed-function Super I/O
  hardware monitor, so its register layout is defined purely by firmware.

This tool works around all of that by editing the **fan curve table inside the
EC's own SRAM**. The firmware then keeps enforcing the modified curve itself, so
there is no polling daemon fighting the EC.

## The problem it solves

The stock curve holds duty `91` (~2700 rpm on a 40 mm fan) for anything up to
74 °C. If your machine sits around 70 °C — which it will if you have disabled
deep C-states or pinned the CPU to max frequency — it never leaves that step,
so the fan runs at 2700 rpm permanently.

On this chassis dropping that step to duty `50` (~1500 rpm) **did not raise CPU
temperature at all** (measured 68–69 °C before and after over several minutes).
Airflow is not the limiting factor; the heatsink and thermal interface are. The
extra 1200 rpm was pure noise for no thermal benefit.

## Install / use

Nothing to compile. Needs root and `/dev/port` (`CONFIG_DEVPORT`).

```bash
sudo ./gmktec-fanctl status          # show fan state and the current curve
sudo ./gmktec-fanctl apply           # apply the built-in quiet curve
sudo ./gmktec-fanctl restore         # put the factory curve back
sudo ./gmktec-fanctl monitor -i 1    # watch temp / duty / rpm / level
sudo ./gmktec-fanctl set 60          # force live PWM duty (EC overwrites in ~1s)
sudo ./gmktec-fanctl dump -o ec.bin  # dump 8KB of EC SRAM (for porting)
```

Custom curve — six duties (levels 1–6, `0..255`) and five upper temperature
bounds in °C (levels 1–5; level 6 is the top step):

```bash
sudo ./gmktec-fanctl apply --duties 25,32,40,50,118,183 --bounds 54,61,64,74,96
```

Changes live in EC SRAM only. **A power cycle restores the factory curve**, which
makes experimenting safe. `restore` also puts it back immediately.

### NixOS

```nix
{
  imports = [ /path/to/gmktec-m5-fan-control/module.nix ];

  hardware.gmktecFanControl = {
    enable = true;
    # duties = [ 25 32 40 50 118 183 ];   # default quiet curve
    # tempBounds = [ 54 61 64 74 96 ];    # default = stock bounds
  };
}
```

Or as a flake input, using `nixosModules.default`. The module installs a
systemd service plus a timer that re-applies the curve every 60 s, because the
EC reloads its factory table on events such as resume from suspend.

## Curves

Stock:

| level | duty | % | applies while | rpm |
|---|---|---|---|---|
| 1 | 45 | 17% | ≤ 54 °C | ~1300 |
| 2 | 54 | 21% | ≤ 61 °C | ~1650 |
| 3 | 73 | 28% | ≤ 64 °C | ~2200 |
| 4 | **91** | 35% | ≤ 74 °C | **~2700** |
| 5 | 118 | 46% | ≤ 96 °C | ~3600 |
| 6 | 183 | 71% | above | ~4600 |

Built-in quiet curve (`apply` with no arguments). Levels 5 and 6 are left at the
factory values, so cooling under sustained load is **identical to stock** and
only the quiet steps change:

| level | duty | % | rpm |
|---|---|---|---|
| 1 | 25 | 9% | ~600 |
| 2 | 32 | 12% | ~800 |
| 3 | 40 | 15% | ~1180 |
| 4 | **50** | 19% | **~1500** |
| 5 | 118 | 46% | ~3600 (stock) |
| 6 | 183 | 71% | ~4600 (stock) |

Measured duty → rpm on this unit:

| duty | 10 | 20 | 30 | 40 | 50 | 60 | 75 | 91 | 110 | 130 | 160 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| rpm | 295 | 499 | 731 | 1177 | 1517 | 1806 | 2268 | 2703 | 3107 | 3594 | 4161 |

Duty `0` stops the fan. The fan still spins reliably at duty `10` (295 rpm), so
there is no stall risk anywhere in the usable range.

## Behaviour under load

The EC ramps duty gradually rather than jumping, roughly one duty step per
second. Measured on a 16-thread busy loop with the quiet curve applied, duty
climbed `50 → 105` over about a minute while the CPU sat at 93 °C, then settled.
Because the ramp is slow, brief load spikes do not audibly spin the fan up,
which is most of the benefit.

If you lower levels 5 and 6 as well, you are trading peak thermal headroom for
noise you will only hear under load. A variant with level 5 at duty 105 and the
level-4 band widened to 82 °C reached 93 °C under the same stress, versus about
90 °C on the stock curve — safe against the 5825U's 105 °C Tjmax, but not worth
it. The default therefore leaves levels 5 and 6 alone.

If your machine idles right at the 74 °C level-4 boundary and keeps flipping up
to level 5, widen the quiet band instead of lowering level 5:

```bash
sudo ./gmktec-fanctl apply --bounds 54,61,64,80,96
```

## Register map

The EC's internal address space is reached through the **SMFI indirect window**
on the Super I/O port pair `0x4E`/`0x4F`. SIO config register `0x2E` selects a
sub-index and `0x2F` carries the data; sub-index `0x11`/`0x10` set the address
high/low byte and `0x12` transfers a data byte. Entering SIO config mode is the
usual ITE sequence `0x87, 0x01, 0x55, 0xAA` written to `0x4E`.

The address space follows the layout used by ITE's embedded controllers, which
is what made the rest of the map findable:

| address | contents |
|---|---|
| `0x0400`–`0x04FF` | the ACPI EC 256-byte window (so `0x0470` == ACPI EC `0x70`) |
| `0x0470` | CPU temperature in °C — tracks `k10temp` exactly |
| `0x0298`/`0x0299` | firmware-computed fan RPM, big-endian |
| `0x0761`–`0x077E` | **fan curve table** (see below) |
| `0x077D` | currently active curve level, 1–6 |
| `0x1800`–`0x18FF` | PWM controller |
| `0x1805` | **live PWM duty cycle register (DCR3)**, 0–255 |
| `0x181E`/`0x181F` | fan tachometer period count, little-endian |
| `0x1900`–`0x19FF` | ADC channels (thermistors; inversely correlated with temp) |

Fan speed from the tachometer count: `rpm ≈ 2160000 / count`. This was validated
against the firmware's own RPM value at two operating points: count 804 → 2687
computed vs 2685 reported, and count 646 → 3343 vs 3348 reported.

### Fan curve table

Six 5-byte records. The record for level N starts at `0x075F + 5 * (N - 1)` and
is laid out `[engage_temp, temp_alt, level, 0x00, duty]`:

| level | record | engage temp | duty address | stock duty |
|---|---|---|---|---|
| 1 | `0x075F` | `0x075F` = 49 °C | `0x0763` | 45 |
| 2 | `0x0764` | `0x0764` = 54 °C | `0x0768` | 54 |
| 3 | `0x0769` | `0x0769` = 61 °C | `0x076D` | 73 |
| 4 | `0x076E` | `0x076E` = 64 °C | `0x0772` | 91 |
| 5 | `0x0773` | `0x0773` = 74 °C | `0x0777` | 118 |
| 6 | `0x0778` | `0x0778` = 96 °C | `0x077C` | 183 |

`0x077D`, immediately after the last record, is the active level indicator.

A level's *engage temperature* is where it takes over, so level N is in effect
between its own engage temperature and the next level's. That is why this tool
presents `--bounds` as the upper bound of levels 1–5: the upper bound of level N
is the same byte as the engage temperature of level N+1. Level 1's own engage
temperature (`0x075F`) is the floor of the whole curve and is left untouched.

Writing a level's duty byte is enough: the EC's closed loop picks it up within
about a second and then holds it.

The duty does **not** step discontinuously between levels — the EC ramps toward
the target. During a stress ramp the duty register was observed moving
`91, 94, 99, 103, 107, 112, 116, 118`, and on cooldown it lags, holding a high
duty for a while after the temperature has fallen. So a reading part-way between
two levels' duty values simply means the ramp is still in progress.

The second field of each record (`55, 62, 65, 75, 97, 150`) is consistently a
little higher than that record's duty. Its purpose is unconfirmed and this tool
does not touch it; it may correspond to the Quiet/Balance/Performance power
modes in the BIOS.

Writing the live PWM register `0x1805` also works and takes effect instantly,
but the firmware control loop overwrites it roughly once per second, so it is
only useful for quick experiments (`set`).

## How the map was found

1. **ACPI dump.** `acpidump` + `iasl -d` on the DSDT confirmed the EC at
   `\_SB_.PCI0.SBRG.EC0_` with command port `0x66` and data port `0x62`, an
   `ERAM` region of `0xFF` bytes, and no fan methods whatsoever. The field names
   are laptop-derived (battery, LID, brightness) even though this is a mini PC.
2. **Anchor point.** `ec_sys` (`modprobe ec_sys write_support=1`) plus a stress
   test showed ACPI EC byte `0x70` following `k10temp` exactly (69 → 86 → 85 °C).
   That byte then appeared at SRAM `0x470` through the SMFI window, which both
   proved SMFI access worked and pinned the `0x400` window offset.
3. **Correlation.** 28 full 8 KB SRAM dumps were taken across an idle → stress →
   cooldown cycle (70 → 92 → 73 °C), recording `k10temp` with each. Pearson
   correlation of every byte against temperature isolated the temperature
   mirrors (r = 1.000), the duty register at `0x1805` (91 → 118, with cooldown
   hysteresis), and the inversely-correlated ADC block at `0x1900`.
4. **Verification by writing.** Holding `0x1805` at 170 drove the fan
   2679 → ~4400 rpm and releasing it let the firmware restore 91 → 2700 rpm,
   confirming both the register and that the firmware reasserts it.
5. **Sweep.** Stepping duty from 255 down to 0 while reading the tachometer
   produced the duty → rpm table above.
6. **Finding the table.** Searching SRAM for the constant `91` in the firmware
   variable region turned up `0x0772`, sitting in an obvious 5-byte record
   structure with the level indices `1..6` and rising duty values. A single
   write to `0x0772` changed the fan speed *persistently*, which identified the
   table as the correct thing to edit.

`tools/correlate.py` reproduces step 3 and is the useful starting point if you
want to port this to a different board or firmware revision.

## Porting to other machines

Many white-label mini PCs (AceMagic, Beelink, MinisForum, Bosgame, Peladn and
others) use an IT5570E. **The register map is firmware-specific — do not assume
these offsets transfer.** For instance
[passiveEndeavour/it5570-fan](https://github.com/passiveEndeavour/it5570-fan),
a hwmon driver for the AceMagic W1, finds CPU temperature at ACPI EC `0x26`,
fan duty control at `0x0F` and RPM at `0x22`/`0x23`. On this GMKtec board those
bytes are all zero and the temperature is at `0x70` instead. Same chip,
different firmware.

To port: dump SRAM across a thermal cycle, run `tools/correlate.py`, and look
for a byte that tracks temperature (your anchor) and a byte that steps up with
it and lags on cooldown (your duty register).

Related work for a different ITE EC platform:
[cmetz/ec-su_axb35-linux](https://github.com/cmetz/ec-su_axb35-linux).

## Safety

- The tool refuses to write anything unless the Super I/O chip ID reads
  `0x5570`.
- Only the fan curve duty and bound bytes are written; nothing else is touched.
- All changes are in volatile EC SRAM. A power cycle fully restores factory
  behaviour, and `restore` does it without rebooting.
- Level 6 stays at the stock duty by default, so thermal protection above 96 °C
  is unchanged. The CPU's own throttling is untouched regardless.
- Concurrent invocations are serialised with a lock, since interleaved SIO
  index/data sequences would corrupt each other.

Setting a very low duty while under sustained heavy load will let temperatures
rise. Use `monitor` to check the result on your workload before making it
permanent.

## License

GPL-2.0-only.
