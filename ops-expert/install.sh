#!/usr/bin/env bash
set -euo pipefail

OFFICIAL_REPO='ApolloAuto/apollo-claw'
OFFICIAL_BRANCH='EDU'
FORK_REPO='apollo-fj/apollo-claw'
FORK_BRANCH="${APOLLO_OPS_FORK_BRANCH:-EDU}"
PROFILE="${DSH_PROFILE:-web}"
DSH_HOME_DIR="${DSH_HOME:-$HOME/.dsh}"
WITH_LAN=0
SOURCE_OVERRIDE="${APOLLO_OPS_REPO_SOURCE:-auto}"
REQUIRED_SKILLS='apollo-env apollo-dev apollo-test apollo-eval'

while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-lan) WITH_LAN=1; shift ;;
    -h|--help)
      echo 'Usage: install.sh [--with-lan]'
      echo 'Set APOLLO_OPS_REPO_SOURCE=official|fork to select a source explicitly.'
      echo 'Set APOLLO_OPS_FORK_BRANCH to test a branch in your fork (default: EDU).'
      echo 'Set APOLLO_OPS_SKILLS_SOURCE to a local checkout to install Skills from disk.'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$SOURCE_OVERRIDE" in
  auto|official|fork) ;;
  *) echo 'APOLLO_OPS_REPO_SOURCE must be auto, official, or fork.' >&2; exit 2 ;;
esac
case "$FORK_BRANCH" in
  ''|/*|*..*|*[!A-Za-z0-9._/-]*) echo 'Invalid APOLLO_OPS_FORK_BRANCH.' >&2; exit 2 ;;
esac

for tool in dsh npm curl tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required command not found: $tool" >&2; exit 1; }
done
if command -v sha256sum >/dev/null 2>&1; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  echo 'Required command not found: sha256sum or shasum.' >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

raw_url() { printf 'https://raw.githubusercontent.com/%s/%s/ops-expert' "$1" "$2"; }
# Branch names may contain slashes; URL-encode them for the archive endpoint.
archive_url() {
  printf 'https://github.com/%s/archive/refs/heads/%s.tar.gz' "$1" "${2//\//%2F}"
}

fetch_metadata() {
  local source="$1" repo="$2" branch="$3" raw
  raw=$(raw_url "$repo" "$branch")
  curl -fsSL "$raw/github-assets/release.env" -o "$TMP_DIR/$source.env" || return 1
  curl -fsSL "$raw/install.sh" -o "$TMP_DIR/$source.install.sh" || return 1
}
field() { sed -n "s/^$2=//p" "$1" | head -1; }

metadata_equal() {
  local key
  for key in RELEASE_VERSION CLIENT_PACKAGE PRESETS_PACKAGE LAN_PACKAGE; do
    [ "$(field "$TMP_DIR/official.env" "$key")" = "$(field "$TMP_DIR/fork.env" "$key")" ] || return 1
  done
  [ "$(sha256_file "$TMP_DIR/official.install.sh")" = "$(sha256_file "$TMP_DIR/fork.install.sh")" ]
}

choose_fork() {
  local answer
  if [ "$SOURCE_OVERRIDE" = fork ]; then return 0; fi
  if [ "$SOURCE_OVERRIDE" = official ]; then return 1; fi
  if [ ! -r /dev/tty ]; then
    echo 'Official and fork sources differ. Re-run interactively, or set APOLLO_OPS_REPO_SOURCE=official|fork.' >&2
    exit 2
  fi
  printf 'Use the fork links for this installation? [y/N] ' > /dev/tty
  IFS= read -r answer < /dev/tty || answer=''
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

SKILLS_LOCAL="${APOLLO_OPS_SKILLS_SOURCE:-}"
if [ -n "$SKILLS_LOCAL" ] && [ -f "$SKILLS_LOCAL/ops-expert/github-assets/release.env" ]; then
  echo "Using local checkout: $SKILLS_LOCAL"
  cp "$SKILLS_LOCAL/ops-expert/github-assets/release.env" "$TMP_DIR/local.env"
  SOURCE='local'
else
  SKILLS_LOCAL=''
  OFFICIAL_OK=0
  FORK_OK=0
  fetch_metadata official "$OFFICIAL_REPO" "$OFFICIAL_BRANCH" && OFFICIAL_OK=1 || true
  fetch_metadata fork "$FORK_REPO" "$FORK_BRANCH" && FORK_OK=1 || true

  if [ "$OFFICIAL_OK" -eq 1 ] && [ "$FORK_OK" -eq 1 ]; then
    if metadata_equal; then
      if [ "$SOURCE_OVERRIDE" = fork ]; then SOURCE='fork'; else SOURCE='official'; fi
      printf 'Official and fork releases match; using %s links.\n' "$SOURCE"
    else
      echo 'Update detected: the official repository and your fork have different install scripts or release metadata.'
      if choose_fork; then SOURCE='fork'; else SOURCE='official'; fi
      printf 'Selected source: %s\n' "$SOURCE"
    fi
  elif [ "$OFFICIAL_OK" -eq 1 ] && [ "$FORK_OK" -eq 0 ]; then
    echo 'The fork release metadata is unavailable; using the official repository.'
    SOURCE='official'
  elif [ "$OFFICIAL_OK" -eq 0 ] && [ "$FORK_OK" -eq 1 ]; then
    echo 'Update detected: the official repository does not yet have these release files; your fork does.'
    if choose_fork; then SOURCE='fork'; else
      echo 'Official release is not ready. No packages were installed.' >&2
      exit 2
    fi
  else
    echo 'Could not read release metadata from either the official repository or your fork.' >&2
    exit 1
  fi
fi

if [ "$SOURCE" = official ]; then
  META="$TMP_DIR/official.env"
  REPO="$OFFICIAL_REPO"
  BRANCH="$OFFICIAL_BRANCH"
elif [ "$SOURCE" = fork ]; then
  META="$TMP_DIR/fork.env"
  REPO="$FORK_REPO"
  BRANCH="$FORK_BRANCH"
else
  META="$TMP_DIR/local.env"
  REPO=''
  BRANCH=''
fi

RELEASE_VERSION=$(field "$META" RELEASE_VERSION)
CLIENT_PACKAGE=$(field "$META" CLIENT_PACKAGE)
PRESETS_PACKAGE=$(field "$META" PRESETS_PACKAGE)
LAN_PACKAGE=$(field "$META" LAN_PACKAGE)
case "$RELEASE_VERSION" in ''|*[!A-Za-z0-9.+-]*) echo 'Invalid RELEASE_VERSION in release.env.' >&2; exit 1 ;; esac
for package in "$CLIENT_PACKAGE" "$PRESETS_PACKAGE" "$LAN_PACKAGE"; do
  case "$package" in @*/*@*) ;; *) echo "Invalid npm package spec in release.env: $package" >&2; exit 1 ;; esac
done

printf 'Installing client plugin %s\n' "$CLIENT_PACKAGE"
dsh plugin --profile "$PROFILE" add "$CLIENT_PACKAGE"

SKILLS_LOCAL="${APOLLO_OPS_SKILLS_SOURCE:-}"
if [ -n "$SKILLS_LOCAL" ]; then
  printf 'Using local Skills from %s\n' "$SKILLS_LOCAL"
  EXTRACT="$SKILLS_LOCAL"
else
  printf 'Downloading Skills %s from %s (%s)\n' "$RELEASE_VERSION" "$REPO" "$BRANCH"
  REPO_ARCHIVE="$TMP_DIR/repo.tar.gz"
  if ! curl -fL --retry 3 "$(archive_url "$REPO" "$BRANCH")" -o "$REPO_ARCHIVE"; then
    echo 'Skills download failed.' >&2
    exit 1
  fi
  EXTRACT="$TMP_DIR/repo"
  mkdir -p "$EXTRACT"
  tar -xzf "$REPO_ARCHIVE" -C "$EXTRACT" --strip-components=1
fi

for skill in $REQUIRED_SKILLS; do
  [ -f "$EXTRACT/$skill/SKILL.md" ] || { echo "Skills source is missing $skill/SKILL.md" >&2; exit 1; }
done

mkdir -p "$DSH_HOME_DIR/skills"
STAMP=$(date +%Y%m%d%H%M%S)
for skill in $REQUIRED_SKILLS; do
  if [ -e "$DSH_HOME_DIR/skills/$skill" ]; then
    BACKUP="$DSH_HOME_DIR/skills/$skill.bak.$STAMP"
    mv "$DSH_HOME_DIR/skills/$skill" "$BACKUP"
    printf 'Backed up existing %s -> %s\n' "$skill" "$BACKUP"
  fi
  cp -a "$EXTRACT/$skill" "$DSH_HOME_DIR/skills/$skill"
  [ -f "$DSH_HOME_DIR/skills/$skill/SKILL.md" ] || { echo "Failed to install $skill" >&2; exit 1; }
  printf 'Installed Skill %s\n' "$skill"
done

printf 'Installing agent presets %s\n' "$PRESETS_PACKAGE"
# 取包内脚本直接执行：npx 会通过 node_modules/.bin 软链调用，脚本按自身目录
# 找预设时会被解析成 .bin 目录而失败。下载 tarball 后从真实路径运行可避免。
PRESET_DIR="$TMP_DIR/presets"
mkdir -p "$PRESET_DIR"
if ! npm pack "$PRESETS_PACKAGE" --pack-destination "$PRESET_DIR" >/dev/null 2>&1; then
  echo "Failed to download $PRESETS_PACKAGE" >&2
  exit 1
fi
tar -xzf "$PRESET_DIR"/*.tgz -C "$PRESET_DIR"
PRESET_INSTALLER="$PRESET_DIR/package/install-presets.sh"
[ -f "$PRESET_INSTALLER" ] || { echo 'Presets package is missing install-presets.sh' >&2; exit 1; }
DSH_HOME="$DSH_HOME_DIR" DSH_PROFILE="$PROFILE" bash "$PRESET_INSTALLER"

if [ "$WITH_LAN" -eq 1 ]; then
  printf 'Installing optional LAN plugin %s\n' "$LAN_PACKAGE"
  dsh plugin --profile "$PROFILE" add "$LAN_PACKAGE"
fi

printf '\nInstallation complete. Restart DSH Web to load the changes.\n'
if [ "$WITH_LAN" -eq 1 ]; then
  printf 'LAN access is enabled; use only on a trusted network.\n'
fi
