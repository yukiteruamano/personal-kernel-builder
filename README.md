# personal-kernel-builder

Personal Linux kernel configs for specific machines, and the tool that builds and
installs them on Slackware.

- [`personal-kernel-builder/`](personal-kernel-builder/README.md): builds a kernel from
  Slackware's `kernel-source` without root, installs it as GRUB's default entry and can
  uninstall it. Packaged as a SlackBuild.
- [`seed/`](#seed-configs): customized kernel configs, one per machine, ready to be
  imported with `personal-kernel-builder init --config`.

Only customized configs live here: Slackware's stock config is already public and is
read from `/boot/config` on the host when needed (`personal-kernel-builder diff`).

## Seed configs

| Config | Machine | CPU / platform | Kernel | Boot |
|---|---|---|---|---|
| [`config-thinkpad-e14g2`](seed/config-thinkpad-e14g2) | Lenovo ThinkPad E14 Gen 2 AMD (type 20T6) | AMD Ryzen 5 4500U, Renoir | 7.2 | UEFI, no initrd |

Each config names its machine in its header comment.

### config-thinkpad-e14g2

Reduced from Slackware's generic 7.2 config to the hardware of this laptop: about 440
modules instead of about 3450.

| Component | Hardware | Option |
|---|---|---|
| Graphics | Radeon Vega (Renoir iGPU), HDMI, USB-C DisplayPort | `DRM_AMDGPU=m`, `TYPEC_DP_ALTMODE` |
| Storage | NVMe SSD (Silicon Motion SM2263), XFS root | `BLK_DEV_NVME=y`, `XFS_FS=y` (built in) |
| Wi-Fi / Bluetooth | Realtek RTL8822CE | `RTW88_8822CE=m`, Realtek BT over USB |
| Ethernet | Realtek RTL8111/8168 | `R8169=m` |
| Audio | HDA Realtek ALC257 + HDMI/DP, ACP digital mic | `SND_HDA_CODEC_REALTEK`, `SND_SOC_AMD_RENOIR` |
| Laptop / power | ThinkPad ACPI, battery thresholds, s2idle, amd-pstate | `THINKPAD_ACPI`, `AMD_PMC`, `X86_AMD_PSTATE=y` |
| USB-C | UCSI over ACPI | `TYPEC_UCSI`, `UCSI_ACPI` |

The boot path (EFI stub, NVMe, XFS) is built in, so the kernel boots without an initrd.
Modules must be signed (`MODULE_SIG_FORCE=y`), so out-of-tree modules are not supported.

Install it as the personal config (see the tool's [README](personal-kernel-builder/README.md)):

```
# as root
personal-kernel-builder init --name NAME --builder <user> --config seed/config-thinkpad-e14g2

# as <user>
personal-kernel-builder config olddefconfig
personal-kernel-builder build
```

`config olddefconfig` adapts it to the installed `kernel-source` version, and `build`
replaces its `CONFIG_LOCALVERSION` with `-NAME`.

Settings for this machine in `/etc/personal-kernel-builder/personal-kernel-builder.conf`
(the packaged defaults are generic):

```
CRITICAL_OPTIONS=EFI_STUB=y MODULES=y BLK_DEV_NVME=y XFS_FS=y ACPI=y ACPI_EC=y ACPI_AC ACPI_BATTERY POWER_SUPPLY THINKPAD_ACPI TYPEC_UCSI UCSI_ACPI AMD_PMC PINCTRL_AMD MODULE_SIG
VERIFY_MODULES=thinkpad_acpi ucsi_acpi amd_pmc
VERIFY_BATTERY=yes
```

`amd_pmc` only loads when the BIOS sleep state is "Windows and Linux" (s0ix); with S3,
`verify` skips it.

## Adding a config

1. Start from a config that boots on the machine, and trim or tune it.
2. Save it as `seed/config-<vendor-model>` and name the machine in the header comment:
   ```
   #
   # Machine: <vendor> <model> (type <machine type>, <CPU>)
   # Linux/<arch> <version>
   #
   ```
3. Add a row to the table above and a section with its hardware and the
   `CRITICAL_OPTIONS`/`VERIFY_MODULES` it needs. Do not commit hardware dumps (`dmesg`,
   `lspci -v`, `lsusb -v`): they contain disk UUIDs and device serial numbers.

## Development

```
make check      # bash -n, shellcheck and the tests
make help       # every target
```

`make lint` uses `shellcheck` from `PATH`; without it, `make lint
SHELLCHECK="uvx --from shellcheck-py shellcheck"`. CI runs `make check` on every push.

## License

[MIT](LICENSE)
