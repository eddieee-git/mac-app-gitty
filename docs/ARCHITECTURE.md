# Gitty 구조

Gitty를 고칠 사람을 위한 짧은 안내예요. SwiftUI 앱이고, git은 직접 구현하지 않고 시스템의 `git` 명령을 불러 써요.

## 큰 그림

```
GittyApp ─ ContentView ─┬─ WelcomeView (저장소 고르기, 첫 실행 안내)
                        └─ BrowserView ─┬─ LocalPaneView (왼쪽: 내 Mac)
                                        ├─ RepoPaneView  (오른쪽: Git 저장소)
                                        └─ LogPanel      (아래: 진행 로그)

AppModel (@MainActor, 화면 상태) ── GitRepo (actor, git 명령) ── Shell (Process 실행)
```

- **화면은 AppModel만 본다.** 버튼은 `AppModel`의 함수(`upload`, `delete`, `rename`, `undoLast` …)를 부르고, `AppModel`이 `GitRepo`를 부른다.
- **git 작업은 `GitRepo` actor 안에서 하나씩 순서대로** 실행된다. 동시에 두 git 명령이 돌지 않는다.
- **`AppModel.perform`이 모든 Git 작업의 틀이다**: 바쁨 표시 → 진행률 연결 → 작업 → 결과 메시지·오류 창 → 목록 다시 읽기 → 미전송 커밋 수 갱신 → (원하면) 되돌리기 목록에 넣고 push 예약.

## Git 작업의 흐름

1. 파일을 바꾼다 (복사, 삭제, `git mv` …).
2. `GitRepo.commit(_:paths:)`: **그 작업에서 건드린 경로만** `git add -A -- <경로>`로 올리고 커밋한다. `--literal-pathspecs`라서 이름에 `*`, `[` 가 있어도 그대로 쓴다. 클론 폴더에 사용자가 넣은 다른 파일은 커밋되지 않는다.
3. 커밋은 `takeLastCommit()`으로 `AppModel`이 가져가 **되돌리기 목록**(`undoStack`)에 넣는다. 되돌리기는 `git revert`라서 기록이 지워지지 않는다.
4. push는 바로 하지 않고 **2초 뒤 한 번에** 한다 (`schedulePush` → `flushPush`). 그사이 다른 작업이 오면 다시 기다린다. 앱을 끝낼 때(`applicationShouldTerminate`)와 저장소 목록으로 돌아갈 때 남은 push를 마저 한다.
5. push가 거절되면 `pull --rebase --autostash` 뒤 다시 시도한다. 충돌하면 rebase를 취소하고 알린다.

인증은 `-c credential.helper=!gh auth git-credential`로 GitHub CLI 로그인을 빌려 쓴다. 토큰을 따로 저장하지 않는다.

## 파일 역할

| 파일 | 하는 일 |
|---|---|
| `GittyApp.swift` | 앱·창·메뉴, 종료 처리 (남은 push, 받아 둔 업데이트 설치) |
| `AppModel.swift` | 화면 상태, 작업 틀(`perform`), push 모으기, 되돌리기, 변경 기록 |
| `GitRepo.swift` | git 명령: 클론, pull/push, 커밋, 업로드(LFS 포함), 이름 변경, 이동, 삭제, revert, 기록, 지난 버전 꺼내기 |
| `Shell.swift` | `Process` 실행, stderr를 줄 단위로 넘겨 진행률 표시, stdout을 파일로 받기 |
| `FileOps.swift` | `FileItem`, 폴더 목록 읽기, 검색(취소·한도), 복사·이동·휴지통 |
| `LocalBrowser.swift` | 왼쪽 패널 상태 (폴더 목록을 뒤에서 읽기) |
| `FolderTree.swift` | 폴더 트리, `FolderChildren`(하위 폴더를 뒤에서 읽어 기억) |
| `Places.swift` | Finder식 즐겨찾기·위치(Google Drive 등), Git 즐겨찾기 |
| `Components.swift` | 파일 목록 표(정렬), 끌어다 놓기(`FileDropHost`), 이름 입력 창 등 공용 화면 |
| `LocalPaneView.swift` / `RepoPaneView.swift` | 양쪽 패널 |
| `HistoryView.swift` | 변경 기록 창, Git 메뉴(되돌리기) |
| `SetupCheck.swift` | 첫 실행 안내 (git, gh 로그인, git-lfs) |
| `Updater.swift` / `UpdateView.swift` | 업데이트 확인·내려받기·서명 확인·설치, 알림 창 |
| `Log.swift`, `LogPanel.swift`, `LogView.swift` | 작업 기록 파일(토큰 가림), 진행 로그 |
| `Progress.swift` | 진행률 모으기 (0.1초에 한 번), git 진행 출력 해석 |

## 화면이 멈추지 않게

- 폴더 목록, 트리 하위 폴더, 검색은 모두 `Task.detached`로 뒤에서 읽는다. 읽는 사이 다른 폴더로 가면 `loadToken`으로 늦게 온 결과를 버린다.
- 검색은 부른 쪽 작업이 취소되면(검색어가 바뀌면) 바로 멈추고, 폴더 1만 개·깊이 12까지만 훑는다.

## 끌어다 놓기

SwiftUI `.onDrop`은 `Table`(NSTableView) 뒤에 깔려서 놓기를 받지 못한다. 그래서 `FileDropHost`가 AppKit 뷰(`FileDropView`)로 내용을 감싸 직접 받는다. 폴더 줄 위에 놓았는지는 줄 뒤에 숨겨 둔 `FolderMarkerView`로 알아낸다. 끌기가 어느 패널에서 시작됐는지는 `DragSession`이 기억해서, 같은 패널이면 이동, 다른 패널이면 복사로 처리한다.

## 업데이트

1. 6시간마다 GitHub `releases/latest`를 확인한다 (`updateFeedURL` 기본값으로 바꿔 시험할 수 있다).
2. 릴리스에는 `Gitty-x.y.z.dmg`와 `Gitty-x.y.z.dmg.sig`가 있어야 한다. `.sig`는 dmg의 Ed25519 서명이다.
3. 받은 dmg를 `Info.plist`의 `GittyUpdatePublicKey`로 확인하고, 맞지 않으면 버린다.
4. 기본은 알림 창에서 내려받아 dmg를 열어 준다. 자동 설치를 켜면 앱을 꺼내 두었다가 종료할 때 작은 셸 스크립트가 바꿔 끼운다(실패하면 이전 버전으로 되돌림).

서명 키 관리는 README의 "업데이트 서명"을 보세요.

## 시험과 배포

- `./scripts/test.sh`: 앱 소스와 `Tests/harness/main.swift`를 함께 컴파일해 돌린다. 로컬 bare 저장소를 원격으로 쓰므로 GitHub에 아무것도 보내지 않는다. (Command Line Tools만 있어도 되도록 XCTest를 쓰지 않는다.)
- `./scripts/build-app.sh`: arm64·x86_64를 따로 빌드해 합치고, 서명(ad-hoc)하고 dmg를 만든다.
- `./scripts/release.sh`: 빌드 → dmg 서명 → 태그 → GitHub 릴리스(dmg, .sig). 버전은 `Info.plist`, 노트는 `docs/releases/v<버전>.md`.
