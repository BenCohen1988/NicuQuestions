#!/bin/bash
# auto-format: run the right formatter for each file, based on its extension.
#
# Usage:
#   format.sh <file-or-directory>...   Format the given paths (directories recurse).
#                                      Installs a missing formatter, then formats.
#   format.sh --setup <path>...        Install the formatters the path needs; format nothing.
#                                      Exit 1 when a pinned one could not be installed.
#   format.sh --install <tool>...      Install exactly these pinned tools (ruff shfmt yamlfmt
#                                      prettier swiftformat); exit 1 if one failed, 2 if a
#                                      name is not pinned. CI's entry: no version in a workflow.
#   format.sh --lint <path>...         Swift only: SwiftFormat --lint with the same arguments
#                                      as a format run; exit 1 when any file would change.
#   format.sh --hook                   Claude Code PostToolUse mode: reads the hook
#                                      JSON on stdin and formats the edited file.
#
# Two rules make this safe to call on anything:
#   - Unknown extensions are skipped silently.
#   - A formatter failure never corrupts a file (jq writes via a temp file;
#     prettier/ruff only write on a successful parse).
#
# Why --hook never installs: the hook fires on EVERY edit. An install there
# would block a keystroke on a network round-trip, and would retry forever if it
# failed. Instead the hook reports the gap once, on stderr, so it is visible
# rather than silently skipped — then you (or `format.sh <path>`) install it.
#
# This file and formatters.sh (the pinned versions and their installers) are
# byte-identical in the auto-format skill (scripts/) and in every repo that
# vendors them at .claude/scripts/ (Claude Code's project hook needs them
# inside the repo). Copy both, always. It stays identical by holding nothing
# repo-specific. What a repo must never reformat (machine-written JSON, a file
# that is an API contract, an Xcode-owned asset catalog) is declared in that
# repo's .gitattributes with `-format`, where git already keeps per-path facts:
#
#   data/**        -format
#   tickers.json   -format
#
# To add a language: add its extension to formatter_for and its installer to
# install_cmd_for (formatters.sh). Only well-known formatters belong here — never install
# something discovered ad hoc.
#
# What is deliberately NOT here: Xcode-owned XML (.plist, .storyboard,
# .pbxproj, .xcscheme), systemd units, Firestore .rules, .svg, .xml, .csv —
# either no standard formatter exists or a tool owns the file and would fight
# any reformat. Those are left exactly as they are.

# shellcheck disable=SC2034 # ALLOW_INSTALL is read by ensure_tool, in formatters.sh

# SwiftFormat's opt-in rules, the one Swift style for every repo. They live
# here, not in a per-repo .swiftformat, so the script stays the only copy:
# every repo already vendors it byte for byte, and every Swift edit, commit
# and CI format run goes through it.
#
# Left out, because each broke an iOS build (seen 21.10.2026, the first CI
# run after the reformat):
# - propertyTypes: `x = URL(string: s)!` became `x: URL = (string: s)!`, and
#   `x = T.make()` became `x: T = .make()`, wrong when make() is not a T.
# - isEmpty: `count > 0` became `!isEmpty` on a type with no isEmpty
#   (PHFetchResult).
# - privateStateVariables: made @ObservedObject properties private, which
#   makes the view's memberwise init private too.
SWIFT_RULES=markTypes,noGuardInTests,preferSwiftStringAPI,singlePropertyPerLine,sortSwitchCases

# Pinned versions, their installers and PATH live beside this file.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ ! -r "$HERE/formatters.sh" ]; then
	echo "auto-format: formatters.sh missing beside format.sh: copy both from OpsScripts" >&2
	# An edit or a commit only warns (the shared pre-commit ignores our
	# status); CI's auto-format and standard-check fail.
	[ "$1" = --hook ] && exit 0
	exit 1
fi
# shellcheck source=formatters.sh
. "$HERE/formatters.sh"

# extension -> the formatter that owns it. One owner per type: two formatters on
# one file fight forever (jq expands JSON arrays, prettier collapses them).
# A file with no known extension is a shell script if its first line says so
# (the .githooks/pre-commit in every repo), and nothing otherwise.
formatter_for() {
	case "$(basename "$1")" in
	*.swift) echo swiftformat ;;
	*.py | *.pyi) echo ruff ;;
	*.sh | *.bash | *.zsh) echo shfmt ;;
	*.yml | *.yaml) echo yamlfmt ;;
	*.json | *.webmanifest) echo jq ;;
	*.toml) echo taplo ;;
	*.js | *.jsx | *.ts | *.tsx | *.mjs | *.cjs | *.mts | *.cts | *.html | *.css | *.scss | *.less | *.vue | *.md | *.markdown | *.mdx | *.graphql | *.gql | *.json5 | *.jsonc) echo prettier ;;
	*.kt | *.kts) echo ktlint ;;
	*.java) echo google-java-format ;;
	*.go) echo gofmt ;;
	*.rs) echo rustfmt ;;
	*.c | *.h | *.cc | *.cpp | *.cxx | *.hpp | *.hh | *.m | *.mm) echo clang-format ;;
	*.dart) echo dart ;;
	*.rb | *.rake | Gemfile | Rakefile) echo rubocop ;;
	*.tf | *.tfvars) echo terraform ;;
	*.*) ;;
	*)
		case "$(head -c 64 "$1" 2>/dev/null | head -n 1)" in
		'#!'*sh*) echo shfmt ;;
		esac
		;;
	esac
}

# `-format` in .gitattributes reads back as "unset". Outside a checkout, or
# for a path no pattern names, check-attr says "unspecified" and the file is
# formatted like any other. The git environment is dropped first: a hook in a
# linked worktree is handed an absolute GIT_DIR, which makes check-attr
# resolve against the wrong work-tree root and answer "unspecified" for a
# path that is marked `-format`.
skip_by_attr() {
	[ "$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX \
		git -C "$(dirname "$1")" check-attr format -- "$(basename "$1")" 2>/dev/null | sed 's/.*: //')" = unset ]
}

skip_file() {
	case "$1" in
	*/node_modules/* | */.git/* | */Pods/* | */.build/* | */venv/* | */.venv/* | */dist/* | */coverage/*) return 0 ;;
	esac
	# Lockfiles belong to the package manager; everything else a repo owns by
	# machine is declared in its .gitattributes, not hardcoded here.
	case "$(basename "$1")" in
	package-lock.json | *.lock.json) return 0 ;;
	esac
	skip_by_attr "$1" && return 0
	return 1
}

# The one SwiftFormat call: format and --lint must agree on every argument.
run_swiftformat() {
	swiftformat "$1" --quiet --enable "$SWIFT_RULES" --swiftversion "$SWIFT_VERSION" "${@:2}"
}

format_file() {
	local f="$1" tool
	[ -f "$f" ] || return 0
	skip_file "$f" && return 0
	tool="$(formatter_for "$f")"
	[ -n "$tool" ] || return 0
	ensure_tool "$tool" "$f" || return 0
	case "$tool" in
	swiftformat)
		run_swiftformat "$f"
		;;
	ruff) ruff format --quiet "$f" ;;
	shfmt) shfmt -w "$f" ;;
	ktlint) ktlint --format --log-level=none "$f" >/dev/null 2>&1 ;;
	google-java-format) google-java-format --replace "$f" >/dev/null 2>&1 ;;
	gofmt) gofmt -w "$f" ;;
	rustfmt) rustfmt --edition 2021 "$f" >/dev/null 2>&1 ;;
	# Only where the project has a .clang-format: with no style file the
	# fallback "none" leaves the file alone instead of imposing LLVM style.
	clang-format) clang-format -i --style=file --fallback-style=none "$f" 2>/dev/null ;;
	dart) dart format "$f" >/dev/null 2>&1 ;;
	# Safe autocorrect only (-a), never the unsafe set (-A).
	rubocop) rubocop -a --format quiet "$f" >/dev/null 2>&1 ;;
	terraform) terraform fmt "$f" >/dev/null 2>&1 ;;
	# retain_line_breaks_single keeps the blank lines that separate blocks, so
	# hand-written workflows keep their visual structure.
	yamlfmt) yamlfmt -quiet -formatter retain_line_breaks_single=true "$f" 2>/dev/null ;;
	taplo) taplo fmt "$f" >/dev/null 2>&1 ;;
	# Prettier picks up the project's .prettierrc/.prettierignore automatically
	# and only writes on a successful parse, so a syntax error never corrupts.
	prettier) prettier --write --log-level silent "$f" 2>/dev/null ;;
	jq)
		local tmp
		tmp="$(mktemp)" && jq --indent 2 . "$f" >"$tmp" 2>/dev/null && mv "$tmp" "$f" || rm -f "$tmp"
		;;
	esac
	return 0
}

# Directories recurse over every file; formatter_for decides per file, so a
# shebang script without an extension is found too.
walk() {
	local path="$1"
	if [ -d "$path" ]; then
		# Process substitution, not a pipe: --lint records drift in a variable
		# that a pipeline's subshell would lose.
		while IFS= read -r -d '' f; do "$ACTION" "$f"; done < <(find "$path" \( -name node_modules -o -name .git -o -name Pods -o -name .build -o -name venv -o -name .venv -o -name dist -o -name coverage \) -prune -o -type f -print0)
	else
		"$ACTION" "$path"
	fi
}

# --setup: install what the path needs, format nothing.
setup_file() {
	local tool
	skip_file "$1" && return 0
	tool="$(formatter_for "$1")"
	[ -n "$tool" ] || return 0
	# A pinned formatter that cannot be installed fails the setup; the rest
	# (a toolchain, a brew tool) are reported and left.
	ensure_tool "$tool" "$1" || ! is_pinned "$tool" || SETUP_FAILED=1
}

# --lint: Swift only; reports each file SwiftFormat would change and sets
# LINT_FAILED. A missing formatter fails too: a lint that cannot run is not a pass.
lint_file() {
	local f="$1"
	[ -f "$f" ] || return 0
	skip_file "$f" && return 0
	[ "$(formatter_for "$f")" = swiftformat ] || return 0
	ensure_tool swiftformat "$f" || {
		LINT_FAILED=1
		return 0
	}
	run_swiftformat "$f" --lint >/dev/null 2>&1 || {
		echo "format.sh: $f is not formatted (run: format.sh $f)" >&2
		LINT_FAILED=1
	}
}

install_usage() {
	echo "usage: format.sh --install TOOL...  (pinned: $PINNED_TOOLS)${1:+; not pinned: $1}" >&2
	exit 2
}

if [ "$1" = "--hook" ]; then
	# A hook must stay fast and unattended: format if the tool is here, report if not.
	ALLOW_INSTALL=0
	file="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)"
	[ -n "$file" ] && format_file "$file"
	exit 0
fi

ALLOW_INSTALL=1
if [ "$1" = "--install" ]; then
	shift
	[ $# -gt 0 ] || install_usage
	for tool in "$@"; do is_pinned "$tool" || install_usage "$tool"; done
	status=0
	for tool in "$@"; do tool_present "$tool" || install_pinned "$tool" || status=1; done
	exit "$status"
fi
if [ "$1" = "--setup" ]; then
	shift
	ACTION=setup_file
elif [ "$1" = "--lint" ]; then
	shift
	ACTION=lint_file
else
	ACTION=format_file
fi
LINT_FAILED=0
SETUP_FAILED=0
for path in "$@"; do walk "$path"; done
exit $((LINT_FAILED | SETUP_FAILED))
