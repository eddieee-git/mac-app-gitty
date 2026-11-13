#!/bin/zsh
# 동작 시험: 앱 소스(GittyApp.swift 제외)와 Tests/harness/main.swift를 함께 컴파일해서 돌린다.
# 로컬 bare 저장소를 원격으로 써서 GitHub에는 아무것도 보내지 않는다.
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d -t gitty-test)
trap 'rm -rf "$out"' EXIT
sources=(${(f)"$(ls Sources/Gitty/*.swift | grep -v GittyApp.swift)"})
swiftc -O -o "$out/gitty-test" $sources Tests/harness/main.swift \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Resources/Info.plist
mkdir -p "$out/work"
"$out/gitty-test" "$out/work"
