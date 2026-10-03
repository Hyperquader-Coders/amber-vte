# amber-vte: one VTE build for the whole amber suite.
#
# `make vte` builds it, `make deb` packages it to /usr/lib/amber-vte, and the apps
# point their RUNPATH there. See README.md for why it exists at all.
VERSION = 0.84.1
# The package revision, bumped when the packaging changes but the VTE version does not.
REVISION = 1
DEB = dist/amber-vte_$(VERSION)-$(REVISION)_amd64.deb
BRANCH ?= main
REMOTE ?= origin
ROOT_COMMIT_MSG ?= Initial amber-vte

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
# VTE is built against the distro's GTK headers and resolves libgtk-4.so.1 at run time
# through this RUNPATH, so it uses the amber-gtk4 bundle wherever that is installed.
GTK_BUNDLE_DIR = /usr/lib/amber-gtk4
GTK_BUNDLE_MIN = 4.16.13
# The release tarball, verified against the sum GNOME publishes beside it
# (download.gnome.org/sources/vte/<major.minor>/vte-<version>.sha256sum). A fetched
# archive that does not match is deleted, so a wrong VERSION bump fails here and not
# after the build. Lives under build/, not /tmp: /tmp is shared and predictable.
TARBALL = build/vte-$(VERSION).tar.xz
TARBALL_SHA256 = aca1caa8478aebcdbb1d67897fb3511eb7601debae6810e16a15b6fa25f31ac8
TARBALL_URL = https://download.gnome.org/sources/vte/$(basename $(VERSION))/vte-$(VERSION).tar.xz

.PHONY: deps help vte build built stage check ci deb deb-path deb-install deb-remove clean push force-push lint hooks check-no-agent-files

deps: hooks ## install the build dependencies and git hooks
	sudo apt install meson ninja-build gperf g++-14 shellcheck dpkg-dev binutils \
		libgtk-4-dev libglib2.0-dev liblz4-dev libsystemd-dev libdrm-dev \
		libgnutls28-dev libicu-dev libpcre2-dev libfribidi-dev

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

# Build VTE $(VERSION) (gtk4) for bundling. Mint ships 0.76; the termprop API and the
# UUID functions the apps use are only in 0.78 and later.
#
# gcc-14 because VTE 0.84 is C++20. The linker is given the amber-gtk4 RUNPATH, so the
# library finds the bundled GTK without the application's help.
vte: $(TARBALL) ## fetch, patch and build VTE into build/vte/stage
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
	CC=gcc-14 CXX=g++-14 meson setup build/vte/_build build/vte --prefix=$(CONF_PREFIX) \
		--libdir=$(CONF_LIBDIR) -Dgtk3=false -Dgtk4=true -Dvapi=false -Dgir=false \
		-Ddocs=false -Dglade=false -Dapp=false \
		-Dc_link_args=-Wl,-rpath,$(GTK_BUNDLE_DIR) \
		-Dcpp_link_args=-Wl,-rpath,$(GTK_BUNDLE_DIR)
	DESTDIR=$$(pwd)/$(STAGE) ninja -C build/vte/_build install
	# Strip in place, so `make check` sees exactly what `make deb` will ship.
	find $(BUNDLE) -type f -name '*.so*' -exec strip --strip-unneeded {} +

# The standard name for the build; the one build there is.
build: vte ## the same as vte

built: stage
	@test -e $(BUNDLE)/libvte-2.91-gtk4.so.0 || \
		{ echo "no bundle at $(BUNDLE) — run 'make vte'"; exit 1; }

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
check: built ## the bundle pulls in no newer stack and carries no build paths
	@scripts/check-no-cascade $(BUNDLE)/libvte-2.91-gtk4.so.0
	@scripts/check-no-buildpaths $(BUNDLE)

ci: check lint deb ## everything a push must pass
	@echo "CI OK — bundle resolves against the stock stack, carries no build paths, and packages"

# Binary .deb. Ships the shared object only: no headers, no pkg-config, no binaries.
# This is a runtime bundle for the amber apps, not a -dev package. The staged headers
# under build/vte/stage/usr/include are what odin-vte generates its bindings from.
deb: check ## package the bundle into dist/
	rm -rf build/deb build/shlibwork
	install -d build/deb$(INSTALL_DIR)
	install -D -m644 $(BUNDLE)/libvte-2.91-gtk4.so.0 build/deb$(INSTALL_DIR)/libvte-2.91-gtk4.so.0
	# Assert on what is actually packaged, not only on what was staged: `make deb` must
	# not be a way around `make check`.
	@scripts/check-no-buildpaths build/deb
	install -D -m644 packaging/lintian-overrides build/deb/usr/share/lintian/overrides/amber-vte
	install -D -m644 packaging/debian/copyright build/deb/usr/share/doc/amber-vte/copyright
	gzip -9n < packaging/debian/changelog > build/deb/usr/share/doc/amber-vte/changelog.Debian.gz
	chmod 644 build/deb/usr/share/doc/amber-vte/changelog.Debian.gz
	mkdir -p build/deb/DEBIAN
	# The bundle is deliberately NOT on the ldconfig path: only a binary whose RUNPATH
	# names $(INSTALL_DIR) picks it up, so installing this cannot change what any other
	# program on the system links against. No shlibs file either, for the same reason.
	find build/deb -type d -exec chmod 755 {} +
	cd build/deb && find . -type f -not -path './DEBIAN/*' -printf '%P\n' | sort | xargs md5sum > DEBIAN/md5sums
	mkdir -p build/shlibwork/debian
	printf 'Source: amber-vte\n\nPackage: amber-vte\nArchitecture: amd64\n' > build/shlibwork/debian/control
	# --ignore-missing-info: amber-gtk4 ships no shlibs file by design; control.in names
	# that dependency explicitly. shlibdeps resolves libgtk-4.so.1 to the archive's
	# libgtk-4-1, which is never loaded when the RUNPATH reaches amber-gtk4 first, so that
	# claim is dropped: the GTK dependency is amber-gtk4 and nothing else.
	cd build/shlibwork && dpkg-shlibdeps -O --ignore-missing-info \
		../deb$(INSTALL_DIR)/libvte-2.91-gtk4.so.0 > deps.txt
	sed -e 's/@VERSION@/$(VERSION)-$(REVISION)/' \
		-e 's/@GTK_MIN@/$(GTK_BUNDLE_MIN)/' \
		-e "s/@SIZE@/$$(du -sk build/deb --exclude=DEBIAN | cut -f1)/" \
		-e "s|@DEPS@|$$(sed -e 's/^shlibs:Depends=//' -e 's/libgtk-4-1 ([^)]*)\(, \)\?//' build/shlibwork/deps.txt)|" \
		packaging/control.in > build/deb/DEBIAN/control
	mkdir -p dist
	dpkg-deb --build --root-owner-group build/deb $(DEB)

# Where `make deb` puts the package: one absolute path, nothing else.
# amberlinux-apt ingests it through this.
deb-path: ## print the absolute path of the .deb
	@echo "$(CURDIR)/$(DEB)"

deb-install: deb ## build and install the .deb (sudo)
	# --allow-downgrades: once the package is published, the archive carries the same
	# version at a higher pin priority than a local file, so apt reads installing your own
	# build as a downgrade and refuses.
	sudo apt install --reinstall --allow-downgrades ./$(DEB)

deb-remove: ## remove the installed package (sudo)
	sudo apt remove amber-vte

clean: ## remove the deb staging and dist/ (keeps the VTE build)
	rm -rf build/deb build/shlibwork dist

push: ## git push to REMOTE BRANCH (origin main)
	git push "$(REMOTE)" "$(BRANCH)"

# Agent files are never published. Two ways they get in: already tracked, or
# present-and-unignored when `git add -A` below sweeps the whole tree. Both are
# checked here, because a squashed history shows no file being added: a stray
# path appears in the root commit like any other file.
check-no-agent-files: ## refuse agent files that are tracked or not ignored
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored — 'git add -A' would publish it"; \
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
	git branch -M "$$tmp_branch" "$(BRANCH)"; \
	git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null 2>&1 || { git fetch "$(REMOTE)" "$(BRANCH)" >/dev/null 2>&1 && git branch --set-upstream-to="$(REMOTE)/$(BRANCH)" "$(BRANCH)" >/dev/null; } || echo "warning: could not set upstream"; \
	echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."

lint: deb check-no-agent-files ## shellcheck, lintian, hooks installed, agent-file guard
	@if command -v shellcheck >/dev/null; then \
		git ls-files | while read -r f; do \
			case "$$f" in *.sh|*.bash) echo "$$f";; \
			*) head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh' && echo "$$f";; esac; \
		done | xargs -r shellcheck --severity=warning && echo "shellcheck OK"; \
	else echo "shellcheck not installed — skipping (apt install shellcheck)"; fi
	@test "$$(git config --get core.hooksPath)" = .githooks || echo "lint: hooks not installed — run 'make hooks'"
	@if command -v lintian >/dev/null; then lintian --no-tag-display-limit -L '>=pedantic' $(DEB); \
	else echo "lintian not installed — skipping (apt install lintian)"; fi

# A shipped hook does nothing until core.hooksPath points at it.
hooks: ## point core.hooksPath at .githooks
	@git config core.hooksPath .githooks && echo "hooks: core.hooksPath -> .githooks"
