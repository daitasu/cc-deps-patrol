#!/usr/bin/env bash
set -euo pipefail

# Verify npm supply-chain trust signals for dependencies updated in a
# Dependabot PR.  Checks three signals:
#
#   1. npm provenance  – Sigstore attestation (proves CI/CD origin)
#   2. Install scripts – postinstall / preinstall / install (malware vector)
#   3. Release age     – days since publication (informational)
#
# Required env vars:
#   DEPENDENCY_NAMES   – Comma-separated dependency names (from fetch-metadata)
#   PACKAGE_ECOSYSTEM  – e.g. "npm_and_yarn" (from fetch-metadata)
#   GH_TOKEN           – GitHub token (unused here, but set in the env)
#
# Optional env vars:
#   UPDATED_DEPENDENCIES_JSON – Per-dependency name/prevVersion/newVersion array
#                               (from fetch-metadata).  Required to check the
#                               versions the PR actually bumps to; without it
#                               grouped PRs fall back to npm's "latest", which
#                               is not what the PR contains.
#   NEW_VERSION        – New version for single-dep PRs (from fetch-metadata)
#   PREVIOUS_VERSION   – Previous version for single-dep PRs (from fetch-metadata)
#
# Outputs (via $GITHUB_OUTPUT):
#   provenance-result  – pass | warn | fail | skip
#   provenance-report  – Markdown report (multi-line)

echo "::group::Supply-chain trust check"

# ── Helper: days between an ISO-8601 date and now ──
days_ago() {
  local published="$1"
  if [[ -z "$published" ]]; then
    echo "unknown"
    return
  fi
  local pub_epoch now_epoch
  pub_epoch=$(date -u -d "$published" +%s 2>/dev/null) \
    || pub_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "${published%%.*}" +%s 2>/dev/null) \
    || { echo "unknown"; return; }
  now_epoch=$(date -u +%s)
  echo $(( (now_epoch - pub_epoch) / 86400 ))
}

# ── Helper: extract install-related script names from an npm scripts JSON ──
install_scripts() {
  local scripts_json="$1"
  echo "$scripts_json" | jq -r 'keys[]' 2>/dev/null \
    | grep -E '^(preinstall|install|postinstall)$' || true
}

# ── Non-npm ecosystem → skip ──
if [[ "${PACKAGE_ECOSYSTEM:-}" != "npm_and_yarn" ]]; then
  echo "::notice::Ecosystem '${PACKAGE_ECOSYSTEM:-unknown}' — skipping npm provenance check"
  echo "provenance-result=skip" >> "$GITHUB_OUTPUT"
  DELIM="PROVENANCE_REPORT_$(date +%s)"
  {
    echo "provenance-report<<${DELIM}"
    echo "Provenance check skipped (ecosystem: ${PACKAGE_ECOSYSTEM:-unknown})."
    echo "${DELIM}"
  } >> "$GITHUB_OUTPUT"
  echo "::endgroup::"
  exit 0
fi

# ── npm availability check ──
if ! command -v npm &>/dev/null; then
  echo "::warning::npm CLI not found — skipping provenance check"
  echo "provenance-result=skip" >> "$GITHUB_OUTPUT"
  DELIM="PROVENANCE_REPORT_$(date +%s)"
  {
    echo "provenance-report<<${DELIM}"
    echo "Provenance check skipped (npm CLI not available)."
    echo "${DELIM}"
  } >> "$GITHUB_OUTPUT"
  echo "::endgroup::"
  exit 0
fi

# ── Parse dependencies as "name<TAB>newVersion<TAB>prevVersion" rows ──
# updated-dependencies-json carries the versions the PR actually bumps to, for
# every dependency in the PR.  Grouped Dependabot PRs contain several
# dependencies, so the single-dep NEW_VERSION / PREVIOUS_VERSION cannot cover
# them.
DEP_ROWS=$(printf '%s' "${UPDATED_DEPENDENCIES_JSON:-}" \
  | jq -r '.[] | [.dependencyName, .newVersion // "", .prevVersion // ""] | @tsv' 2>/dev/null \
  || true)

# Fallback: names only.  Versions are known only when the PR has a single dep.
if [[ -z "$DEP_ROWS" ]]; then
  echo "::warning::updated-dependencies-json unavailable — falling back to dependency names"
  IFS=', ' read -ra NAMES <<< "${DEPENDENCY_NAMES:-}"
  # ${NAMES[@]} on an empty array trips `set -u` under bash 3.2, so guard it.
  for name in ${NAMES[@]+"${NAMES[@]}"}; do
    [[ -z "$name" ]] && continue
    if [[ ${#NAMES[@]} -eq 1 ]]; then
      DEP_ROWS+="${name}"$'\t'"${NEW_VERSION:-}"$'\t'"${PREVIOUS_VERSION:-}"$'\n'
    else
      DEP_ROWS+="${name}"$'\t'$'\t'$'\n'
    fi
  done
fi

if [[ -z "$DEP_ROWS" ]]; then
  echo "::warning::No dependency names provided — skipping"
  echo "provenance-result=skip" >> "$GITHUB_OUTPUT"
  DELIM="PROVENANCE_REPORT_$(date +%s)"
  {
    echo "provenance-report<<${DELIM}"
    echo "Provenance check skipped (no dependencies detected)."
    echo "${DELIM}"
  } >> "$GITHUB_OUTPUT"
  echo "::endgroup::"
  exit 0
fi

# ── Check each dependency ──
RESULT="pass"      # overall: pass → warn → fail
REPORT_ROWS=""
ISSUES=""
TOTAL=0
PROVENANCE_OK=0

while IFS=$'\t' read -r dep VERSION PREV_VERSION; do
  [[ -z "$dep" ]] && continue
  TOTAL=$((TOTAL + 1))

  echo "── Checking: ${dep} ──"

  # An unresolved version means the checks below would inspect some other
  # release than the one this PR installs, so treat it as a blocking failure
  # rather than merging on an unverified package.
  if [[ -z "$VERSION" ]]; then
    echo "  🚫 Could not resolve the version this PR bumps to"
    REPORT_ROWS+="| \`${dep}\` | - | 🚫 Unknown | - | - |"$'\n'
    ISSUES+="- \`${dep}\`: could not determine the version this PR installs — checks did not run"$'\n'
    RESULT="fail"
    continue
  fi
  echo "  Version: ${VERSION}"

  # ── 1. Provenance attestation ──
  PKG_ENCODED=$(printf '%s' "$dep" | sed 's|/|%2F|g')
  ATTESTATION_URL="https://registry.npmjs.org/-/npm/v1/attestations/${PKG_ENCODED}@${VERSION}"
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ATTESTATION_URL" 2>/dev/null || echo "000")

  PROV_LABEL=""
  if [[ "$HTTP_STATUS" == "200" ]]; then
    PROV_LABEL="✅ Verified"
    PROVENANCE_OK=$((PROVENANCE_OK + 1))
    echo "  ✅ Provenance attestation found"
  else
    PROV_LABEL="⚠️ Not found"
    [[ "$RESULT" == "pass" ]] && RESULT="warn"
    ISSUES+="- \`${dep}@${VERSION}\`: No provenance attestation"$'\n'
    echo "  ⚠️ No provenance attestation (HTTP ${HTTP_STATUS})"
  fi

  # ── 2. Install scripts ──
  NEW_SCRIPTS_JSON=$(npm view "${dep}@${VERSION}" scripts --json 2>/dev/null || echo "{}")
  NEW_INSTALL=$(install_scripts "$NEW_SCRIPTS_JSON")

  SCRIPTS_LABEL="✅ None"
  SCRIPTS_NEW=false

  if [[ -n "$NEW_INSTALL" ]]; then
    # Check if these scripts existed in the previous version
    if [[ -n "$PREV_VERSION" ]]; then
      OLD_SCRIPTS_JSON=$(npm view "${dep}@${PREV_VERSION}" scripts --json 2>/dev/null || echo "{}")
      OLD_INSTALL=$(install_scripts "$OLD_SCRIPTS_JSON")

      for script_name in $NEW_INSTALL; do
        if ! echo "$OLD_INSTALL" | grep -qx "$script_name"; then
          SCRIPTS_NEW=true
          break
        fi
      done
    else
      # Cannot compare — flag the presence of install scripts
      SCRIPTS_NEW=true
    fi

    SCRIPT_LIST=$(echo "$NEW_INSTALL" | paste -sd ',' - | sed 's/,/, /g')
    if [[ "$SCRIPTS_NEW" == "true" ]]; then
      SCRIPTS_LABEL="⚠️ ${SCRIPT_LIST} (NEW)"
      RESULT="fail"
      ISSUES+="- \`${dep}@${VERSION}\`: New install script detected: ${SCRIPT_LIST}"$'\n'
      echo "  ⚠️ Install scripts (NEW): ${SCRIPT_LIST}"
    else
      SCRIPTS_LABEL="ℹ️ ${SCRIPT_LIST} (existing)"
      echo "  ℹ️ Install scripts (existing): ${SCRIPT_LIST}"
    fi
  else
    echo "  ✅ No install scripts"
  fi

  # ── 3. Release age ──
  PUBLISHED=$(npm view "${dep}" time --json 2>/dev/null \
    | jq -r ".[\"${VERSION}\"] // empty" 2>/dev/null || echo "")
  AGE=$(days_ago "$PUBLISHED")

  if [[ "$AGE" == "unknown" ]]; then
    AGE_LABEL="unknown"
  else
    AGE_LABEL="${AGE} days ago"
    echo "  📅 Published: ${AGE_LABEL}"
  fi

  # ── Build table row ──
  REPORT_ROWS+="| \`${dep}\` | ${VERSION} | ${PROV_LABEL} | ${SCRIPTS_LABEL} | ${AGE_LABEL} |"$'\n'
done <<< "$DEP_ROWS"

echo "══════════════════"
echo "Result: ${RESULT} (${PROVENANCE_OK}/${TOTAL} provenance verified)"

# ── Build full markdown report ──
REPORT="### 🔍 Supply Chain Trust Check"$'\n'$'\n'
REPORT+="| Package | Version | Provenance | Install Scripts | Published |"$'\n'
REPORT+="|---------|---------|------------|-----------------|-----------|"$'\n'
REPORT+="${REPORT_ROWS}"$'\n'

case "$RESULT" in
  pass)
    REPORT+="✅ **All ${TOTAL} packages passed supply-chain checks.**"$'\n'
    ;;
  warn)
    REPORT+="⚠️ **Warnings found** (${PROVENANCE_OK}/${TOTAL} provenance verified):"$'\n'$'\n'
    REPORT+="${ISSUES}"
    ;;
  fail)
    REPORT+="🚫 **Issues found** — manual review recommended:"$'\n'$'\n'
    REPORT+="${ISSUES}"
    ;;
esac

# ── Output results ──
echo "provenance-result=${RESULT}" >> "$GITHUB_OUTPUT"
DELIM="PROVENANCE_REPORT_$(date +%s)"
{
  echo "provenance-report<<${DELIM}"
  echo "$REPORT"
  echo "${DELIM}"
} >> "$GITHUB_OUTPUT"

echo "::endgroup::"
