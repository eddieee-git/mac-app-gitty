// 이 파일은 mac-app/shared/AppAbout.swift가 원본이에요.
// 앱 저장소에서 직접 고치지 말고, 원본을 고친 뒤 mac-app/scripts/sync-shared.sh로 다섯 앱에 복사해요.

import AppKit
import SwiftUI

/// 같은 사람이 만든 앱 묶음. 설정의 "정보"에서 서로를 알려 줘요.
/// 앱이 늘거나 소개 문구가 바뀌면 여기와 mac-app/scripts/apply-common-docs.py의 APPS를 함께 고쳐요.
enum AppFamily {
    struct Member: Identifiable {
        let name: String
        let ko: String
        let en: String
        var id: String { name }
        var repo: String { "mac-app-" + name.lowercased() }
        var url: URL { URL(string: "https://github.com/\(AppFamily.owner)/\(repo)")! }
    }

    static let owner = "eddieee-git"
    static let members = [
        Member(name: "Clocky", ko: "넘김시계 타이머·알람·일정 알림", en: "Flip-clock timers, alarms and calendar alerts"),
        Member(name: "Floaty", ko: "플로팅 스티커 메모", en: "Floating sticky notes"),
        Member(name: "Gitty", ko: "Git 저장소를 파일 관리자처럼", en: "Git repositories like a file manager"),
        Member(name: "Grabby", ko: "찍고, 그리고, 바로 붙여 넣는 화면 캡처", en: "Capture, mark up and paste"),
        Member(name: "Keepy", ko: "복사한 내용을 모아 두고 다시 붙여 넣는 클립보드 기록", en: "Clipboard history to paste again"),
        Member(name: "Mdy", ko: "더블클릭으로 바로 여는 마크다운 뷰어 겸 편집기", en: "Markdown viewer and editor that opens with a double-click"),
        Member(name: "Peeky", ko: "노치에 가려진 메뉴바 아이콘 꺼내 보기", en: "Menu bar icons hidden behind the notch"),
    ]

    static func others(than name: String) -> [Member] { members.filter { $0.name != name } }
    static func member(_ name: String) -> Member { members.first { $0.name == name } ?? members[0] }
}

/// 설정 창의 "정보". `Form` 안에 그대로 넣어요(탭이 있는 앱은 "정보" 탭의 Form, 한 장짜리 설정은 맨 아래).
struct AppAboutSections: View {
    let appName: String
    let english: Bool

    private func t(_ ko: String, _ en: String) -> String { english ? en : ko }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-" }

    var body: some View {
        let me = AppFamily.member(appName)
        Section(t("정보", "About")) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appName).font(.headline)
                    Text(t("버전 \(version)", "Version \(version)")).foregroundStyle(.secondary)
                    Text(english ? me.en : me.ko).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 16) {
                Link("GitHub", destination: me.url)
                Link(t("변경 기록", "Changelog"), destination: me.url.appendingPathComponent("releases"))
                Link(t("문제 알리기", "Report a problem"), destination: me.url.appendingPathComponent("issues/new/choose"))
            }
            .font(.callout)
        }
        Section(t("다른 앱", "More apps")) {
            ForEach(AppFamily.others(than: appName)) { app in
                Link(destination: app.url) {
                    HStack {
                        Text(app.name).fontWeight(.medium)
                        Text(english ? app.en : app.ko).foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(app.name), \(english ? app.en : app.ko)")
            }
        }
    }
}

/// 이미 자기 "정보" 화면이 있는 앱(Grabby)에 넣는 한 줄: 다른 앱: Clocky · Floaty · …
struct AppFamilyLinks: View {
    let appName: String
    let english: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(english ? "More apps:" : "다른 앱:").foregroundStyle(.secondary)
            ForEach(AppFamily.others(than: appName)) { app in
                Link(app.name, destination: app.url)
                    .help(english ? app.en : app.ko)
            }
        }
        .font(.callout)
    }
}
