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
/usr/local/bin/personal-kernel-builder
/usr/local/lib/personal-kernel-builder/*.sh
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
installpkg /tmp/personal-kernel-builder-1.10-noarch-1_pkb.txz
personal-kernel-builder init --name volfread --builder <user> --config seed/config-thinkpad-e14g2
personal-kernel-builder adopt 7.3.3-e14g2     # older personal kernel, so uninstall can remove it

# as <user>
personal-kernel-builder config olddefconfig
personal-kernel-builder check
personal-kernel-builder build

# as root, before rebooting (/tmp is wiped)
personal-kernel-builder install

# after rebooting into it
personal-kernel-builder verify
su -c 'personal-kernel-builder uninstall 7.3.3-e14g2'   # once the new one boots fine
```

## Renaming the kernel

Change `NAME=` (or `init --name NEW`), then `build` and `install`: the name is part of
the release string compiled into the kernel and every module. Keep the old kernel until
the new one boots, then `uninstall` it.

## Building the package

```
su -c ./personal-kernel-builder.SlackBuild      # writes /tmp/personal-kernel-builder-1.10-noarch-1_pkb.txz
```

## Tests

```
tests/unit.sh
tests/completion.sh     # bash completion
```

## Shell completion

The package installs completion for bash (`/usr/share/bash-completion/completions/`) and
zsh (`/usr/share/zsh/site-functions/_personal-kernel-builder`). In zsh it needs
`compinit` in `~/.zshrc`; after installing, open a new shell or run `rm -f ~/.zcompdump*;
compinit`.
