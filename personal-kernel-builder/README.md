# personal-kernel-builder

Builds a personal kernel from Slackware's `kernel-source` (`/usr/src/linux`) with a
config kept in `/etc/personal-kernel-builder`, and installs it as GRUB's default entry.

- `config`, `build`, `diff`, `check`, `verify` and `status` run without root, as the
  user named in `BUILDER=` (who owns `personal.config` and its backups; no extra group).
  Builds happen in a private copy of the sources under
  `/tmp/personal-kernel-builder-<user>`, which a reboot wipes.
- `init`, `install`, `uninstall` and `adopt` need root. `install` only copies the
  staged build (root never runs `make` on a user's tree) and sets `GRUB_TOP_LEVEL`.
- Modules are signed with a key the kernel generates for each build; `build` deletes the
  private key once the modules are signed, so nothing else can be signed for that kernel
  (with `MODULE_SIG_FORCE` it loads only the modules built with it). Out-of-tree modules
  are therefore not supported.

## Layout

```
/usr/bin/personal-kernel-builder
/usr/share/personal-kernel-builder/*.sh
/etc/personal-kernel-builder/
  personal-kernel-builder.conf   settings (NAME=, JOBS=, ...)
  default.config                 copy of the config /boot/config points to
  default.origin                 which file that was
  personal.config                the config that gets built (BUILDER, 0644)
  backups/personal-<date>.config dated backups (KEEP_BACKUPS, default 7; BUILDER's directory,
                                 so root writes there only as BUILDER)
/var/lib/personal-kernel-builder/installed/<release>.info   kernels uninstall may remove
/var/log/personal-kernel-builder/                           root runs and build logs
```

## First setup

```
# as root
installpkg /tmp/personal-kernel-builder-<version>-noarch-1_pkb.txz
personal-kernel-builder init --name NAME --builder <user> --config seed/<config>
personal-kernel-builder adopt <release>     # an older personal kernel, so uninstall can remove it

# as <user>
personal-kernel-builder config olddefconfig
personal-kernel-builder check
personal-kernel-builder build

# as root, before rebooting (/tmp is wiped)
personal-kernel-builder install

# after rebooting into it
personal-kernel-builder verify
su -c 'personal-kernel-builder uninstall <old release>'   # once the new one boots fine
```

The packaged `personal-kernel-builder.conf` only requires `EFI_STUB=y MODULES=y MODULE_SIG`.
Add what your machine cannot boot without to `CRITICAL_OPTIONS`, and the modules `verify`
should find to `VERIFY_MODULES`: the repository README lists both for each seed config.

## Booting without initrd

With `USE_INITRD=no` (the default) the drivers of the root disk and filesystem must be
built in: list them as `NAME=y` in `CRITICAL_OPTIONS` (`BLK_DEV_NVME=y XFS_FS=y`, say), and
set `GRUB_DISABLE_LINUX_UUID=true` (`install --fix-grub-uuid` does it). With `--initrd`,
`install` runs `mkinitrd` for the filesystem type of `/`, still without a module list.

## Rebuilding the running release

Rebuilding the same sources with the same `NAME` gives the release that is running.
`install` refuses to replace it: every build signs its modules with a new key, so the
running kernel could not load any module until the reboot. Boot another kernel first
(Slackware's stays in GRUB), or pass `--force` and reboot right after `install`.

## Renaming the kernel

Change `NAME=` (or `init --name NEW`), then `build` and `install`: the name is part of
the release string compiled into the kernel and every module. Keep the old kernel until
the new one boots, then `uninstall` it.

## Building the package

From the repository root (the version is `VERSION` in the SlackBuild):

```
su -c 'make package'      # writes /tmp/personal-kernel-builder-<version>-noarch-1_pkb.txz
```

Since 1.11 the package installs into `/usr/bin` and `/usr/share/personal-kernel-builder`
instead of `/usr/local`; `upgradepkg` removes the old files.

## Tests

From the repository root:

```
make check      # bash -n, shellcheck, unit and completion tests (make help lists the rest)
```

## Shell completion

The package installs completion for bash (`/usr/share/bash-completion/completions/`) and
zsh (`/usr/share/zsh/site-functions/_personal-kernel-builder`). In zsh it needs
`compinit` in `~/.zshrc`; after installing, open a new shell or run `rm -f ~/.zcompdump*;
compinit`.
