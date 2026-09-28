#!/usr/bin/env bash
set -euo pipefail

REF="$1"
ENVNAME="$2"
BRANCH="deploy/${ENVNAME}"
TOKEN="${MANIFEST_PUSH_TOKEN:-${GITHUB_TOKEN:-}}"

if [ -z "$TOKEN" ]; then
  echo "WARN: no MANIFEST_PUSH_TOKEN/GITHUB_TOKEN; bump of ${BRANCH} skipped"
  exit 0
fi

git remote set-url origin "https://x-access-token:${TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
git fetch -q origin

if git ls-remote --exit-code origin "refs/heads/${BRANCH}" >/dev/null 2>&1; then
  git checkout -q -B "${BRANCH}" "origin/${BRANCH}"
else
  git checkout -q --orphan "${BRANCH}"
  git rm -rf --quiet . 2>/dev/null || true
fi

mkdir -p "deploy/${ENVNAME}"
printf 'ref: %s\n' "$REF" > "deploy/${ENVNAME}/ref.yaml"
git add "deploy/${ENVNAME}/ref.yaml"
git -c user.name="dbt-cicd-bot" -c user.email="actions@github.com" \
  commit -q -m "bump ${ENVNAME} manifest ref to ${REF}"
git push -q origin "${BRANCH}"
echo "BUMPED ${BRANCH} -> ${REF}"