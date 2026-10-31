# amber-vte: one VTE build for the whole amber suite.
#
# `make vte` builds it against amber-gtk4's GTK 4.16, `make deb` packages it to
# /usr/lib/amber-vte, and the apps point their RUNPATH there. See README.md for why it exists
# at all and docs/DECISIONS.md for the choices below.
# check-packaging: upstream (VTE 0.84.1, rebuilt for the suite)
VERSION = 0.84.1
# The package revision, bumped when the packaging changes but the VTE version does not.
REVISION = 1
DEB = dist/amber-vte_$(VERSION)-$(REVISION)_amd64.deb
DEV_DEB = dist/amber-vte-dev_$(VERSION)-$(REVISION)_amd64.deb
DEBS = $(DEB) $(DEV_DEB)
BRANCH ?= main
REMOTE ?= origin
ROOT_COMMIT_MSG ?= Initial amber-vte
# The siblings are found through the roots' variables, which mise sets on a development
# machine. AMBER_ROOT is the Amber tree, holding amber-gtk4 (siblings.txt). HOUSE_ROOT is the
# folder holding house-rules, whose check-narration and check-example-hosts `check-sources`
# runs where it is there; house-rules is private, so it is not in siblings.txt, and a clone
# outside the house and the public runner go without those two checks, saying so.
HOUSE_SCRIPTS = $(HOUSE_ROOT)/house-rules/scripts

# $(call require,VARIABLE,path,sibling,what to do): fail, naming the variable, when it is unset
# or the sibling's file is not there.
require = @test -n '$($(1))' || { \
	    echo '$@: $(1) is not set: it names the folder holding $(3) (mise sets it on a development machine)'; \
	    exit 2; }; \
	test -e '$(2)' || { \
	    echo '$@: $(2) not found ($(1)=$($(1))): $(4)'; \
	    exit 2; }

# targets: no test (upstream VTE, built with its tests off; check asserts the bundle's two shipping properties)

# Where the build lands, and where the deb installs it. Apps hardcode INSTALL_DIR in
# their release RUNPATH, so it is part of the contract with them.
#
# Configured with /usr and staged through DESTDIR: VTE compiles its prefix into the
# shipped .so, so a build-tree prefix would ship the builder's home directory.
# libdir=lib/amber-vte lands the library where INSTALL_DIR expects it. `make check`
# asserts it.
INSTALL_DIR = /usr/lib/amber-vte
CONF_PREFIX = /usr
CONF_LIBDIR = lib/amber-vte
STAGE = build/vte/stage
BUNDLE = $(STAGE)$(INSTALL_DIR)
# Written when make check passes against the staged bundle.
CHECKED = build/checked
# The GTK side. VTE compiles against amber-gtk4's staged 4.16 headers, not Mint's 4.14: its
# accessible text implements the extents and offset calls only when GTK_CHECK_VERSION(4, 15, 1)
# holds at compile time (docs/DECISIONS.md, 2). At run time the library's RUNPATH reaches the
# amber-gtk4 bundle, and the -dev package's .pc file requires that GTK.
GTK_BUNDLE_DIR = /usr/lib/amber-gtk4
GTK_BUNDLE_MIN = 4.16.13
GTK_STAGE ?= $(AMBER_ROOT)/amber-gtk4/build/gtk/stage
GTK_PC = build/gtk-pc
# The release tarball, verified against the sum GNOME publishes beside it
# (download.gnome.org/sources/vte/<major.minor>/vte-<version>.sha256sum). A fetched
# archive that does not match is deleted, so a wrong VERSION bump fails here and not
# after the build. Lives under build/, not /tmp: /tmp is shared and predictable.
TARBALL = build/vte-$(VERSION).tar.xz
TARBALL_SHA256 = aca1caa8478aebcdbb1d67897fb3511eb7601debae6810e16a15b6fa25f31ac8
TARBALL_URL = https://download.gnome.org/sources/vte/$(basename $(VERSION))/vte-$(VERSION).tar.xz

.PHONY: help setup init-packages init-modules init-workstation vte build built gtk-pc stage check ci deb deb-path deb-install deb-remove clean push force-push lint check-sources check-lintian hooks check-no-agent-files

# A target whose recipe fails or is interrupted is removed, so it is never taken as made.
.DELETE_ON_ERROR:

# The system packages a build and the checks need, in one list: a development machine and the
# CI install the same, the CI with `make init-packages APT_FLAGS=-y`. A package missing on the
# runner is added here, and a workflow names none.
# libgtk-4-1 is the stock GTK that check-no-cascade resolves libvte against where amber-gtk4 is
# not installed; at run time the amber-gtk4 RUNPATH reaches the bundle's 4.16 first. From sassc
# on, the list is what amber-gtk4's build of GTK needs, which CI runs as a sibling.
# curl fetches VTE's source tarball.
DEPS := meson ninja-build gperf g++-14 curl shellcheck shfmt dpkg-dev binutils lintian \
	libgtk-4-1 libglib2.0-dev liblz4-dev libsystemd-dev libdrm-dev \
	libgnutls28-dev libicu-dev libpcre2-dev libfribidi-dev \
	sassc libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev libgraphene-1.0-dev libepoxy-dev \
	libxkbcommon-dev libwayland-dev libx11-dev libxi-dev libxcursor-dev libxdamage-dev \
	libxinerama-dev libxrandr-dev libxext-dev libxfixes-dev libcairo-script-interpreter2 \
	libjpeg-dev libtiff-dev libharfbuzz-dev
APT_FLAGS ?=

init-packages: ## install the system packages a build and the checks need (sudo apt)
	sudo apt-get install $(APT_FLAGS) --no-install-recommends $(DEPS)

# No language packages: VTE is C and C++, built from its release tarball. `ci` depends on it all
# the same, as in every repository.
init-modules: ## install the language packages from the lock: none here

init-workstation: hooks ## set up a desk: the git hooks

help: ## this list
	@awk 'BEGIN {FS = ":.*## "} \
	    /^##@ / {printf "\n%s\n", substr($$0, 5)} \
	    /^[a-z][a-z0-9-]*:.*## / {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

$(TARBALL):
	@echo "fetching vte $(VERSION)"
	mkdir -p build
	curl -fL -o $(TARBALL).part $(TARBALL_URL)
	@echo "$(TARBALL_SHA256)  $(TARBALL).part" | sha256sum -c - || { rm -f $(TARBALL).part; exit 1; }
	mv $(TARBALL).part $(TARBALL)

# amber-gtk4's .pc files name prefix=/usr, where the package installs; for the build they are
# copied with the prefix moved to its stage, so pkg-config hands meson the 4.16 headers and
# the staged libgtk-4.so to link. Only the prefix line changes.
gtk-pc:
	$(call require,AMBER_ROOT,$(GTK_STAGE)/usr/lib/amber-gtk4/pkgconfig/gtk4.pc,amber-gtk4,build amber-gtk4 first (make -C $(AMBER_ROOT)/amber-gtk4 build; make init-siblings clones it))
	@rm -rf $(GTK_PC) && mkdir -p $(GTK_PC)
	@for f in $(GTK_STAGE)/usr/lib/amber-gtk4/pkgconfig/*.pc; do \
		sed 's|^prefix=/usr$$|prefix=$(GTK_STAGE)/usr|' "$$f" > $(GTK_PC)/$${f##*/}; \
	done
	@v=$$(PKG_CONFIG_PATH=$(CURDIR)/$(GTK_PC) pkg-config --modversion gtk4); \
	[ "$$v" = "$(GTK_BUNDLE_MIN)" ] || { echo "gtk-pc: amber-gtk4's stage is GTK $$v, this build expects $(GTK_BUNDLE_MIN)"; exit 1; }

# Build VTE $(VERSION) (gtk4) for bundling. Mint ships 0.76; the termprop API and the
# UUID functions the apps use are only in 0.78 and later.
#
# gcc-14 because VTE 0.84 is C++20. meson finds gtk4 in amber-gtk4's stage through
# PKG_CONFIG_PATH (gtk-pc). The linker is given the amber-gtk4 RUNPATH, so the library finds
# the bundled GTK without the application's help.
#
# LIBRARY_PATH names the stage's library folder to gcc, which lists it among its own; meson
# then takes it for a system folder and leaves it out of the build RUNPATH. Otherwise meson
# would build with the stage in the RUNPATH and, on install, end the string after
# /usr/lib/amber-gtk4, leaving the stage's path in .dynstr (check-no-buildpaths fails on it).
vte: $(TARBALL) gtk-pc ## fetch, patch and build VTE against amber-gtk4's GTK 4.16 into build/vte/stage
	rm -rf build/vte
	mkdir -p build/vte
	tar xf $(TARBALL) -C build/vte --strip-components=1
	# patches/ carries the downstream fixes. The extract above is unconditional, so a
	# patch that stops applying is a hard failure here rather than a bundle that quietly
	# ships upstream's behaviour: -N makes reapplication a no-op, not an error, and the
	# exit status is checked. See patches/README.md for what each one is for.
	@for p in patches/*.patch; do \
		test -e "$$p" || continue; \
		echo "applying $$p"; \
		patch -p1 -N -d build/vte --no-backup-if-mismatch --input="$(CURDIR)/$$p" || exit 1; \
	done
	CC=gcc-14 CXX=g++-14 PKG_CONFIG_PATH=$(CURDIR)/$(GTK_PC) LIBRARY_PATH=$(GTK_STAGE)$(GTK_BUNDLE_DIR) \
		meson setup build/vte/_build build/vte --prefix=$(CONF_PREFIX) \
		--libdir=$(CONF_LIBDIR) -Dgtk3=false -Dgtk4=true -Dvapi=false -Dgir=false \
		-Ddocs=false -Dglade=false -Dapp=false \
		-Dc_link_args=-Wl,-rpath,$(GTK_BUNDLE_DIR) \
		-Dcpp_link_args=-Wl,-rpath,$(GTK_BUNDLE_DIR)
	DESTDIR=$$(pwd)/$(STAGE) ninja -C build/vte/_build install
	# Strip in place, so `make check` sees exactly what `make deb` will ship.
	find $(BUNDLE) -type f -name '*.so*' -exec strip --strip-unneeded {} +

# The standard name for the build; the one build there is.
build: vte ## the same as vte

# The checks need the bundle, so a checkout without one builds it here (`make vte`).
built: stage
	@test -e $(BUNDLE)/libvte-2.91-gtk4.so.0 || $(MAKE) vte

# Re-stage whenever the meson build tree is newer than the staged bundle.
#
# `deb` packages $(BUNDLE), which only `ninja install` writes. Building the library on its
# own updates the build tree and leaves the stage untouched, so without this the deb ships
# the previous library without any error. ninja install is a no-op when the tree is
# already staged.
stage:
	@test -d build/vte/_build || exit 0; \
	built=build/vte/_build/src/libvte-2.91-gtk4.so.0; \
	staged=$(BUNDLE)/libvte-2.91-gtk4.so.0; \
	if [ -e "$$built" ] && { [ ! -e "$$staged" ] || [ "$$built" -nt "$$staged" ]; }; then \
		echo "re-staging: $$built is newer than the staged bundle"; \
		DESTDIR=$$(pwd)/$(STAGE) ninja -C build/vte/_build install >/dev/null || exit 1; \
		find $(BUNDLE) -type f -name '*.so*' -exec strip --strip-unneeded {} + ; \
	fi

# Two properties make this bundle safe to ship, and the scripts below enforce both:
#   1. it resolves against the distro's stock stack and amber-gtk4, and pulls nothing else in
#   2. it carries no path from the machine that built it
# The checks pass once per staged bundle: CHECKED is newer than the library and the scripts
# only after both pass, so check, deb and deb-install skip them until either changes.
check: built $(CHECKED) ## the bundle pulls in no newer stack and carries no build paths

$(CHECKED): $(BUNDLE)/libvte-2.91-gtk4.so.0 scripts/check-no-cascade scripts/check-no-buildpaths
	@scripts/check-no-cascade $(BUNDLE)/libvte-2.91-gtk4.so.0
	@scripts/check-no-buildpaths $(BUNDLE)
	@touch $@

# `built` makes the bundle before anything that names it is looked at; this rule is reached only
# when the stamp is asked for on its own.
$(BUNDLE)/libvte-2.91-gtk4.so.0:
	@echo "$@ is not there: make vte first"; exit 2

# What a push must pass. Unlike amber-webkit's, it builds: a VTE build is a few minutes, and CI
# keeps the staged bundle in its cache, so the runner checks and packages the bundle and runs
# lintian over both packages.
ci: init-modules check lint check-lintian ## everything a push must pass: check, lint, and lintian on both packages
	@echo "CI OK: the bundle resolves against the stock stack, carries no build paths, and packages; sources and packaging metadata check out"

# The checks that need no build: the shell scripts, the docs, the packaging metadata.
check-sources: ## shellcheck, the changelog and control templates, and house-rules' narration and example-host checks where it is there
	@if [ -n "$(HOUSE_ROOT)" ] && [ -x "$(HOUSE_SCRIPTS)/check-narration" ]; then \
		"$(HOUSE_SCRIPTS)/check-narration" && "$(HOUSE_SCRIPTS)/check-example-hosts" "$(CURDIR)" || exit 1; \
	else echo "house-rules not found (HOUSE_ROOT=$(HOUSE_ROOT)): check-narration and check-example-hosts skipped; house-rules is private"; fi
	@git ls-files | while read -r f; do \
		case "$$f" in *.sh|*.bash) echo "$$f";; \
		*) head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh' && echo "$$f";; esac; \
	done | xargs -r shellcheck --severity=warning && echo "shellcheck OK"
	@dpkg-parsechangelog -l packaging/debian/changelog -S Version | grep -qx '$(VERSION)-$(REVISION)' || \
		{ echo "packaging/debian/changelog is not at $(VERSION)-$(REVISION)"; exit 1; }
	@test "$$(dpkg-parsechangelog -l packaging/debian/changelog -S Changes | grep -c '^  \*')" = 1 || \
		{ echo "packaging/debian/changelog has more than its one entry"; exit 1; }
	@for c in packaging/control.in packaging/control-dev.in; do \
		grep -q '^Package: ' $$c && grep -q '^Version: @VERSION@$$' $$c || { echo "$$c: no Package or Version line"; exit 1; }; \
	done
	@echo "check-sources OK"

# Two binary packages from the one build.
#   amber-vte: the shared object under /usr/lib/amber-vte; no binaries.
#   amber-vte-dev: the headers, the unversioned .so link and the .pc file, all under
#     /usr/lib/amber-vte, so they never meet the distro's libvte-2.91-gtk4-dev; odin-vte is
#     generated from these headers.
# The stage keeps meson's layout (headers in usr/include), which odin-vte reads; the headers
# move under /usr/lib/amber-vte in the -dev package, and its .pc file's includedir with them
# (scripts/check-pc checks it in the package).
DEBROOT = build/deb/amber-vte
DEVROOT = build/deb/amber-vte-dev
deb: built $(DEBS) ## package the bundle into dist/: amber-vte and amber-vte-dev

# Both packages come from one staging, so one rule makes them together, and only when the
# checked bundle or what goes into a package changed: an up-to-date pair is installed or
# ingested as it is. `built` runs first and re-stages a rebuilt library, so the bundle's time is
# the staged one. A recipe that fails or is interrupted deletes them (.DELETE_ON_ERROR), so a
# half-written package never counts as made.
$(DEBS) &: $(CHECKED) packaging/control.in packaging/control-dev.in packaging/debian/copyright packaging/debian/changelog $(wildcard packaging/lintian-overrides/*) scripts/check-no-buildpaths scripts/check-pc Makefile
	rm -rf build/deb build/shlibwork
	install -d $(DEBROOT)$(INSTALL_DIR) $(DEVROOT)$(INSTALL_DIR)
	# The real file; the unversioned link belongs to -dev.
	install -D -m644 $(BUNDLE)/libvte-2.91-gtk4.so.0 $(DEBROOT)$(INSTALL_DIR)/libvte-2.91-gtk4.so.0
	cp -a $(BUNDLE)/libvte-2.91-gtk4.so $(BUNDLE)/pkgconfig $(DEVROOT)$(INSTALL_DIR)/
	cp -a $(STAGE)/usr/include $(DEVROOT)$(INSTALL_DIR)/
	sed -i 's|^includedir=.*|includedir=$${prefix}/lib/amber-vte/include|' $(DEVROOT)$(INSTALL_DIR)/pkgconfig/*.pc
	# meson writes the gtk4 floor VTE's own meson.build asks for, 4.14; the library is
	# compiled against 4.16, so the packaged .pc file requires amber-gtk4's.
	sed -i -E 's/(^Requires:.*\bgtk4) >= [0-9.]+/\1 >= $(GTK_BUNDLE_MIN)/' $(DEVROOT)$(INSTALL_DIR)/pkgconfig/*.pc
	# Assert on what is actually packaged, both packages, the object and the text beside it,
	# not only on what was staged: `make deb` must not be a way around `make check`.
	@scripts/check-no-buildpaths build/deb
	# The .pc file requires gtk4, which amber-vte-dev takes from amber-gtk4-dev: check-pc
	# resolves it in amber-gtk4's stage and fails on a floor other than $(GTK_BUNDLE_MIN).
	$(call require,AMBER_ROOT,$(GTK_STAGE)$(GTK_BUNDLE_DIR)/pkgconfig/gtk4.pc,amber-gtk4,build amber-gtk4 first (make -C $(AMBER_ROOT)/amber-gtk4 build; make init-siblings clones it))
	@PKG_CONFIG_PATH=$(GTK_STAGE)$(GTK_BUNDLE_DIR)/pkgconfig scripts/check-pc $(DEVROOT)$(INSTALL_DIR)/pkgconfig $(INSTALL_DIR) $(GTK_BUNDLE_MIN)
	@set -e; for p in amber-vte amber-vte-dev; do \
		root=build/deb/$$p; \
		install -D -m644 packaging/lintian-overrides/$$p $$root/usr/share/lintian/overrides/$$p; \
		install -D -m644 packaging/debian/copyright $$root/usr/share/doc/$$p/copyright; \
		gzip -9n < packaging/debian/changelog > $$root/usr/share/doc/$$p/changelog.Debian.gz; \
		chmod 644 $$root/usr/share/doc/$$p/changelog.Debian.gz; \
		find $$root -type d -exec chmod 755 {} +; \
		mkdir -p $$root/DEBIAN; \
		(cd $$root && find . -type f -not -path './DEBIAN/*' -printf '%P\n' | sort | xargs md5sum > DEBIAN/md5sums); \
	done
	# The bundle is deliberately NOT on the ldconfig path: only a binary whose RUNPATH
	# names $(INSTALL_DIR) picks it up, so installing this cannot change what any other
	# program on the system links against. No shlibs file either, for the same reason.
	mkdir -p build/shlibwork/debian
	printf 'Source: amber-vte\n\nPackage: amber-vte\nArchitecture: amd64\n' > build/shlibwork/debian/control
	# --ignore-missing-info: amber-gtk4 ships no shlibs file by design; control.in names
	# that dependency explicitly. shlibdeps resolves libgtk-4.so.1 to the archive's
	# libgtk-4-1, which is never loaded when the RUNPATH reaches amber-gtk4 first, so that
	# claim is dropped: the GTK dependency is amber-gtk4 and nothing else.
	cd build/shlibwork && dpkg-shlibdeps -O --ignore-missing-info \
		../../$(DEBROOT)$(INSTALL_DIR)/libvte-2.91-gtk4.so.0 > deps.txt
	sed -e 's/@VERSION@/$(VERSION)-$(REVISION)/' \
		-e 's/@GTK_MIN@/$(GTK_BUNDLE_MIN)/' \
		-e "s/@SIZE@/$$(du -sk $(DEBROOT) --exclude=DEBIAN | cut -f1)/" \
		-e "s|@DEPS@|$$(sed -e 's/^shlibs:Depends=//' -e 's/libgtk-4-1 ([^)]*)\(, \)\?//' build/shlibwork/deps.txt)|" \
		packaging/control.in > $(DEBROOT)/DEBIAN/control
	sed -e 's/@VERSION@/$(VERSION)-$(REVISION)/' \
		-e 's/@GTK_MIN@/$(GTK_BUNDLE_MIN)/' \
		-e "s/@SIZE@/$$(du -sk $(DEVROOT) --exclude=DEBIAN | cut -f1)/" \
		packaging/control-dev.in > $(DEVROOT)/DEBIAN/control
	mkdir -p dist
	dpkg-deb --build --root-owner-group $(DEBROOT) $(DEB)
	dpkg-deb --build --root-owner-group $(DEVROOT) $(DEV_DEB)

# Where `make deb` puts the packages: one absolute path a line, nothing else.
# amberlinux-apt ingests them through this.
deb-path: ## print the absolute paths of the two .debs, one a line
	@for d in $(DEBS); do echo "$(CURDIR)/$$d"; done

deb-install: deb ## install both .debs, packaging them first if the bundle changed (sudo)
	# --allow-downgrades: once the packages are published, the archive carries the same
	# version at a higher pin priority than a local file, so apt reads installing your own
	# build as a downgrade and refuses.
	sudo apt install --reinstall --allow-downgrades $(patsubst %,./%,$(DEBS))

deb-remove: ## remove the installed packages (sudo)
	sudo apt remove amber-vte-dev amber-vte

# build/ holds the VTE build as well: after a clean, `make vte` compiles everything again.
clean: ## remove build/ and dist/, the VTE build included
	rm -rf build dist

push: ## git push to REMOTE BRANCH (origin main)
	git push "$(REMOTE)" "$(BRANCH)"

# Agent files are never published. Two ways they get in: already tracked, or
# present-and-unignored when `git add -A` below sweeps the whole tree. Both are
# checked here, because a squashed history shows no file being added: a stray
# path appears in the root commit like any other file.
check-no-agent-files: ## refuse agent files that are tracked or not ignored
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/|\.codex/|AGENTS\.md|CLAUDE\.md)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber .codex AGENTS.md CLAUDE.md; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored: 'git add -A' would publish it"; \
			echo "fix: add $$p to .gitignore"; \
			exit 2; \
		fi; \
	done
	@echo "no agent files staged for publication"

force-push: check check-no-agent-files ## squash history into one signed root commit and force-push
	@test -z "$$(git status --porcelain)" || { \
		echo "Working tree is dirty. Commit, stash, or revert changes first."; \
		exit 2; \
	}
	@set -e; \
	orig_branch="$$(git branch --show-current)"; \
	test -n "$$orig_branch" || { echo "force-push: detached HEAD, check out a branch first"; exit 1; }; \
	tmp_branch="root-squash-$$(date +%s)"; \
	step="starting"; ok=0; \
	trap 'if [ "$$ok" != 1 ]; then echo "force-push FAILED while: $$step. Local history is intact on $$orig_branch; $(REMOTE)/$(BRANCH) was not replaced." >&2; git checkout -f "$$orig_branch" >/dev/null 2>&1 || true; git branch -D "$$tmp_branch" >/dev/null 2>&1 || true; exit 1; fi' EXIT; \
	step="creating the orphan branch"; git checkout --orphan "$$tmp_branch"; \
	step="staging the tree"; git add -A; \
	step="signing the root commit"; git commit -S -m "$(ROOT_COMMIT_MSG)"; \
	step="pushing to $(REMOTE)/$(BRANCH) (refused or unreachable)"; git push --force "$(REMOTE)" "$$tmp_branch:$(BRANCH)"; \
	step="verifying $(REMOTE)/$(BRANCH) equals the new commit"; \
	remote_sha="$$(git ls-remote "$(REMOTE)" "refs/heads/$(BRANCH)" | cut -f1)"; \
	test -n "$$remote_sha" && test "$$remote_sha" = "$$(git rev-parse HEAD)"; \
	ok=1; \
	other_wt="$$(git worktree list --porcelain | awk -v b="branch refs/heads/$(BRANCH)" '/^worktree /{w=substr($$0, 10)} $$0 == b {print w}')"; \
	if [ -n "$$other_wt" ] && [ "$$other_wt" != "$$(git rev-parse --show-toplevel)" ]; then \
		git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 || true; \
		git checkout -q --detach; git branch -D "$$tmp_branch" >/dev/null; \
		echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."; \
		echo "$(BRANCH) is checked out in $$other_wt; once it is clean: git -C $$other_wt fetch && git -C $$other_wt reset --keep $(REMOTE)/$(BRANCH)"; \
	else \
		git branch -M "$$tmp_branch" "$(BRANCH)"; \
		git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null 2>&1 || { git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 && git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null; } || echo "warning: could not set upstream"; \
		echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."; \
	fi

# lint needs no build: the formatting, the agent-file guard and the source checks.
lint: check-fmt check-no-agent-files check-sources ## check-fmt, the agent-file guard and check-sources
	@test "$$(git config --get core.hooksPath)" = .githooks || echo "lint: hooks not installed, run 'make hooks'"

# lintian reads the packages, so it needs the build; ci runs it after check.
check-lintian: deb ## lintian on both packages (needs the build)
	@if command -v lintian >/dev/null; then \
		lintian --tag-display-limit 0 -L '>=pedantic' --fail-on error,warning $(DEBS) && echo "lintian OK"; \
	elif [ "$$GITHUB_ACTIONS" = true ]; then echo "lintian is not installed on this runner; make init-packages installs it"; exit 1; \
	else echo "lintian not installed: skipping (make init-packages installs it)"; fi

# A shipped hook does nothing until core.hooksPath points at it.
hooks: ## point core.hooksPath at .githooks
	@git config core.hooksPath .githooks && echo "hooks: core.hooksPath -> .githooks"

# Shell scripts are laid out by shfmt (sudo apt install shfmt), with tabs: every tracked file
# that is a shell script by its name or its first line.
# apt's shfmt, the one a CI runner has, before any other on the PATH: versions differ in layout.
SHFMT ?= $(firstword $(wildcard /usr/bin/shfmt) shfmt)
SHFMT_FLAGS = -i 0
SH_SOURCES = git ls-files -z --cached --others --exclude-standard -- . | xargs -0 -r $(SHFMT) -f
.PHONY: fmt check-fmt fmt-sh check-fmt-sh
fmt-sh: ## lay the shell scripts out in place
	@$(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -w

check-fmt-sh: ## fail when a shell script is not as make fmt-sh leaves it
	@if ! command -v $(SHFMT) >/dev/null; then \
		if [ "$$GITHUB_ACTIONS" = true ]; then echo "shfmt is not installed on this runner; make init-packages installs it"; exit 1; fi; \
		echo "shfmt not installed, skipping (sudo apt install shfmt)"; exit 0; \
	fi; \
	bad=$$($(SH_SOURCES) | xargs -r -d '\n' $(SHFMT) $(SHFMT_FLAGS) -l 2>&1) || true; \
	if [ -n "$$bad" ]; then echo "not formatted:"; echo "$$bad"; echo "fix: make fmt"; exit 1; fi; \
	echo "shfmt OK"

fmt: fmt-sh ## format the code in place: here, the shell scripts
check-fmt: check-fmt-sh ## fail on code that is not as make fmt leaves it

# --- siblings: house-rules scripts/binding/siblings.mk, the same in every repository with a siblings.txt ---
# siblings.txt names the repositories this one needs beside it, one a line, as
# `<ROOT_VARIABLE>,https://github.com/<owner>/<name>`; `#` starts a comment and blank lines are
# skipped. `make init-siblings` clones each one that is missing, from the URL as written, into
# `$(<ROOT_VARIABLE>)/<name>`, <name> being the URL's last part without `.git`. A checkout
# already there is left as it is: no pull, no reset, no checkout. Each variable is set in the
# environment or on the command line: mise at a desk, the workflow in CI, each to a folder above
# its workspace. It is part of `setup` (the rule below adds it, first, when this block stands
# above the `setup` rule) and never of `ci`.
SIBLING_ROOTS = $(foreach v,$(filter %_ROOT,$(.VARIABLES)),$(if $(filter environment% command%,$(origin $(v))),$(v)))
.PHONY: init-siblings
init-siblings: ## clone the repositories siblings.txt names that are missing from their roots; one already there is left as it is
	@sed 's/#.*//' siblings.txt | tr -d ' \t\r' | while IFS= read -r line; do \
		[ -n "$$line" ] || continue; \
		var=$${line%%,*}; url=$${line#*,}; \
		printf '%s\n' "$$var" | grep -Eqx '[A-Z_]+_ROOT' && [ "$$var" != "$$line" ] || \
			{ echo "init-siblings: '$$line' in siblings.txt does not start with a root variable and a comma (AMBER_ROOT,https://github.com/<owner>/<name>)" >&2; exit 2; }; \
		printf '%s\n' "$$url" | grep -Eqx 'https://github\.com/[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*' || \
			{ echo "init-siblings: '$$url' in siblings.txt is not https://github.com/<owner>/<name>" >&2; exit 2; }; \
		name=$${url##*/}; name=$${name%.git}; \
		case " $(SIBLING_ROOTS) " in *" $$var "*) ;; \
		*) echo "init-siblings: $$var is not set: it names the root $$name goes in (mise sets it at a desk; a workflow sets it to a folder above its workspace)" >&2; exit 2 ;; esac; \
		root=$$(printenv "$$var") || root=; root=$${root%/}; \
		[ -n "$$root" ] || { echo "init-siblings: $$var is empty" >&2; exit 2; }; \
		dest=$$root/$$name; \
		if [ -e "$$dest" ]; then echo "init-siblings: $$name is there, $$dest"; continue; fi; \
		echo "init-siblings: cloning $$name into $$dest"; \
		git clone -q "$$url" "$$dest" || exit 1; \
	done

setup: init-siblings

# The one command after a fresh clone, the same in every repository.
setup: init-packages init-modules init-workstation ## everything a fresh clone needs: siblings, packages (sudo apt), then hooks
