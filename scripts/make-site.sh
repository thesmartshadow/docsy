#!/bin/bash
# cSpell:ignore autoprefixer docsy postcss themesdir github oneline
set -eo pipefail

# -----------------------------
# Defaults / Globals
# -----------------------------
DEPS=(autoprefixer postcss-cli)

DOCSY_REPO_DEFAULT="google/docsy"
DOCSY_REPO="$DOCSY_REPO_DEFAULT"
DOCSY_VERS=""
DOCSY_SRC="NPM"
FORCE_DELETE=false

# Allow HUGO to be overridden (e.g., "hugo" or "npx hugo")
HUGO="${HUGO:-"npx hugo"}"
SITE_NAME="test-site"
THEMESDIR="node_modules"

VERBOSE=1
QUIET=false

function _usage() {
  cat <<EOS
Usage: $(basename "$0") [options]

  Creates a Docsy-themed site under SITE_NAME using the Hugo new command.
  Docsy is fetched as an NPM package from $DOCSY_REPO in GitHub,
  unless the -l or -s HUGO_MOD flags are used.

  -f            Force delete SITE_NAME if it exists before recreating it
  -h            Output this usage info
  -l PATH       Use local Docsy from PATH. Default: '$THEMESDIR'
  -n SITE_NAME  Name of directory to create for the Hugo generated site.
                Default: '$SITE_NAME'
  -q            Run a bit more quietly.
  -r REPO       GitHub org+repo to fetch Docsy from.
                Format: GITHUB_USER/DOCSY_REPO. Default: $DOCSY_REPO_DEFAULT
  -s MOD_OR_PKG Docsy source: from a Hugo module or NPM package named '$DOCSY_REPO', where
                MOD_OR_PKG is NPM or HUGO_MODULE (HUGO for short). Default: $DOCSY_SRC
  -v VERS       Docsy Hugo module or NPM package version. Default: '$DOCSY_VERS'.
                Examples for Hugo modules: v1.1.1, some-branch-name
                Examples for NPM: semver:1.1.1, some-branch-name

EOS
}

function usage() {
  local status=${1:-0}
  _usage 1>&2
  exit "$status"
}

function die() {
  echo "[ERROR] $*" >&2
  exit 1
}

function info() {
  echo "[INFO] $*"
}

# Quiet wrapper (mimics previous OUTPUT_REDIRECT behavior)
function run() {
  if "$QUIET"; then
    "$@" >/dev/null 2>&1
  else
    "$@"
  fi
}

# Parse HUGO string into argv array safely (no eval).
# Example: "npx hugo" -> ("npx" "hugo")
function init_hugo_cmd() {
  read -r -a HUGO_CMD <<< "$HUGO"
  if [[ ${#HUGO_CMD[@]} -eq 0 ]]; then
    die "Invalid HUGO command"
  fi
}

# Validate repo format: owner/name
function validate_docsy_repo() {
  if [[ ! "$DOCSY_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    die "Invalid -r REPO format '$DOCSY_REPO'. Expected 'owner/repo'."
  fi
}

# Conservative but practical git ref / version validation.
# Goal: reject shell metacharacters and known-dangerous ref patterns while allowing common branches/tags.
function validate_docsy_vers() {
  local v="$1"
  [[ -z "$v" ]] && return 0

  # Reject whitespace and common shell metacharacters outright
  if [[ "$v" =~ [[:space:]] ]]; then
    die "Invalid -v VERS: whitespace is not allowed"
  fi
  if [[ "$v" =~ [\;\&\|\`\$\<\>\(\)\{\}\!\"] ]]; then
    die "Invalid -v VERS: contains illegal characters"
  fi
  # Reject backslash and brackets (often problematic in refs and shells)
  if [[ "$v" =~ [\\\[\]] ]]; then
    die "Invalid -v VERS: contains illegal characters"
  fi

  # Reject dangerous/invalid git-ref patterns
  if [[ "$v" == .* || "$v" == */ || "$v" == *..* || "$v" == *//* || "$v" == *"@{"* ]]; then
    die "Invalid -v VERS: looks like an unsafe/invalid ref"
  fi
  if [[ "$v" == -* ]]; then
    die "Invalid -v VERS: must not start with '-'"
  fi

  # Allow typical patterns: tags/branches like v1.2.3, main, feature/x, release-2025.12, semver:1.2.3
  if [[ ! "$v" =~ ^(semver:)?[A-Za-z0-9][A-Za-z0-9._/-]{0,200}$ ]]; then
    die "Invalid -v VERS: unsupported format"
  fi
}

function process_CLI_args() {
  while getopts ":fhl:n:qr:s:v:" opt; do
    case $opt in
      f)
        FORCE_DELETE=true
        ;;
      h)
        usage
        ;;
      l)
        DOCSY_SRC="LOCAL"
        THEMESDIR="$OPTARG"
        ;;
      n)
        SITE_NAME="$OPTARG"
        ;;
      q)
        VERBOSE=""
        QUIET=true
        ;;
      r)
        DOCSY_REPO="$OPTARG"
        ;;
      s)
        DOCSY_SRC=$(echo "$OPTARG" | tr '[:lower:]' '[:upper:]')
        if [[ $DOCSY_SRC != "NPM" && $DOCSY_SRC != HUGO* ]]; then
          echo "ERROR: invalid argument to -s flag: $OPTARG" >&2
          usage 1
        fi
        ;;
      v)
        DOCSY_VERS="$OPTARG"
        ;;
      \?)
        echo "ERROR: unrecognized flag: -$OPTARG" >&2
        usage 1
        ;;
    esac
  done

  shift $((OPTIND-1))
  if [[ "$#" -gt 0 ]]; then
    echo "ERROR: extra argument(s): $*" >&2
    usage 1
  fi
}

# Create site directory, checking if it exists first
function create_site_directory() {
  if [[ -e "$SITE_NAME" ]]; then
    if [[ "$FORCE_DELETE" == true ]]; then
      info "Directory '$SITE_NAME' already exists. Deleting it as requested (-f)."
      ([[ $VERBOSE ]] && set -x; rm -rf "$SITE_NAME")
    else
      die "Directory '$SITE_NAME' already exists. Remove it or use -f to force delete."
    fi
  fi
}

function _npm_install() {
  # Keep npm init quiet by default (matches original behavior)
  npm init -y >/dev/null
  npm install --omit dev --save "${DEPS[@]}"
}

function set_up_and_cd_into_site() {
  run "${HUGO_CMD[@]}" new site --format yaml --quiet "$SITE_NAME"
  cd "$SITE_NAME"
  run _npm_install

  if [[ "$DOCSY_SRC" == HUGO* ]]; then
    _set_up_site_using_hugo_modules
  else
    echo "theme: docsy" >> hugo.yaml
    echo "themesDir: $THEMESDIR" >> hugo.yaml
  fi
}

function _set_up_site_using_hugo_modules() {
  local user_name
  user_name="$(whoami)"

  local HUGO_MOD_WITH_VERS="$DOCSY_REPO"
  if [[ -n "$DOCSY_VERS" ]]; then
    HUGO_MOD_WITH_VERS+="@$DOCSY_VERS"
  fi

  info "Getting Docsy as Hugo module $HUGO_MOD_WITH_VERS"

  run "${HUGO_CMD[@]}" mod init "github.com/$user_name/$SITE_NAME"

  if [[ "$DOCSY_REPO" == "$DOCSY_REPO_DEFAULT" ]]; then
    run "${HUGO_CMD[@]}" mod get "github.com/$HUGO_MOD_WITH_VERS"
  else
    info "Fetch Docsy GitHub repo '$DOCSY_REPO' @ '$DOCSY_VERS'"
    mkdir -p tmp

    local DEPTH=10
    local SWITCH_NEEDED=""
    local repo_url="https://github.com/$DOCSY_REPO"

    if [[ -n "$DOCSY_VERS" ]]; then
      if ! git clone --depth="$DEPTH" -b "$DOCSY_VERS" "$repo_url" tmp/docsy; then
        SWITCH_NEEDED=1
        git clone --depth="$DEPTH" "$repo_url" tmp/docsy
      fi
    else
      git clone --depth="$DEPTH" "$repo_url" tmp/docsy
    fi

    (
      cd tmp/docsy
      git log --oneline -"${DEPTH}"
      if [[ -n "$SWITCH_NEEDED" && -n "$DOCSY_VERS" ]]; then
        git switch --detach "$DOCSY_VERS"
      fi
    )

    echo "replace github.com/$DOCSY_REPO_DEFAULT => ./tmp/docsy" >> go.mod
    run "${HUGO_CMD[@]}" mod get "github.com/$DOCSY_REPO_DEFAULT"
  fi

  echo "module: {proxy: direct, hugoVersion: {extended: true}, imports: [{path: github.com/$DOCSY_REPO_DEFAULT, disable: false}]}" >> hugo.yaml
}

function main() {
  process_CLI_args "$@"
  init_hugo_cmd

  # Hardening: validate inputs used in module fetch paths/refs
  validate_docsy_repo
  validate_docsy_vers "$DOCSY_VERS"

  create_site_directory

  if [[ "$DOCSY_SRC" == "NPM" ]]; then
    local NPM_PKG="$DOCSY_REPO"
    if [[ -n "$DOCSY_VERS" ]]; then
      NPM_PKG+="#$DOCSY_VERS"
    fi
    info "Getting Docsy as NPM package '$NPM_PKG'"
    DEPS+=("$NPM_PKG")
  elif [[ "$DOCSY_SRC" == "LOCAL" ]]; then
    info "Getting Docsy through a local directory '$THEMESDIR'"
  fi

  [[ $VERBOSE ]] && set -x
  set_up_and_cd_into_site

  # Generate site (no eval)
  run "${HUGO_CMD[@]}"

  [[ $VERBOSE ]] && set +x
  cd ..

  info "'$SITE_NAME' successfully created, set up, and built."

  if [[ $VERBOSE ]]; then
    info "Here are the site files:"
    echo
    set -x
    ls -l "$SITE_NAME"
    echo
    ls -l "$SITE_NAME/public"
  fi
}

main "$@"
