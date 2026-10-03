# patches

Downstream fixes applied to the VTE tarball before `meson setup`. `make vte` applies every
`*.patch` here with `patch -p1 -N` and stops the build if one fails, so a patch that no
longer applies to a new VTE is a build error rather than a bundle that silently ships
upstream's behaviour.

Each patch must carry, in its own header, what it fixes and how that was measured. Delete a
patch once upstream VTE has fixed what it works around.

## 0001: selection survives unrelated child output

VTE pauses PTY reads in `start_selection()`, but `Terminal::process()` re-arms them on every
tick, and its "deselect if the text under the selection changed" check compares against the
PRIMARY snapshot, which mid-drag is the previous selection. Under a program that redraws
continuously, every mouse selection is cancelled before release and nothing is copied.

Upstream: <https://gitlab.gnome.org/GNOME/vte/-/issues/2726> and
<https://gitlab.gnome.org/GNOME/vte/-/issues/2960>.
