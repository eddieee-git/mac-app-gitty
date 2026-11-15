> 문서·UI 규칙은 ../mac-app/STYLE.md를 따른다. 다르게 할 때는 여기에 이유를 적는다.

# Gitty 개발 메모

Git 저장소를 파일 관리자처럼 다루는 macOS 앱. Swift Package 실행 파일 하나로, Xcode 없이 Command Line Tools만으로 빌드한다.
macOS 14 이상, Apple 실리콘과 Intel. 저장소: `eddieee-git/mac-app-gitty` (공개). 번들 ID `com.eddieee.Gitty`.
구조는 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## 지켜야 할 것

- **Apple 계정이 필요한 기능은 만들지 않는다.** 공증, Developer ID 서명 등.
- 사용자 문구는 한국어로 쓰고 `tr("…")`로 감싼다. 영어는 `Resources/en.json`. 말투는 "~해요".
- 문서는 README·CHANGELOG 한/영 두 벌.
- **스크린샷에 개인 내용(저장소·파일 이름)이 나오지 않게 한다.**

## STYLE.md와 다른 점

- Dock 앱이라 메뉴바 메뉴 대신 앱 메뉴(Gitty → 업데이트 확인…)와 창 위 알림 띠를 쓴다.
- 로그인 시 실행은 없다(창을 여는 앱이라 맞지 않음).
- 문구 함수는 `L(…)`가 아니라 `tr(…)`다. 끼워 넣는 값을 문자열 보간으로 쓰는 방식이라 그대로 둔다.
- Intel Mac도 지원한다(universal 빌드).

## 명령

```bash
./scripts/test.sh           # 동작 시험 (로컬 bare 저장소로, GitHub에 아무것도 안 보냄)
./scripts/build-app.sh      # build/Gitty.app + build/Gitty-<버전>.dmg
./scripts/release.sh        # 태그를 달고 GitHub 릴리스에 dmg와 서명(.sig) 첨부
./scripts/make-icon.sh      # 앱 아이콘 다시 그리기 (Resources/AppIcon.icns, docs/images/icon.png)
python3 scripts/l10n.py     # 번역 빠진 문구 찾기
```

## 업데이트

- 업데이트 코드는 다섯 앱 공통 `Sources/Gitty/AppUpdater.swift`다. **여기서 고치지 않는다.** 원본은 `../mac-app/shared/AppUpdater.swift`이고
  `../mac-app/scripts/sync-shared.sh`로 복사한다. Gitty에만 해당하는 값은 `UpdaterSetup.swift`에 있다.
- 공개 키는 `Resources/Info.plist`의 `GittyUpdatePublicKey`, 비밀 키는 릴리스하는 Mac의 로그인 키체인("Gitty Update Signing")에만 있다.
  서명 파일이 없거나 맞지 않는 릴리스는 설치하지 않는다.

```bash
swift scripts/update-signing.swift public-key   # 키체인의 키로 공개 키 확인
swift scripts/update-signing.swift keygen       # 새 키 만들기 (처음 한 번)
swift scripts/update-signing.swift export ~/Desktop/gitty-key.txt   # 백업 (비밀번호 관리자에 옮기고 파일은 지우기)
swift scripts/update-signing.swift import ~/Desktop/gitty-key.txt   # 다른 Mac에서 릴리스할 때 키체인에 넣기
```

비밀 키를 잃어버리면 새 키를 넣은 버전을 사용자가 한 번 직접 설치해야 한다. 꼭 백업해 둔다.

## 릴리스 순서

1. `Resources/Info.plist`의 `CFBundleShortVersionString`(그리고 `CFBundleVersion`)을 올린다.
2. `docs/releases/v<버전>.md`에 릴리스 노트를 쓴다(설치와 업데이트 → 새 기능 → 바뀐 점 → 고친 점 → 알려진 제한 → `## English`).
3. `CHANGELOG.md`와 `CHANGELOG.en.md` 맨 위에 그 버전을 더한다.
4. `./scripts/test.sh` → `./scripts/release.sh`.
