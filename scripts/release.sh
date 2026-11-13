#!/bin/zsh
# GitHub 릴리스를 만든다: 빌드(dmg) → 태그 → 릴리스에 dmg 첨부.
# 버전은 Resources/Info.plist의 CFBundleShortVersionString을 쓴다. 릴리스 노트는 docs/releases/v<버전>.md.
# 사용: ./scripts/release.sh
set -e
cd "$(dirname "$0")/.."

version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
tag="v$version"
notes="docs/releases/$tag.md"

if [[ ! -f "$notes" ]]; then
    echo "릴리스 노트가 없어요: $notes"
    exit 1
fi
if git rev-parse "$tag" >/dev/null 2>&1; then
    echo "이미 있는 태그예요: $tag (Info.plist의 버전을 올려 주세요)"
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "커밋하지 않은 변경이 있어요. 먼저 커밋해 주세요."
    exit 1
fi

./scripts/build-app.sh

git tag -a "$tag" -m "Gitty $version"
git push origin "$tag"
gh release create "$tag" "build/Gitty-$version.dmg" --title "Gitty $version" --notes-file "$notes"
echo "릴리스를 만들었어요: $tag"
