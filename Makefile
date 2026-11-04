# amber-vte: one VTE build for the whole amber suite, against amber-gtk4's GTK 4.16, packaged to
# /usr/lib/amber-vte, where the apps' RUNPATH points. What every bundle does is in
# house/bundle.mk, a copy of house-rules' scripts/binding/bundle.mk: this repository is public,
# and its runner has no house-rules. project.toml names the release, its options, the siblings
# and the system packages; README.md says why the bundle exists and docs/DECISIONS.md the
# choices below.
include house/bundle.mk

.PHONY: gtk-pc hooks

# The GTK side. VTE compiles against amber-gtk4's staged 4.16 headers, not Mint's 4.14: its
# accessible text implements the extents and offset calls only when GTK_CHECK_VERSION(4, 15, 1)
# holds at compile time (docs/DECISIONS.md, 2). At run time the library's RUNPATH reaches the
# amber-gtk4 bundle, and the -dev package's .pc file requires that GTK, at the floor
# scripts/after-stage writes and scripts/check-pc checks.
GTK_BUNDLE_DIR = /usr/lib/amber-gtk4
export GTK_BUNDLE_MIN = 4.16.13
# amber-gtk4's checkout is $(AMBER_ROOT)/amber-gtk4, or AMBER_GTK4_DIR where that is set (a
# worktree, in the gitignored local.mk).
GTK_STAGE ?= $(or $(AMBER_GTK4_DIR),$(AMBER_ROOT)/amber-gtk4)/build/stage
GTK_STAGE_PC = $(GTK_STAGE)$(GTK_BUNDLE_DIR)/pkgconfig
GTK_PC = build/gtk-pc

# amber-gtk4's .pc files name prefix=/usr, where the package installs; for the build they are
# copied with the prefix moved to its stage, so pkg-config hands meson the 4.16 headers and the
# staged libgtk-4.so to link. Only the prefix line changes.
gtk-pc:
	@[ -n '$(AMBER_ROOT)' ] || { echo '$@: AMBER_ROOT is not set: it names the folder holding amber-gtk4'; exit 2; }
	@[ -e '$(GTK_STAGE_PC)/gtk4.pc' ] || { echo '$@: $(GTK_STAGE_PC)/gtk4.pc not found: build amber-gtk4 first (make -C $(or $(AMBER_GTK4_DIR),$(AMBER_ROOT)/amber-gtk4) build; make init-siblings clones it)'; exit 2; }
	@rm -rf $(GTK_PC) && mkdir -p $(GTK_PC)
	@for f in $(GTK_STAGE_PC)/*.pc; do \
		sed 's|^prefix=/usr$$|prefix=$(GTK_STAGE)/usr|' "$$f" > $(GTK_PC)/$${f##*/}; \
	done
	@v=$$(PKG_CONFIG_PATH=$(CURDIR)/$(GTK_PC) pkg-config --modversion gtk4); \
	[ "$$v" = "$(GTK_BUNDLE_MIN)" ] || { echo "$@: amber-gtk4's stage is GTK $$v, this build expects $(GTK_BUNDLE_MIN)"; exit 1; }

# gcc-14, as VTE 0.84 is C++20; gtk4 from amber-gtk4's stage through gtk-pc's copies, order-only
# so that writing them again never configures the build again.
#
# LIBRARY_PATH names the stage's library folder to gcc, which lists it among its own; meson then
# takes it for a system folder and leaves it out of the build RUNPATH. Otherwise meson would
# build with the stage in the RUNPATH and, on install, end the string after /usr/lib/amber-gtk4,
# leaving the stage's path in .dynstr (check-no-buildpaths fails on it).
$(OBJ)/build.ninja: | gtk-pc
$(OBJ)/build.ninja: export CC = gcc-14
$(OBJ)/build.ninja: export CXX = g++-14
$(OBJ)/build.ninja: export PKG_CONFIG_PATH = $(CURDIR)/$(GTK_PC)
$(OBJ)/build.ninja: export LIBRARY_PATH = $(GTK_STAGE)$(GTK_BUNDLE_DIR)

# check-pc resolves the .pc file's gtk4 in amber-gtk4's stage, the GTK the library is built
# against.
check deb: export PKG_CONFIG_PATH = $(GTK_STAGE_PC)

# A shipped hook does nothing until core.hooksPath points at it.
init-workstation: hooks
hooks: ## point core.hooksPath at .githooks
	@git config core.hooksPath .githooks && echo "hooks: core.hooksPath -> .githooks"
