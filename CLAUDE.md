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

## 지금 상태 (2026-11-19)

- GitHub 최신 릴리스는 **v0.2.2** (2026-11-15). 다음에 낼 버전은 **0.2.3**.
- `main`에는 0.2.2 뒤로 **아직 릴리스하지 않은 변경**이 있다 (0.2.3 릴리스 노트·CHANGELOG에 넣을 것):
  - `4fcafb8` 업데이트: 자동 설치를 기본으로, 직접 확인해도 묻지 않고 바로 설치 (공통 AppUpdater)
  - `f2b0bfb` 파일 더블클릭으로 반대쪽에 복사(내 폴더 → Git 올리기, Git → 내 폴더 받기; 폴더는 열기, 파일 열기는 Return)
- 릴리스 흐름: 0.1.0 → 0.1.1(드롭 업로드 수정, 탐색기 화면) → 0.1.2(자동 업데이트·서명, 되돌리기, 변경 기록) → 0.1.3(충돌 정리, 미리 보기) →
  0.1.4~0.1.6(Google Drive 내 드라이브) → 0.2.0(탭, 폴더 맞추기, 안전 경고, 취소, 영어 화면 등) → 0.2.1(업데이트 403) → 0.2.2(공통 AppUpdater, 문서 공통 틀).
- 확인한 것: `scripts/test.sh` 전부 통과, GitHub Actions 통과, 옛 업데이트 코드로 0.1.x → 0.2.1까지 실제 릴리스 자동 업데이트,
  화면은 화면 밖 렌더로 확인(가운데 단추, 아이콘 보기, 영어, 충돌 판, 기록 창, 첫 실행 안내).
- 확인하지 못한 것 (사용자가 써 보면서 확인할 것):
  - 실제 마우스 끌어다 놓기, 탭 여러 개에 저장소 여러 개, 실제 GitHub에 100MB 넘는 LFS 올리기, 큰 업로드 중 취소.
  - 사용자의 다른 Mac(Google Drive 미러링)에서 내 드라이브가 보이는지 — 0.1.6에서 고쳤지만 사용자 확인 전.
  - 공통 AppUpdater가 실제 릴리스로 스스로 업데이트하는 것 (0.2.3을 낼 때 처음 일어남).

### 사용자 환경에서 알게 된 것

- 다른 Mac은 Google Drive를 **미러링**으로 쓴다: 실제 파일은 `~/My Drive`, `~/Library/CloudStorage/GoogleDrive-…/My Drive`와 `~/Google Drive`는 바로가기(심볼릭 링크).
  계정 폴더 자체는 터미널에서도 "Operation not permitted". → `Places.googleMyDrives`가 바로가기를 풀어 실제 폴더 하나로 보여 준다. `FileItem.list`는 폴더가 바로가기면 실제 경로로 읽는다(URL로 읽으면 "Not a directory").
- 회사 네트워크라 GitHub API 로그인 없는 요청이 한도(시간당 60번)에 자주 걸린다(403). 업데이트 확인은 릴리스 페이지로 대신한다.

## 다음에 할 일

1. 사용자가 0.2.2를 써 보고 알려 주는 문제 고치기. 위 "확인하지 못한 것"을 먼저 봐 달라고 안내한다.
2. 0.2.3을 낼 때: 위 "릴리스 순서". 공통 AppUpdater로 0.2.2 → 0.2.3 자동 업데이트가 실제로 되는지 확인한다(`../mac-app/tests`의 e2e 업데이트 시험).
3. 시험 "반쯤 복사된 것은 치움"(0.03초 뒤 취소)이 GitHub Actions에서 가끔 실패한다. 타이밍 문제 — 복사가 시작된 걸 확인한 뒤 취소하도록 고친다.
4. README용 스크린샷 — 개인 내용이 찍힐 수 있어 사용자가 찍는다.

## 일하는 방식 (사용자와 정한 것)

- 답은 한국어로.
- **화면을 바꾸는 일은 먼저 시안을 보여 주고** 사용자가 정한 뒤 만든다.
- 커밋·릴리스는 사용자가 말할 때만. 보통 "먼저 써볼게요" → 써 본 뒤 "릴리스". 고친 것만 있으면 패치 버전(0.2.x)을 올린다.
- 고친 뒤에는 `./scripts/build-app.sh`로 만들고, 켜 둔 Gitty를 끝낸 다음 `build/Gitty.app`을 다시 열어 둔다(`open`만 하면 옛 앱이 앞으로 나올 뿐이다).
