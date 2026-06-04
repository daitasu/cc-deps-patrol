#!/usr/bin/env bash
set -euo pipefail

# Approve and merge a Dependabot PR based on provenance-check results,
# or post a comment explaining why the merge was blocked.
#
# Required env vars:
#   GH_TOKEN            – GitHub token with PR write permissions
#   PR_URL              – Full URL of the pull request
#   PR_NUMBER           – Pull request number
#   PROVENANCE_RESULT   – pass | warn | fail | skip (from verify-provenance.sh)
#   PROVENANCE_REPORT   – Markdown report       (from verify-provenance.sh)

echo "::group::Verify-and-merge gate"

case "${PROVENANCE_RESULT}" in
  pass|skip)
    echo "✅ Provenance check ${PROVENANCE_RESULT} — approving and merging"
    gh pr review "$PR_URL" --approve \
      --body "🤖 Supply-chain check passed — auto-approved by cc-deps-patrol."
    gh pr merge "$PR_URL" --merge
    echo "merged=true" >> "$GITHUB_OUTPUT"
    ;;
  warn)
    echo "⚠️ Provenance check has warnings — approving with report and merging"
    BODY=$(cat <<EOF
🤖 Supply-chain check completed with warnings — auto-approved by cc-deps-patrol.

${PROVENANCE_REPORT}
EOF
    )
    gh pr review "$PR_URL" --approve --body "$BODY"
    gh pr merge "$PR_URL" --merge
    echo "merged=true" >> "$GITHUB_OUTPUT"
    ;;
  fail)
    echo "🚫 Provenance check failed — posting report, skipping merge"
    BODY=$(cat <<EOF
🚫 **Auto-merge blocked** — supply-chain trust check detected issues.

${PROVENANCE_REPORT}

Manual review is required before this PR can be merged.
EOF
    )
    gh pr comment "$PR_NUMBER" -b "$BODY"
    echo "merged=false" >> "$GITHUB_OUTPUT"
    ;;
  *)
    echo "::error::Unknown provenance result: ${PROVENANCE_RESULT}"
    exit 1
    ;;
esac

echo "::endgroup::"
