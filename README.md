# amber-vte

One VTE 0.84 build shared by the [Amber Linux](https://amberlinux.org) applications,
installed to `/usr/lib/amber-vte` and reached only through those applications' RUNPATH.
amber-vte-dev carries its headers and pkg-config file, which
[odin-vte](https://github.com/Hyperquader-Coders/odin-vte) is generated from and builds against.

## Why it exists

Linux Mint 22 ships VTE 0.76. kat800's terminal needs the termprop API and the UUID
functions that arrived in 0.78, and one downstream fix ([patches/](patches/README.md)). The
build is its own package, not part of kat800, so that the bindings
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

## What the packages contain

**amber-vte**, the runtime:

| path | what |
|---|---|
| `/usr/lib/amber-vte/libvte-2.91-gtk4.so.0` | the library, stripped |
| `/usr/share/doc/amber-vte/` | copyright and changelog |

**amber-vte-dev**, for building against the bundle:

| path | what |
|---|---|
| `/usr/lib/amber-vte/include/vte-2.91-gtk4/` | the VTE headers |
| `/usr/lib/amber-vte/pkgconfig/vte-2.91-gtk4.pc` | the pkg-config file |
| `/usr/lib/amber-vte/libvte-2.91-gtk4.so` | the link a linker looks for |

It depends on amber-vte at the same version, on amber-gtk4-dev (the `.pc` file requires
`gtk4`), and on the -dev packages of glib, pango and cairo, which it requires as well.

No binaries. `/usr/lib/amber-vte` is deliberately not on the `ldconfig` path: only a binary
whose RUNPATH names it picks the bundle up, so installing it changes nothing for any other
program on the system. The headers and `.pc` file sit there too, so they never meet Mint's
`libvte-2.91-gtk4-dev`.

## Consuming it

Build against amber-vte-dev and amber-gtk4-dev, and point the release RUNPATH at both bundles:

```sh
export PKG_CONFIG_PATH=/usr/lib/amber-vte/pkgconfig:/usr/lib/amber-gtk4/pkgconfig
cc app.c $(pkg-config --cflags --libs vte-2.91-gtk4) \
  -Wl,--enable-new-dtags,-rpath,/usr/lib/amber-vte:/usr/lib/amber-gtk4
```

## Two properties the build enforces

**It resolves against the distro's stock stack, and amber-gtk4, and nothing else.**
`scripts/check-no-cascade` passes only when every library the bundle needs resolves to a
file some dpkg package owns.

**It carries no path from the machine that built it.** VTE compiles its prefix in, and
`strip` does not touch it. The build is configured with `--prefix=/usr --libdir=lib/amber-vte`
and staged through `DESTDIR`. `scripts/check-no-buildpaths` fails on the builder's home, the
repo, or a staging directory, in the staged tree and again in both packages.

`scripts/check-pc` asserts, in the packaged tree, that the `.pc` file's `libdir` and
`includedir` are inside the bundle.

## Building

Requires Linux Mint 22 or Ubuntu 24.04, and amber-gtk4 built beside this checkout: VTE
compiles against amber-gtk4's staged GTK 4.16 headers. `siblings.txt` names the repositories
this one needs beside it, one a line with the root variable whose folder it goes in
(`AMBER_ROOT,https://github.com/Hyperquader-Coders/amber-gtk4`); `make setup`, or
`make init-siblings`, clones the missing ones there and leaves a checkout already there as it is.

```sh
make setup    # a fresh clone: the siblings, the system packages (sudo apt) and the git hooks
make -C "$AMBER_ROOT/amber-gtk4" build  # once: the GTK 4.16 stage VTE compiles against
make vte      # fetch, verify, patch and build into build/vte/stage
make lint     # shfmt, shellcheck, the agent-file guard and the source checks, with no build
make ci       # check, lint, the .debs and lintian on both; builds the bundle first when it is missing
make help     # every target
```

The tarball is checked against the sum GNOME publishes beside it. `make deb` writes
`dist/amber-vte_<version>-<revision>_amd64.deb` and `dist/amber-vte-dev_…`, again only when the
checked bundle or a packaging file changed; `make deb-path` prints where, one a line.
`make check-lintian` runs lintian over both.

The staged headers in `build/vte/stage/usr/include/vte-2.91-gtk4` are what odin-vte
generates its bindings from in a checkout beside this one.

## Licence

LGPL-3.0-or-later, the licence of VTE. Some VTE files are GPL-3.0-or-later; see
[packaging/debian/copyright](packaging/debian/copyright).
