---
name: pr-push
description: Check open GitHub PRs, merge locally on a release branch, run verification, bump the VERSION file, tag and publish a new version to main, and update the GitHub release notes. Use when releasing a new version or merging pending PRs with gh and git.
---

# Release PRs

**Goal:** Check open GitHub PRs, merge onto a release branch, verify, and publish a new version via `main`.

## Versioning (shared with `commit-push` and CONTEXT.md): Releases are **Git-Tag driven**, and the `VERSION` file mirrors the latest tag (it is what the Web UI displays). The `VERSION` file must be bumped and committed **before** tagging so the tag points at a tree where `VERSION == tag`. The tag must be pushed **before** the branch so CI's version-alignment check stays green on the release push.

## Steps

### 1. Check Open PRs
```bash
gh pr list --state open --json number,title,headRefName
```

### 2. Fetch Remote Branches and Tags
```bash
git fetch origin --tags
```

### 3. Create Release Branch
Create a branch from the latest `main`:
```bash
git checkout main
git pull origin main
git checkout -b release/vX.Y.Z
```

### 4. Review Each PR
For every open PR, review the full diff:
```bash
git diff origin/main...origin/<headRefName>
```
Verify each PR is not already in `main` and introduces no problems:
- **No secrets**: no tokens, credentials, or API keys hard-coded
- **No debug leftovers**: no stray `console.log(`, `debugger`, or unfinished `TODO`/`FIXME`
- **No deleted functionality**: removal of an element/function must be confirmed unused first
- **XSS safety**: user-controlled data must be properly escaped

Ignore version bumps and tooling directories if present.

### 5. Merge in Order
Merge each PR sequentially onto the release branch:
```bash
git merge origin/<headRefName> --no-edit
```

### 6. Determine Next Version
```bash
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
SUBJECT=$(git log -1 --format=%s)

# Semantic bump: breaking change ("!") → major, feat → minor, everything else → patch
NEW_VERSION=$(python3 -c '
import re, sys
maj, minor, patch = (int(x) for x in sys.argv[1].lstrip("vV").split("."))
m = re.match(r"([a-z]+)(\([^)]*\))?(!)?:", sys.argv[2])
bump = "major" if (m and m.group(3)) else ("minor" if (m and m.group(1) == "feat") else "patch")
if bump == "major": maj, minor, patch = maj + 1, 0, 0
elif bump == "minor": minor, patch = minor + 1, 0
else: patch += 1
print(f"v{maj}.{minor}.{patch}")
' "$LAST_TAG" "$SUBJECT")
```

### 7. Bump the VERSION File
This is the **only** place `VERSION` is changed during a release:
```bash
echo "$NEW_VERSION" > VERSION
```

### 8. Commit on Release Branch
```bash
git add -A
git commit -m "v$NEW_VERSION: merge PRs #A-B, summary

- Merge PR #A: short description
- Merge PR #B: short description
..."
```

### 9. Merge to Main
```bash
git checkout main
git merge release/vX.Y.Z --no-edit
git branch -d release/vX.Y.Z
```

### 10. Verify No Lingering Changes
```bash
git status --short
```
If files remain, stage and commit them:
```bash
git add -A
git commit -m "chore: prepare v$NEW_VERSION"
```

### 11. Tag and Push
Tag HEAD (which contains `VERSION == $NEW_VERSION`), then push the tag **before** the branch:
```bash
git tag "$NEW_VERSION"
git push origin "$NEW_VERSION"
git push origin main
```

### 12. Create/Update Release Notes
```bash
# Notes = commit subjects since the previous tag
NOTES=$(git log "$LAST_TAG"..HEAD --format='- %s')
gh release create "$NEW_VERSION" --title "$NEW_VERSION" --notes "$NOTES"
# To update an existing release:
# gh release edit "$NEW_VERSION" --notes "## What's Changed
# ### bullet points (Security / Performance / UX / Bugfix)
# ### Full Changelog: https://github.com/spupuz/debian-disk-cleanup/compare/$LAST_TAG...$NEW_VERSION"
```

### 12b. Close Merged PRs on GitHub
Close any PRs that are already merged and pushed to GitHub so they are no longer open:
```bash
# Close each merged PR
gh pr list --state merged --json number --jq '.[].number' | while read -r pr_number; do
  gh pr close "$pr_number" --comment "Auto-closed after release vX.Y.Z"
done
```

### 13. Report
"Released v$NEW_VERSION with N PRs merged."