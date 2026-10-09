#!/bin/bash
#==============================================================================
# k16-redesign PR 作成スクリプト
#
# このスクリプトは GitHub CLI (gh) を使って fork → push → PR 作成まで
# 自動実行します。実行前に:
#
#   1. gh CLI をインストール: https://cli.github.com/
#   2. 認証: gh auth login
#   3. upstream (kin-main/k16-16bitcpu) にアクセスできる GitHub アカウント
#
# 実行方法:
#   cd k16-redesign
#   bash scripts/create_pr.sh
#==============================================================================

set -e

UPSTREAM="kin-main/k16-16bitcpu"
BRANCH="sync-ram-redesign"
PR_TITLE="feat: 同期BRAM対応 再設計 (Tang Nano 9K向け)"
PR_BODY_FILE="PULL_REQUEST.md"

# Check gh CLI
if ! command -v gh &> /dev/null; then
    echo "ERROR: GitHub CLI (gh) がインストールされていません"
    echo "  https://cli.github.com/ からインストールしてください"
    exit 1
fi

# Check auth
if ! gh auth status &> /dev/null; then
    echo "ERROR: gh auth が未認証です"
    echo "  gh auth login を実行してください"
    exit 1
fi

# Check current branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
    echo "ERROR: 現在のブランチが $BRANCH ではありません ($CURRENT_BRANCH)"
    exit 1
fi

echo "=== Status ==="
git status
echo ""

# Fork upstream if not already forked
echo "=== Checking fork ==="
USERNAME=$(gh api user --jq .login)
FORK_REPO="${USERNAME}/k16-16bitcpu"

if gh repo view "$FORK_REPO" &> /dev/null; then
    echo "Fork already exists: $FORK_REPO"
else
    echo "Creating fork of $UPSTREAM..."
    gh repo fork "$UPSTREAM" --clone=false
    echo "Fork created: $FORK_REPO"
    # Wait for fork to be ready
    sleep 5
fi

# Add fork as origin remote
echo ""
echo "=== Adding origin remote ==="
if git remote get-url origin &> /dev/null; then
    git remote set-url origin "https://github.com/${FORK_REPO}.git"
else
    git remote add origin "https://github.com/${FORK_REPO}.git"
fi
git remote -v

# Push to fork
echo ""
echo "=== Pushing to fork ==="
git push -u origin "$BRANCH"

# Create PR
echo ""
echo "=== Creating PR ==="
gh pr create \
    --repo "$UPSTREAM" \
    --head "${USERNAME}:${BRANCH}" \
    --base main \
    --title "$PR_TITLE" \
    --body-file "$PR_BODY_FILE"

echo ""
echo "=== Done ==="
echo "PR created. Check: https://github.com/$UPSTREAM/pulls"
