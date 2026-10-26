# shellcheck shell=bash
# formatters.sh: which version of each formatter, and how to get it. Sourced by
# format.sh (never run), which has no room for it: format.sh stays under the
# 300-line limit by keeping dispatch and formatting, and this keeps the rest.
#
# Byte-identical in the auto-format skill (scripts/formatters.sh) and in every
# repo, at .claude/scripts/formatters.sh, beside format.sh. A bump moves the
# pins below (vm/formatter_bump.py, weekly), then both files are copied over.
# The env vars override a pin, for tests.
#
# A pinned tool is never installed with brew, which cannot pin: it is
# downloaded from its release into a directory keyed on its version,
#   $TOOLS/<tool>/<version>/<tool>       (prettier: .../node_modules/.bin/prettier)
# with $TOOLS the Actions tool cache on a runner and ~/.cache elsewhere. That is
# the layout .github/actions/install-tool already uses for ruff, so CI shares
# one ruff binary per version. A bump installs beside the old version, never
# over a binary a running job holds. taplo, jq and the rest are not pinned.

RUFF_VERSION="${RUFF_VERSION:-0.17.2}"
SHFMT_VERSION="${SHFMT_VERSION:-3.14.1}"
YAMLFMT_VERSION="${YAMLFMT_VERSION:-0.21.0}"
PRETTIER_VERSION="${PRETTIER_VERSION:-3.9.10}"
SWIFTFORMAT_VERSION="${SWIFTFORMAT_VERSION:-0.64.2}"
SWIFT_VERSION="${SWIFT_VERSION:-6.4}"

TOOLS="${RUNNER_TOOL_CACHE:-$HOME/.cache}"
PINNED_TOOLS="ruff shfmt yamlfmt prettier swiftformat"

# The version a tool is pinned to; empty for a tool that is not pinned.
pin_of() {
	case "$1" in
	ruff) echo "$RUFF_VERSION" ;;
	shfmt) echo "$SHFMT_VERSION" ;;
	yamlfmt) echo "$YAMLFMT_VERSION" ;;
	prettier) echo "$PRETTIER_VERSION" ;;
	swiftformat) echo "$SWIFTFORMAT_VERSION" ;;
	esac
}

is_pinned() { [ -n "$(pin_of "$1")" ]; }

# The folder holding a pinned tool's executable.
bin_dir() {
	if [ "$1" = prettier ]; then
		echo "$TOOLS/prettier/$(pin_of prettier)/node_modules/.bin"
	else
		echo "$TOOLS/$1/$(pin_of "$1")"
	fi
}

# True when the formatter can run: a pinned one only at its pinned version.
tool_present() {
	if is_pinned "$1"; then [ -x "$(bin_dir "$1")/$1" ]; else command -v "$1" >/dev/null; fi
}

# tool -> install command. Empty means "do not auto-install": language toolchains
# (go, rust, dart, terraform) are too heavy to pull in because someone touched
# one file; they format when present and report when not.
install_cmd_for() {
	is_pinned "$1" && {
		echo "format.sh --setup <path> ($1 $(pin_of "$1") from its release)"
		return
	}
	case "$1" in
	jq) echo "brew install jq" ;;
	taplo) echo "brew install taplo" ;;
	ktlint) echo "brew install ktlint" ;;
	google-java-format) echo "brew install google-java-format" ;;
	clang-format) echo "brew install clang-format" ;;
	rubocop) echo "brew install rubocop" ;;
	esac
}

# --- Fetchers: each unpacks one release into $2/payload (curl; python3's
# zipfile because unzip is missing on the Oracle VM runner) ---

download() { curl -fsSL --connect-timeout 15 --speed-limit 1024 --speed-time 30 -o "$2" "$1"; }

# What uname reports; each release spells its own OS and CPU names.
cpu_is_arm() {
	case "$(uname -m)" in arm64 | aarch64) return 0 ;; esac
	return 1
}
os_is_mac() { [ "$(uname -s)" = Darwin ]; }

fetch_ruff() {
	local cpu=x86_64 triple
	cpu_is_arm && cpu=aarch64
	triple="$cpu-unknown-linux-gnu"
	os_is_mac && triple="$cpu-apple-darwin"
	download "https://github.com/astral-sh/ruff/releases/download/$1/ruff-$triple.tar.gz" "$2/a.tgz" &&
		mkdir "$2/payload" &&
		tar -xzf "$2/a.tgz" -C "$2/payload" --strip-components=1 "ruff-$triple/ruff"
}

fetch_shfmt() {
	local os=linux cpu=amd64
	os_is_mac && os=darwin
	cpu_is_arm && cpu=arm64
	mkdir "$2/payload" &&
		download "https://github.com/mvdan/sh/releases/download/v$1/shfmt_v${1}_${os}_$cpu" "$2/payload/shfmt" &&
		chmod +x "$2/payload/shfmt"
}

fetch_yamlfmt() {
	local os=Linux cpu=x86_64
	os_is_mac && os=Darwin
	cpu_is_arm && cpu=arm64
	download "https://github.com/google/yamlfmt/releases/download/v$1/yamlfmt_${1}_${os}_$cpu.tar.gz" "$2/a.tgz" &&
		mkdir "$2/payload" && tar -xzf "$2/a.tgz" -C "$2/payload" yamlfmt
}

fetch_swiftformat() {
	local asset=swiftformat
	if ! os_is_mac; then
		asset=swiftformat_linux
		cpu_is_arm && asset=swiftformat_linux_aarch64
	fi
	download "https://github.com/nicklockwood/SwiftFormat/releases/download/$1/$asset.zip" "$2/a.zip" &&
		python3 -m zipfile -e "$2/a.zip" "$2/unzipped" &&
		mkdir "$2/payload" && install -m 755 "$2/unzipped/$asset" "$2/payload/swiftformat"
}

fetch_prettier() {
	command -v npm >/dev/null || {
		echo "auto-format: npm not found: install Node, then format.sh --setup" >&2
		return 1
	}
	npm install --silent --prefix "$2/payload" "prettier@$1" >/dev/null
}

# Install one pinned tool at its pinned version. Built in a temp folder and
# moved into place, so two jobs meeting a cold cache never see half a tool.
# When the other job moved its copy in first, mv lands this one inside it as
# payload/, which is removed: the winner's copy stays.
install_pinned() {
	local tool="$1" version dir tmp
	version="$(pin_of "$tool")"
	dir="$TOOLS/$tool/$version"
	mkdir -p "$TOOLS/$tool" && tmp="$(mktemp -d "$TOOLS/$tool/.tmp.XXXXXX")" || return 1
	echo "auto-format: installing $tool $version…" >&2
	if "fetch_$tool" "$version" "$tmp" && mv "$tmp/payload" "$dir"; then
		rm -rf "$dir/payload" "$tmp"
		tool_present "$tool" && return 0
	fi
	rm -rf "$tmp"
	echo "auto-format: could not install $tool $version" >&2
	return 1
}

# Make sure a formatter is present. Installs only when explicitly allowed.
ensure_tool() {
	local tool="$1" file="$2" cmd
	tool_present "$tool" && return 0
	cmd="$(install_cmd_for "$tool")"
	if [ -z "$cmd" ]; then
		echo "auto-format: $tool not installed and no safe installer known — $file left unformatted." >&2
		return 1
	fi
	if [ "$ALLOW_INSTALL" != "1" ]; then
		echo "auto-format: $tool not installed, so $file was left unformatted. Run: $cmd" >&2
		return 1
	fi
	is_pinned "$tool" && {
		install_pinned "$tool"
		return
	}
	if ! command -v brew >/dev/null; then
		echo "auto-format: brew not found — install $tool manually: $cmd" >&2
		return 1
	fi
	echo "auto-format: installing $tool ($cmd)…" >&2
	$cmd >/dev/null 2>&1
	command -v "$tool" >/dev/null || {
		echo "auto-format: could not install $tool — run manually: $cmd" >&2
		return 1
	}
}

# A pinned tool wins over brew's and over anything else on PATH.
for _tool in $PINNED_TOOLS; do PATH="$(bin_dir "$_tool"):$PATH"; done
