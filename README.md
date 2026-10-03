# amber-vte

One VTE 0.84 build shared by the [Amber Linux](https://amberlinux.org) applications,
installed to `/usr/lib/amber-vte` and reached only through those applications' RUNPATH.
It is a runtime bundle, not a development package: applications build against the distro's
`libvte-2.91-gtk4-dev` headers and link the bundle at run time.

## Why it exists

Linux Mint 22 ships VTE 0.76. kat800's terminal needs the termprop API and the UUID
functions that arrived in 0.78, and one downstream fix ([patches/](patches/README.md)). The
build used to live inside kat800; it is its own package so that the bindings
([odin-vte](https://github.com/Hyperquader-Coders/odin-vte)) can test against the real
library, and so a second application could use it without carrying a build.

## Install

From the suite's apt archive:

```sh
sudo curl -fsSL -o /usr/share/keyrings/amberlinux-archive-keyring.gpg \
  https://apt.amberlinux.org/amberlinux-archive-keyring.gpg

echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/amberlinux-archive-keyring.gpg] https://apt.amberlinux.org amber main' \
  | sudo tee /etc/apt/sources.list.d/amberlinux.list

sudo apt update
sudo apt install amber-vte
```

Applications that need it declare `Depends: amber-vte`, so installing one of them installs
this. It depends on [amber-gtk4](https://github.com/Hyperquader-Coders/amber-gtk4).

## What the package contains

| path | what |
|---|---|
| `/usr/lib/amber-vte/libvte-2.91-gtk4.so.0` | the library, stripped |
| `/usr/share/doc/amber-vte/` | copyright and changelog |

No headers, no pkg-config file, no binaries. `/usr/lib/amber-vte` is deliberately not on
the `ldconfig` path: only a binary whose RUNPATH names it picks the bundle up, so installing
it changes nothing for any other program on the system.

## Two properties the build enforces

**It resolves against the distro's stock stack, and amber-gtk4, and nothing else.**
`scripts/check-no-cascade` passes only when every library the bundle needs resolves to a
file some dpkg package owns.

**It carries no path from the machine that built it.** VTE compiles its prefix in, and
`strip` does not touch it. The build is configured with `--prefix=/usr --libdir=lib/amber-vte`
and staged through `DESTDIR`. `scripts/check-no-buildpaths` fails on the builder's home, the
repo, or a staging directory, in the staged tree and again in the package.

## Building

```sh
make deps     # build dependencies and git hooks (sudo apt)
make vte      # fetch, verify, patch and build into build/vte/stage
make ci       # the checks, lint and the .deb
make help     # every target
```

The tarball is checked against the sum GNOME publishes beside it. `make deb` writes
`dist/amber-vte_<version>-<revision>_amd64.deb`; `make deb-path` prints where.

The staged headers in `build/vte/stage/usr/include/vte-2.91-gtk4` are what odin-vte
generates its bindings from.

## Licence

LGPL-3.0-or-later, the licence of VTE. Some VTE files are GPL-3.0-or-later; see
[packaging/debian/copyright](packaging/debian/copyright).
