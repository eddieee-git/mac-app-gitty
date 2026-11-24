# Gitty 구조

Gitty를 고칠 사람을 위한 짧은 안내예요. SwiftUI 앱이고, git은 직접 구현하지 않고 시스템의 `git` 명령을 불러 써요.

## 큰 그림

```
GittyApp ─ MainWindow(창·탭마다 AppModel 하나) ─ ContentView ─┬─ WelcomeView (저장소 고르기, 첫 실행 안내)
                                                                └─ BrowserView ─┬─ LocalPaneView (왼쪽: 내 Mac)
                                                                                ├─ TransferBar   (가운데: ▶ ◀ 복사, ⇄ 맞추기)
                                                                                ├─ RepoPaneView  (오른쪽: Git 저장소)
                                                                                └─ LogPanel      (아래: 진행 로그)

AppModel (@MainActor, 화면 상태) ── GitRepo (actor, git 명령) ── Shell (Process 실행)
```

- **화면은 AppModel만 본다.** 버튼은 `AppModel`의 함수(`upload`, `delete`, `rename`, `undoLast` …)를 부르고, `AppModel`이 `GitRepo`를 부른다.
- **git 작업은 `GitRepo` actor 안에서 하나씩 순서대로** 실행된다. 동시에 두 git 명령이 돌지 않는다.
- **바쁠 때 온 작업은 거절하지 않고 줄을 선다** (`waitTurn`/`finishTurn`). 끝난 작업은 바쁨을 놓지 않고 다음 작업에 바로 넘겨서 끼어들기가 없다. 자동 동기화처럼 조용한 작업은 줄을 서지 않는다.
- **`AppModel.perform`이 모든 Git 작업의 틀이다**: 바쁨 표시 → 진행률 연결 → 작업 → 결과 메시지·오류 창 → 목록 다시 읽기 → 미전송 커밋 수 갱신 → (원하면) 되돌리기 목록에 넣고 push 예약.

## Git 작업의 흐름

1. 파일을 바꾼다 (복사, 삭제, `git mv` …).
2. `GitRepo.commit(_:paths:)`: **그 작업에서 건드린 경로만** `git add -A -- <경로>`로 올리고 커밋한다. `--literal-pathspecs`라서 이름에 `*`, `[` 가 있어도 그대로 쓴다. 클론 폴더에 사용자가 넣은 다른 파일은 커밋되지 않는다.
3. 커밋은 `takeLastCommit()`으로 `AppModel`이 가져가 **되돌리기 목록**(`undoStack`)에 넣는다. 되돌리기는 `git revert`라서 기록이 지워지지 않는다.
4. push는 바로 하지 않고 **2초 뒤 한 번에** 한다 (`schedulePush` → `flushPush`). 그사이 다른 작업이 오면 다시 기다린다. 앱을 끝낼 때(`applicationShouldTerminate`)와 저장소 목록으로 돌아갈 때 남은 push를 마저 한다.
5. push가 거절되면 `pull --rebase --autostash` 뒤 다시 시도한다.

### 충돌

rebase가 충돌하면 취소하고 `merge --no-ff`로 다시 합친다. 그래도 충돌하면 합치기를 열어 둔 채 `MergeConflictError`를 던지고, `AppModel.conflicts`에 담아 `ConflictPanel`을 띄운다(시트가 아니라 덮어 보여 준다. 시트는 앱 종료를 막는다). 충돌이 풀릴 때까지 다른 작업은 막는다.

- 내 것 / 원격 것: `ls-files -u`의 2번(내 쪽)·3번(원격) blob을 `cat-file --filters`로 꺼내 쓴다. 한쪽에서 지웠으면 지운다.
- 둘 다: 내 것은 그 자리에, 원격 것은 `이름 (원격).확장자`로 옆에 둔다.
- 나중에: `merge --abort`로 내 쪽 그대로 돌아간다. 다음 동기화 때 다시 묻는다.
- 앱을 껐다 켜도 `MERGE_HEAD`가 있으면 다시 묻는다.

인증은 `-c credential.helper=!gh auth git-credential`로 GitHub CLI 로그인을 빌려 쓴다. 토큰을 따로 저장하지 않는다.

## 파일 역할

| 파일 | 하는 일 |
|---|---|
| `GittyApp.swift` | 앱·창(`MainWindow`)·탭·메뉴, 종료 전에 남은 push 마치기 |
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
| `ConflictView.swift` | 충돌 정리 판 |
| `QuickLook.swift` | 스페이스바 미리 보기 |
| `RepoExtrasView.swift` | 저장소 용량 막대, Git 휴지통, 새 저장소, 커밋 메시지, 브랜치 메뉴 |
| `GitErrors.swift` | git 오류를 쉬운 말로 (오프라인·로그인·권한 등) |
| `Notifier.swift` | 오래 걸린 작업이 끝나면 macOS 알림 |
| `TransferBar.swift` | 가운데 복사(▶ ◀)·폴더 맞추기 단추 |
| `FolderSync.swift` / `SyncView.swift` | 두 폴더 비교와 맞추기 |
| `FileStatus.swift` | Git 쪽 파일 상태 표시 |
| `FileGrid.swift` | 아이콘(미리보기) 보기 |
| `FolderWatcher.swift` | 보고 있는 폴더가 바뀌면 다시 읽기 |
| `Cancellation.swift` | 작업 취소 (복사는 4MB마다 확인, git은 명령을 끊음) |
| `UploadSafety.swift` | 비밀 정보일 수 있는 파일 찾기 |
| `SplitAutosave.swift` | 칸 나눔 위치 기억 |
| `IconCache.swift` | 파일 아이콘 기억 |
| `Localization.swift` | 화면 글자 번역 `tr("…")` (영어는 `Resources/en.json`) |
| `SetupCheck.swift` | 첫 실행 안내 (git, gh 로그인, git-lfs) |
| `AppUpdater.swift` | 업데이트 확인·내려받기·확인·설치, 설정의 업데이트 칸. **다섯 앱 공통, 여기서 고치지 않음** |
| `UpdaterSetup.swift` | 공통 업데이트에 넣는 Gitty 값 (저장소, 공개 키, 지금 다시 시작해도 되는지) |
| `UpdateView.swift` | Gitty 메뉴의 "업데이트 확인…"과 창 위 알림 띠 |
| `AppAbout.swift` | 설정의 정보 칸 (버전, 링크, 다른 앱). **다섯 앱 공통** |
| `Log.swift`, `LogPanel.swift`, `LogView.swift` | 작업 기록 파일(토큰 가림), 진행 로그 |
| `Progress.swift` | 진행률 모으기 (0.1초에 한 번), git 진행 출력 해석 |

## 화면이 멈추지 않게

- 폴더 목록, 트리 하위 폴더, 검색은 모두 `Task.detached`로 뒤에서 읽는다. 읽는 사이 다른 폴더로 가면 `loadToken`으로 늦게 온 결과를 버린다.
- 검색은 부른 쪽 작업이 취소되면(검색어가 바뀌면) 바로 멈추고, 폴더 1만 개·깊이 12까지만 훑는다.

## 끌어다 놓기

SwiftUI `.onDrop`은 `Table`(NSTableView) 뒤에 깔려서 놓기를 받지 못한다. 그래서 `FileDropHost`가 AppKit 뷰(`FileDropView`)로 내용을 감싸 직접 받는다. 폴더 줄 위에 놓았는지는 줄 뒤에 숨겨 둔 `FolderMarkerView`로 알아낸다. 끌기가 어느 패널에서 시작됐는지는 `DragSession`이 기억해서, 같은 패널이면 이동, 다른 패널이면 복사로 처리한다.

## 업데이트

다섯 앱 공통 `AppUpdater.swift`가 한다(원본 `../mac-app/shared/AppUpdater.swift`, `../mac-app/scripts/sync-shared.sh`로 복사). Gitty에만 해당하는 값은 `UpdaterSetup.swift`.

1. 자동 확인(기본 켬): 켠 지 15초 뒤, 그 뒤 한 시간마다, 잠자기에서 깼을 때 "하루가 지났으면" GitHub `releases/latest`에 묻는다. API가 403·429로 막히면 릴리스 페이지 주소로 버전을 알아낸다.
2. 릴리스에는 `Gitty-x.y.z.dmg`와 `Gitty-x.y.z.dmg.sig`(Ed25519 서명)가 있어야 한다. 받은 dmg는 서명·GitHub SHA-256으로, 바꿔 넣기 전에 번들 ID·버전·코드 서명으로 확인한다.
3. 새 버전을 찾으면 Gitty 메뉴 항목이 "새 버전 X 설치…"로 바뀌고 창 위에 알림 띠가 뜬다. 자동 설치(기본 끔)는 올리는 중이거나 남은 push가 없을 때만 바꿔 넣고 다시 켠다(`canRestartNow`).

서명 키 관리는 [CLAUDE.md](../CLAUDE.md)의 "업데이트"를 보세요.

## 화면 글자 번역

화면에 보이는 한국어는 모두 `tr("…")`로 감싼다. 끼워 넣은 값은 키에서 `{}`가 된다(`tr("‘\(name)’ 폴더를 만들었어요")` → 키 `‘{}’ 폴더를 만들었어요`, 영어 `Created folder ‘{}’`). 영어는 `Resources/en.json`에 있고, 번역이 없으면 한국어 그대로 보인다. 작업 기록(로그)은 번역하지 않는다.

- `python3 scripts/l10n.py keys`: 빠진 번역을 알려 준다 (빠지면 실패).
- `python3 scripts/l10n.py wrap`: 새로 쓴 한국어 글자를 `tr()`로 감싼다. 파일 이름처럼 번역하면 안 되는 글자는 그 줄(또는 바로 윗줄)에 `// no-tr`.

## 창과 탭

창(탭)마다 `MainWindow`가 자기 `AppModel`을 가진다. 같은 클론을 여러 탭에서 열어도 `GitRepo.shared(for:)`로 actor 하나를 함께 써서 git 작업이 겹치지 않는다. 메뉴 명령은 `FocusedValues.appModel`로 앞에 있는 창의 모델을 쓴다.

## 시험과 배포

- `./scripts/test.sh`: 앱 소스와 `Tests/harness/main.swift`를 함께 컴파일해 돌린다. 로컬 bare 저장소를 원격으로 쓰므로 GitHub에 아무것도 보내지 않는다. (Command Line Tools만 있어도 되도록 XCTest를 쓰지 않는다.)
- `./scripts/build-app.sh`: arm64·x86_64를 따로 빌드해 합치고, 서명(ad-hoc)하고 dmg를 만든다.
- `./scripts/release.sh`: 빌드 → dmg 서명 → 태그 → GitHub 릴리스(dmg, .sig). 버전은 `Info.plist`, 노트는 `docs/releases/v<버전>.md`.
- GitHub Actions(`.github/workflows/test.yml`): push마다 `swift build`, `scripts/test.sh`, `scripts/l10n.py keys`(번역 빠짐)를 돌린다.

## 화면 확인 (사람 손 없이)

마우스로 눌러 볼 수 없을 때 쓰는 방법이다. 앱 소스(GittyApp.swift 빼고)와 작은 `main.swift`를 함께 `swiftc`로 컴파일해서, `NSHostingView`를 화면 밖 창에 띄우고 `cacheDisplay`로 PNG를 만든다.

- 창은 `orderFrontRegardless()`로 실제로 띄워야 다시 그려진다 (화면 밖 좌표 `-4000, -4000`).
- 기다릴 때 `RunLoop.run`이 아니라 `await Task.sleep`을 쓴다. 메인 스레드를 막으면 비동기 결과(기록·트리)가 안 들어온다.
- 키 입력은 `NSEvent.keyEvent`로 만들어 `window.sendEvent`.
- 영어 화면: 실행 파일 옆에 `en.json`을 두고 `appLanguage`를 `en`으로.
