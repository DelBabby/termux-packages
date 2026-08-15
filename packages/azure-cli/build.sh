TERMUX_PKG_HOMEPAGE=https://learn.microsoft.com/en-us/cli/azure/
TERMUX_PKG_DESCRIPTION="Microsoft Azure Command-Line Interface"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_LICENSE_FILE="LICENSE"
TERMUX_PKG_MAINTAINER="@GourangaDasSamrat"
TERMUX_PKG_VERSION="2.79.0"
TERMUX_PKG_SRCURL="https://github.com/Azure/azure-cli/archive/refs/tags/azure-cli-${TERMUX_PKG_VERSION}.tar.gz"
TERMUX_PKG_SHA256=79fb9c8e0b063144ca0f671c18b23847e4096d204bfc2323997a40ae8a4039d4
TERMUX_PKG_AUTO_UPDATE=false
TERMUX_PKG_DEPENDS="python, python-cryptography, python-psutil, python-bcrypt, libsodium, openssl, libffi"
TERMUX_PKG_BUILD_DEPENDS="python-pip"
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_NO_STATICSPLIT=true

# Why not the normal termux_step_make_install with plain `pip install .`:
# azure-cli's dependency tree (via azure-cli-core -> pyopenssl/msal/etc.)
# pins tighter `cryptography` version ranges than what Termux ships
# (python-cryptography), so a plain `pip install azure-cli` resolver run
# ignores the system package and tries to build `cryptography` from
# source. That triggers maturin -> rustup, and rustup does not know the
# `aarch64-unknown-linux-android` target triple, so the build hangs/fails.
#
# Strategy used here instead:
#   1. Build a venv with --system-site-packages so it can see the
#      Termux-provided prebuilt native wheels (cryptography, psutil,
#      bcrypt) instead of trying to compile them.
#   2. Install azure-cli with --no-build-isolation and a constraints
#      file, so pip's resolver is forced to accept whatever native
#      package versions Termux already has installed, rather than going
#      out and fetching/building different ones.
#   3. If azure-cli's own version pins are incompatible with what
#      Termux ships, pip will fail loudly with a clear conflict message
#      instead of silently trying (and hanging) on a source build.
#
# NOTE: source tarball is ~153MB and this is a large monorepo with many
# extensions - final installed size may exceed the usual <100MiB/arch
# packaging guideline. This will likely need a policy exception, or a
# trimmed-down source tree (e.g. stripping unused command modules)
# before it can be merged upstream.
#
# NOTE on PyNaCl: unlike cryptography/psutil/bcrypt, Termux does NOT
# ship a prebuilt python-pynacl package - only the underlying C library
# (libsodium). PyNaCl's own setup.py compiles a cffi extension against
# libsodium at pip-install time, which is fine (plain C, no rust/maturin
# involved) as long as SODIUM_INSTALL=system is set - otherwise PyNaCl
# tries to download a prebuilt libsodium binary that has no Android
# target and the build will fail/hang.
#
# NOTE: this is a first draft, unverified end-to-end. Needs an on-device
# test run; expect to iterate on which transitive deps still try to
# compile natively (msal, azure-core extras, etc. are the likely next
# offenders after cryptography/psutil are handled).
#
# NOTE (important, unresolved): termux_step_make_install below runs
# `python3 -m venv` + `pip install` directly on the BUILD HOST, which
# only works as-is for TERMUX_ON_DEVICE_BUILD=true (building directly
# inside Termux on an Android device, where the host python3 already
# *is* the Android target python). When cross-building on a CI runner
# (build (aarch64)/(arm)/(x86_64)/(i686) jobs), this venv/pip approach
# needs the same kind of cross-compile toolchain injection aws-cli uses
# (termux_setup_proot + exported AS/CC/LD/... vars) so that PyNaCl's
# native extension gets compiled for the Android target instead of the
# CI host's own architecture. That part is not implemented yet and is
# the next likely failure once buildorder resolution succeeds.

termux_step_pre_configure() {
	# Make sure pip inside the venv we're about to create can't decide to
	# build native wheels from source no matter what - only allow it to
	# use what's already on disk (system-site-packages) or pure python
	# sdists that don't need a compiler.
	export PIP_NO_CACHE_DIR=1
	export PIP_PREFER_BINARY=1
}

termux_step_make() {
	# Nothing to compile ourselves - azure-cli is pure Python. All the
	# native pieces (cryptography, psutil, bcrypt, pynacl) come from
	# Termux's own prebuilt packages declared in TERMUX_PKG_DEPENDS.
	:
}

termux_step_make_install() {
	local venv_dir="$TERMUX_PREFIX/opt/azure-cli"
	local constraints="$TERMUX_PKG_BUILDER_DIR/constraints.txt"

	rm -rf "$venv_dir"
	python3 -m venv --system-site-packages "$venv_dir"

	# shellcheck disable=SC1091
	source "$venv_dir/bin/activate"

	pip install --upgrade pip wheel

	# Pin the native packages to "whatever the system already has",
	# so pip's resolver is not allowed to go fetch/build a different
	# version of them while resolving azure-cli's own pinned ranges.
	python3 - <<-'PYEOF' > "$constraints"
	import cryptography, psutil, bcrypt
	print(f"cryptography=={cryptography.__version__}")
	print(f"psutil=={psutil.__version__}")
	print(f"bcrypt=={bcrypt.__version__}")
	PYEOF

	# PyNaCl is not pre-installed via TERMUX_PKG_DEPENDS (no such Termux
	# package exists), so it is NOT added to the constraints file above -
	# pip is left free to build it from source here, against the
	# system libsodium.
	SODIUM_INSTALL=system pip install \
		--no-build-isolation \
		--constraint "$constraints" \
		"$TERMUX_PKG_SRCDIR"

	deactivate

	# Expose `az` on PATH without polluting the main site-packages.
	install -Dm755 /dev/stdin "$TERMUX_PREFIX/bin/az" <<-EOF
	#!$TERMUX_PREFIX/bin/sh
	exec "$venv_dir/bin/az" "\$@"
	EOF
}
