import SwiftUI

// 每次重编 +1，表上能一眼确认是不是刷新过
let APP_BUILD = "v10"

@main
struct WatchAssistantApp: App {
  var body: some Scene {
    WindowGroup { ContentView() }
  }
}

struct ContentView: View {
  @StateObject private var a = Assistant()
  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      switch a.screen {
      case .home:      HomeView(a: a)
      case .broadcast: BroadcastView(a: a)
      case .reading:   ReadingView(a: a)
      case .sent:      SentView(a: a)
      }
    }
    .foregroundStyle(Color.wInk)
  }
}

private func timeStr(_ d: Date) -> String {
  let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
}

// MARK: HOME
struct HomeView: View {
  @ObservedObject var a: Assistant
  var body: some View {
    VStack(spacing: 6) {
      HStack(spacing: 4) {
        Circle().fill(a.connected ? Color.wGreen : Color.wAmber).frame(width: 6, height: 6)
        Text(a.connected ? "已连接" : "连接中").font(.system(size: 10)).foregroundStyle(Color.wInk2)
        Text(APP_BUILD).font(.system(size: 10, weight: .bold)).foregroundStyle(Color.wTeal)
      }
      Circle().fill(Color.wTeal).frame(width: 48, height: 48)
        .shadow(color: Color.wTeal.opacity(0.6), radius: 12)
      Text(timeStr(a.now)).font(.system(size: 28, weight: .semibold))
      Button { if let f = a.queue.first { a.broadcast(f) } } label: {
        Text(a.pendingText).font(.system(size: 13, weight: .medium))
          .foregroundStyle(a.queue.isEmpty ? Color.wGreen : Color.wAmber)
      }
      .buttonStyle(.plain).padding(.top, 2)
      Button("刷新") { a.refresh() }
        .font(.system(size: 11)).tint(Color.wTeal).padding(.top, 2)
      Text(a.diag).font(.system(size: 9)).foregroundStyle(Color.wInk2)
        .multilineTextAlignment(.center).lineLimit(3).padding(.top, 2)
    }
    .padding()
  }
}

// MARK: BROADCAST
struct BroadcastView: View {
  @ObservedObject var a: Assistant
  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        Circle().fill(Color.wTeal).frame(width: 50, height: 50)
          .shadow(color: Color.wTeal.opacity(0.6), radius: a.speaking ? 16 : 8)
          .scaleEffect(a.speaking ? 1.08 : 1.0)
          .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: a.speaking)
        Text(a.bcTag).font(.system(size: 11)).foregroundStyle(Color.wTeal).tracking(1)
        Text(a.cur.speak).font(.system(size: 13)).multilineTextAlignment(.center)
          .foregroundStyle(Color.wInk).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Button("重听") { a.replayBroadcast() }.font(.system(size: 12)).tint(Color.wInk2)
          Button("看消息") { a.openReading() }.font(.system(size: 12, weight: .semibold)).tint(Color.wTeal)
        }.padding(.top, 4)
      }.padding()
    }
  }
}

// MARK: READING（C：消息在上，底部 说 / 快捷）
struct ReadingView: View {
  @ObservedObject var a: Assistant
  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        HStack(spacing: 6) {
          Text(String(a.cur.emp.prefix(1)).uppercased())
            .font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
            .frame(width: 22, height: 22).background(Circle().fill(Color(hex: a.cur.colorHex)))
          Text(a.cur.emp).font(.system(size: 13, weight: .semibold))
          Text(a.cur.proj).font(.system(size: 10)).foregroundStyle(Color.wAmber)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.wAmber.opacity(0.14)))
        }
        Text(a.cur.head).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.wAmber)
          .multilineTextAlignment(.center)
        Text(a.cur.body).font(.system(size: 14)).foregroundStyle(Color.wInk)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        Button { a.replayBroadcast() } label: {
          Label("重听助手播报", systemImage: "arrow.clockwise")
            .font(.system(size: 11)).foregroundStyle(Color.wInk2)
        }.buttonStyle(.plain).padding(.top, 2)
      }.padding()
    }
    .safeAreaInset(edge: .bottom) {
      HStack(spacing: 8) {
        Button { a.showInput = true } label: {
          Image(systemName: "mic.fill").font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 8)
        }.tint(Color.wTeal)
        Button { a.showChips = true } label: {
          Text("快捷").font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity).padding(.vertical, 8)
        }.tint(Color.wInk2)
      }.padding(.horizontal, 8).padding(.bottom, 4)
    }
    .sheet(isPresented: $a.showChips) { ChipsSheet(a: a) }
    .sheet(isPresented: $a.showInput) { InputSheet(a: a) }
    .overlay { if a.sending { ProgressView().tint(Color.wTeal) } }
  }
}

// 快捷回复抽屉
struct ChipsSheet: View {
  @ObservedObject var a: Assistant
  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        Text("快捷回复").font(.system(size: 11)).foregroundStyle(Color.wInk2)
        ForEach(a.cur.chips, id: \.self) { txt in
          Button { a.dispatch(txt) } label: {
            Text(txt).font(.system(size: 13)).frame(maxWidth: .infinity).padding(.vertical, 4)
          }.tint(Color.wTeal)
        }
      }.padding()
    }
  }
}

// 语音/听写输入（点 TextField 触发表盘听写）
struct InputSheet: View {
  @ObservedObject var a: Assistant
  @State private var text = ""
  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        Text("说出你的决定").font(.system(size: 11)).foregroundStyle(Color.wTeal)
        TextField("点这里 → 用听写说", text: $text, axis: .vertical)
          .font(.system(size: 14))
        Button {
          a.dispatch(text)
        } label: {
          Label("发给 \(a.cur.emp)", systemImage: "paperplane.fill")
            .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
        }.tint(Color.wTeal).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
      }.padding()
    }
  }
}

// MARK: SENT
struct SentView: View {
  @ObservedObject var a: Assistant
  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(Color.wGreen)
      Text("已发给 \(a.cur.emp)").font(.system(size: 14, weight: .semibold))
      Text("接下来：\(a.sentInstruction)").font(.system(size: 11)).foregroundStyle(Color.wInk2)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 6) {
        Circle().fill(Color.wAmber).frame(width: 7, height: 7); Text("等你").font(.system(size: 11)).foregroundStyle(Color.wInk2)
        Text("→").foregroundStyle(Color.wInk2)
        Circle().fill(Color.wGreen).frame(width: 7, height: 7); Text("干活中").font(.system(size: 11)).foregroundStyle(Color.wInk2)
      }.padding(.top, 2)
    }.padding()
  }
}
