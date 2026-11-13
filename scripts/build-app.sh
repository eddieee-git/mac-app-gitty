#!/bin/zsh
# build/Gitty.app과 배포용 build/Gitty-<버전>.dmg를 만든다. Xcode 없이 Command Line Tools만으로 빌드한다.
# Apple 실리콘과 Intel Mac 모두에서 돌아가는 유니버설 앱을 만든다.
set -e
cd "$(dirname "$0")/.."

# 아키텍처별로 빌드한 뒤 lipo로 합친다 (여러 --arch를 한 번에 쓰려면 Xcode가 필요해서)
for arch in arm64 x86_64; do
    swift build -c release --triple $arch-apple-macosx14.0
done

app=build/Gitty.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create -output "$app/Contents/MacOS/Gitty" \
    .build/arm64-apple-macosx/release/Gitty \
    .build/x86_64-apple-macosx/release/Gitty
cp Resources/Info.plist "$app/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# 임시 서명. 서명 조건을 번들 ID로 지정해서 다시 빌드해도 같은 앱으로 인식되게 한다.
codesign --force --sign - -r='designated => identifier "com.eddieee.Gitty"' "$app"

# 내려받은 쪽에서 응용 프로그램 폴더로 끌어다 놓을 수 있게 바로가기를 함께 넣는다.
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
dmg="build/Gitty-$version.dmg"
staging=build/dmg
rm -rf "$staging" "$dmg"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname Gitty -srcfolder "$staging" -format UDZO "$dmg"
rm -rf "$staging"

echo "$app"
echo "$dmg"
