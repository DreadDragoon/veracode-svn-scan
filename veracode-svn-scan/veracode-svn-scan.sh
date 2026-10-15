#!/usr/bin/env bash
#
# veracode-svn-scan.sh
# Pull code from SVN, package it with the Veracode CLI, and scan it.
#
# Usage:
#   ./veracode-svn-scan.sh -u <svn_url> -a <app_name> [options]
#
# Options:
#   -u  SVN URL (trunk, branch or tag)                          (required)
#   -a  Veracode application profile name                       (required for policy mode)
#   -r  SVN revision to scan (default: HEAD)
#   -m  Scan mode: pipeline | policy | both (default: pipeline)
#   -s  Also run an SCA agent scan (needs SRCCLR_API_TOKEN)
#   -w  Work directory (default: ./veracode-work)
#   -h  Show help
#
# Environment:
#   VERACODE_API_KEY_ID / VERACODE_API_KEY_SECRET   Veracode API creds (required)
#   SVN_USERNAME / SVN_PASSWORD                     SVN creds (optional)
#   VERACODE_WRAPPER_JAR                            Path to an existing VeracodeJavaAPI.jar (policy mode).
#                                                   If unset, the wrapper is downloaded from Maven Central.
#   VERACODE_WRAPPER_VERSION                        Wrapper version to download (default: latest release)
#   VERACODE_WRAPPER_REPO                           Maven repo to download from (default: Maven Central).
#                                                   Point at your Nexus/Artifactory proxy if needed.
#   VERACODE_TOOLS_DIR                              Where downloaded tools are kept between runs
#                                                   (default: ~/.cache/veracode-svn-scan)
#   SRCCLR_API_TOKEN                                SCA agent token (only with -s)
#   POLICY_SCAN_TIMEOUT                             Minutes to wait for policy scan (default: 60)
#
# Exit codes:
#   0  success, no blocking findings
#   1  usage or setup error
#   2  packaging failed
#   3  pipeline scan found flaws / failed
#   4  policy scan failed or did not pass policy
#   5  SCA scan failed

set -euo pipefail

# ---------- defaults ----------
SVN_URL=""
APP_NAME=""
SVN_REV="HEAD"
MODE="pipeline"
RUN_SCA=false
WORK_DIR="./veracode-work"
POLICY_SCAN_TIMEOUT="${POLICY_SCAN_TIMEOUT:-60}"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { echo "[ERROR] $*" >&2; exit "${2:-1}"; }

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# ---------- args ----------
while getopts "u:a:r:m:sw:h" opt; do
  case "$opt" in
    u) SVN_URL="$OPTARG" ;;
    a) APP_NAME="$OPTARG" ;;
    r) SVN_REV="$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    s) RUN_SCA=true ;;
    w) WORK_DIR="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -z "$SVN_URL" ]] && usage
[[ "$MODE" =~ ^(pipeline|policy|both)$ ]] || fail "Mode must be pipeline, policy or both"
[[ -z "${VERACODE_API_KEY_ID:-}" || -z "${VERACODE_API_KEY_SECRET:-}" ]] \
  && fail "VERACODE_API_KEY_ID and VERACODE_API_KEY_SECRET must be set"

if [[ "$MODE" != "pipeline" ]]; then
  [[ -z "$APP_NAME" ]] && fail "Policy mode needs an app name (-a)"
  if [[ -n "${VERACODE_WRAPPER_JAR:-}" && ! -f "$VERACODE_WRAPPER_JAR" ]]; then
    fail "VERACODE_WRAPPER_JAR is set but no file exists at $VERACODE_WRAPPER_JAR"
  fi
  command -v java >/dev/null || fail "java is required for policy mode"
fi

if $RUN_SCA; then
  [[ -z "${SRCCLR_API_TOKEN:-}" ]] && fail "SRCCLR_API_TOKEN must be set for SCA (-s)"
fi

command -v svn >/dev/null || fail "svn client not found"

# ---------- install CLI if missing ----------
if ! command -v veracode >/dev/null; then
  log "Veracode CLI not found, installing into $PWD"
  curl -fsS https://tools.veracode.com/veracode-cli/install | sh
  export PATH="$PWD:$PATH"
fi

# ---------- download Java API wrapper if needed (policy mode) ----------
if [[ "$MODE" != "pipeline" && -z "${VERACODE_WRAPPER_JAR:-}" ]]; then
  WRAPPER_REPO="${VERACODE_WRAPPER_REPO:-https://repo1.maven.org/maven2}"
  WRAPPER_BASE="${WRAPPER_REPO%/}/com/veracode/vosp/api/wrappers/vosp-api-wrappers-java"
  TOOLS_DIR="${VERACODE_TOOLS_DIR:-$HOME/.cache/veracode-svn-scan}"
  mkdir -p "$TOOLS_DIR"

  WRAPPER_VER="${VERACODE_WRAPPER_VERSION:-}"
  if [[ -z "$WRAPPER_VER" ]]; then
    WRAPPER_VER=$(curl -fsS "$WRAPPER_BASE/maven-metadata.xml" \
                  | sed -n 's:.*<release>\(.*\)</release>.*:\1:p') || true
    [[ -z "$WRAPPER_VER" ]] && fail "Could not find the latest Java API wrapper version at $WRAPPER_BASE"
  fi

  VERACODE_WRAPPER_JAR="$TOOLS_DIR/vosp-api-wrappers-java-$WRAPPER_VER.jar"

  if [[ -f "$VERACODE_WRAPPER_JAR" ]]; then
    log "Using cached Java API wrapper $WRAPPER_VER"
  else
    log "Downloading Java API wrapper $WRAPPER_VER into $TOOLS_DIR"
    JAR_URL="$WRAPPER_BASE/$WRAPPER_VER/vosp-api-wrappers-java-$WRAPPER_VER.jar"
    TMP_JAR="$VERACODE_WRAPPER_JAR.part"
    curl -fsSL -o "$TMP_JAR" "$JAR_URL" || { rm -f "$TMP_JAR"; fail "Could not download $JAR_URL"; }

    # Verify against the checksum Maven publishes next to the jar
    EXPECTED_SHA1=$(curl -fsS "$JAR_URL.sha1" | awk '{print $1}') || true
    if [[ -n "$EXPECTED_SHA1" ]]; then
      ACTUAL_SHA1=$(sha1sum "$TMP_JAR" | awk '{print $1}')
      if [[ "$ACTUAL_SHA1" != "$EXPECTED_SHA1" ]]; then
        rm -f "$TMP_JAR"
        fail "Checksum mismatch for the Java API wrapper (expected $EXPECTED_SHA1, got $ACTUAL_SHA1)"
      fi
    else
      log "Warning: no .sha1 checksum found, skipping verification"
    fi
    mv "$TMP_JAR" "$VERACODE_WRAPPER_JAR"
  fi
fi

# ---------- prep ----------
SRC_DIR="$WORK_DIR/src"
OUT_DIR="$WORK_DIR/verascan"
RESULTS_DIR="$WORK_DIR/results"
rm -rf "$WORK_DIR"
mkdir -p "$OUT_DIR" "$RESULTS_DIR"

SVN_AUTH=(--non-interactive)
if [[ -n "${SVN_USERNAME:-}" ]]; then
  SVN_AUTH+=(--username "$SVN_USERNAME" --password "${SVN_PASSWORD:-}" --no-auth-cache)
fi

# Resolve HEAD to an actual revision number so the scan is traceable
REV_NUM=$(svn info "${SVN_AUTH[@]}" -r "$SVN_REV" --show-item last-changed-revision "$SVN_URL")
log "Scanning $SVN_URL at r$REV_NUM"

# ---------- 1. export ----------
log "Exporting source"
svn export "${SVN_AUTH[@]}" -q -r "$REV_NUM" "$SVN_URL" "$SRC_DIR"

# ---------- 2. package ----------
log "Packaging with Veracode autopackager"
veracode package --source "$SRC_DIR" --output "$OUT_DIR" --trust \
  || fail "Packaging failed" 2

mapfile -t ARTIFACTS < <(find "$OUT_DIR" -maxdepth 1 -type f \
  \( -name '*.war' -o -name '*.jar' -o -name '*.ear' -o -name '*.zip' \))
[[ ${#ARTIFACTS[@]} -eq 0 ]] && fail "No artifacts produced in $OUT_DIR" 2
log "Artifacts: ${ARTIFACTS[*]##*/}"

EXIT_CODE=0

# ---------- 3a. pipeline scan ----------
if [[ "$MODE" == "pipeline" || "$MODE" == "both" ]]; then
  for art in "${ARTIFACTS[@]}"; do
    name=$(basename "$art")
    log "Pipeline scan: $name"
    if ! veracode static scan "$art" \
         --results-file "$RESULTS_DIR/pipeline-${name}.json"; then
      log "Pipeline scan reported findings or failed for $name"
      EXIT_CODE=3
    fi
  done
fi

# ---------- 3b. policy (Upload & Scan) ----------
if [[ "$MODE" == "policy" || "$MODE" == "both" ]]; then
  log "Policy scan (Upload and Scan) for '$APP_NAME', version svn-r$REV_NUM"
  if ! java -jar "$VERACODE_WRAPPER_JAR" \
        -vid "$VERACODE_API_KEY_ID" \
        -vkey "$VERACODE_API_KEY_SECRET" \
        -action UploadAndScan \
        -appname "$APP_NAME" \
        -createprofile false \
        -filepath "$OUT_DIR" \
        -version "svn-r$REV_NUM" \
        -scantimeout "$POLICY_SCAN_TIMEOUT" \
        -deleteincompletescan 2; then
    log "Policy scan failed or did not pass policy"
    EXIT_CODE=4
  fi
fi

# ---------- 4. SCA ----------
if $RUN_SCA; then
  log "SCA agent scan"
  if ! curl -sSL https://download.sourceclear.com/ci.sh \
       | sh -s -- scan "$SRC_DIR" --json "$RESULTS_DIR/sca.json"; then
    log "SCA scan failed"
    [[ $EXIT_CODE -eq 0 ]] && EXIT_CODE=5
  fi
fi

log "Done. Results in $RESULTS_DIR (exit $EXIT_CODE)"
exit "$EXIT_CODE"
