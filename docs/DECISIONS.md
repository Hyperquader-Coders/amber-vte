# Decisions: amber-vte

What was weighed and settled, with the reasons that make each choice hold. An entry that stops
being true is rewritten, not appended to.

1. **Two packages from one build: amber-vte and amber-vte-dev.** The runtime package holds the
   library a running app loads. The -dev package holds the headers, the unversioned `.so` link
   and the `.pc` file, all under `/usr/lib/amber-vte` (`include/`, `pkgconfig/`), so they never
   meet Mint's `libvte-2.91-gtk4-dev`. The headers ship because the suite's Odin binding,
   odin-vte, is generated from this bundle's 0.84 headers and builds and tests against the
   published archive, as amber-webkit-dev serves odin-webkit. The stage keeps meson's layout,
   the headers in `usr/include`, which odin-vte's generator reads in a checkout beside this
   one; `make deb` copies them under `/usr/lib/amber-vte/include` and rewrites the packaged
   `.pc` file's `includedir` to match, and `scripts/check-pc` checks `libdir` and `includedir`
   in the package. The -dev package depends on amber-vte at its own version, on
   amber-gtk4-dev, since the `.pc` file requires `gtk4` and the suite's GTK is amber-gtk4's,
   and on the -dev packages of glib, pango and cairo, which it requires as well.

2. **Built against amber-gtk4's GTK 4.16 headers, not Mint's 4.14.** VTE's accessible text
   implements `get_extents` and `get_offset`, which tell a screen reader or magnifier where a
   run of text is on screen and which character is at a point, only when `GTK_CHECK_VERSION(4, 15, 1)` holds at compile
   time, and the suite's GTK at run time is amber-gtk4's 4.16. The build takes gtk4 from
   amber-gtk4's stage (`$(AMBER_ROOT)/amber-gtk4/build/gtk/stage`, a sibling in `siblings.txt`)
   through copies of its `.pc` files with the prefix moved to the stage, as amber-webkit does,
   and links the staged `libgtk-4.so`. meson writes VTE's own floor into the `.pc` file,
   `gtk4 >= 4.14.0`; `make deb` rewrites it to `gtk4 >= 4.16.13`, and `scripts/check-pc`
   checks it and resolves it in the stage. The library still imports nothing GTK 4.14 lacks,
   but it is only built and checked against 4.16, which its packages depend on.
