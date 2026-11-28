import SwiftUI
import AVKit
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
import PhotosUI
import CoreTransferable
#else
import AppKit
#endif

/// Renders a string (an `sm://add` contact link) as a QR code image for either platform.
func meshQRImage(from string: String) -> Image? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
    let context = CIContext()
    guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
    #if os(iOS)
    return Image(uiImage: UIImage(cgImage: cg))
    #else
    return Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height)))
    #endif
}

struct MyQRView: View {
    @ObservedObject var mesh: MeshModel
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let link = mesh.myCardLink, let image = meshQRImage(from: link) {
                    image.interpolation(.none).resizable().scaledToFit().frame(maxWidth: 280)
                        .padding().background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(mesh.myHandle).font(.headline)
                    Text("Have someone scan this in Semantic Mesh, or send them the link below, to add you as a verified contact.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text(link).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(4).padding(.horizontal)
                } else {
                    Text("Your contact code is unavailable because secure storage could not be opened.").foregroundStyle(.secondary)
                }
            }.padding()
        }.navigationTitle("My QR code")
    }
}

#if os(iOS)
struct ScanQRView: View {
    @ObservedObject var mesh: MeshModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        QRScanner { code in if mesh.addFromCard(code) { dismiss() } }
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                Text(mesh.addContactMessage ?? "Point the camera at a Semantic Mesh QR code.")
                    .font(.callout).padding().frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
            }
            .navigationTitle("Scan a code")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// A camera preview that reports the first `sm://` QR payload it sees. No SwiftUI macros are used.
struct QRScanner: UIViewControllerRepresentable {
    let onFound: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }
    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController(); controller.coordinator = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onFound: (String) -> Void
        private var handled = false
        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !handled, let object = objects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue, value.hasPrefix("sm://") else { return }
            handled = true; onFound(value)
        }
    }
}

final class ScannerController: UIViewController {
    var coordinator: QRScanner.Coordinator?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill; layer.frame = view.bounds
        view.layer.addSublayer(layer); preview = layer
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in if self?.session.isRunning == true { self?.session.stopRunning() } }
    }
}
#endif

@main
struct SemanticMeshApp: App {
    @StateObject private var mesh = MeshModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView(mesh: mesh)
                .onAppear { mesh.resume() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { mesh.stop() } else if phase == .active { mesh.resume() }
                }
                #if os(macOS)
                .frame(minWidth: 760, minHeight: 560)
                #endif
        }
    }
}

enum Panel: String, Identifiable { case settings, nearby, chatInfo, groupEditor; var id: String { rawValue } }

/// Chat list beside the open chat on Mac and iPad; collapses to a push navigation stack on iPhone.
struct RootView: View {
    @ObservedObject var mesh: MeshModel
    var body: some View {
        NavigationSplitView {
            ChatListView(mesh: mesh, panel: $mesh.panel)
                .navigationSplitViewColumnWidth(min: 280, ideal: 330)
        } detail: {
            if mesh.selectedChatKey != nil { ConversationView(mesh: mesh, panel: $mesh.panel) }
            else {
                ContentUnavailableView("Select a chat", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Find people nearby, then chat without internet."))
            }
        }
        .alert("Chat request", isPresented: Binding(get: { mesh.pendingInvitation != nil }, set: { if !$0 { mesh.answerInvitation(false) } })) {
            Button("Accept") { mesh.answerInvitation(true) }
            Button("Reject", role: .cancel) { mesh.answerInvitation(false) }
        } message: { Text("\(mesh.pendingInvitation?.label ?? "Nearby user") wants to chat. Confirm their device ID in person.") }
        .sheet(item: $mesh.panel, onDismiss: { if mesh.showGroupEditor && mesh.panel == nil { mesh.showGroupEditor = false } }) { item in
            switch item {
            case .settings: SettingsView(mesh: mesh, panel: $mesh.panel)
            case .nearby: NearbyView(mesh: mesh, panel: $mesh.panel)
            case .chatInfo: ChatInfoView(mesh: mesh, panel: $mesh.panel)
            case .groupEditor: GroupEditor(mesh: mesh)
            }
        }
        .onChange(of: mesh.showGroupEditor) { _, open in
            if open { mesh.panel = .groupEditor } else if mesh.panel == .groupEditor { mesh.panel = nil }
        }
        .sheet(isPresented: $mesh.showPlayer, onDismiss: { mesh.endPlayback() }) {
            VStack {
                MediaPlayerView(player: mesh.player).frame(minHeight: 240)
                Button("Close") { mesh.endPlayback() }.padding()
            }.frame(minWidth: 320).padding()
        }
        .fileImporter(isPresented: $mesh.showImporter, allowedContentTypes: mesh.importKind == "audio" ? [.audio] : [.movie]) { result in
            switch result {
            case .success(let url): mesh.importFile(url, kind: mesh.importKind)
            case .failure(let error): mesh.status(error.localizedDescription)
            }
        }
    }
}

struct Avatar: View {
    let name: String
    var group = false
    var size: CGFloat = 44
    private var color: Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .red]
        return palette[Int(name.unicodeScalars.reduce(UInt32(0)) { $0 &* 31 &+ $1.value } % UInt32(palette.count))]
    }
    var body: some View {
        ZStack {
            Circle().fill(color.gradient)
            if group { Image(systemName: "person.3.fill").font(.system(size: size * 0.32)).foregroundStyle(.white) }
            else { Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct ChatListView: View {
    @ObservedObject var mesh: MeshModel
    @Binding var panel: Panel?
    var body: some View {
        List(selection: Binding(get: { mesh.selectedChatKey }, set: { mesh.selectedChatKey = $0 })) {
            Section { NetworkBanner(mesh: mesh) }
            Section("Chats") {
                if mesh.chatList.isEmpty {
                    Button { panel = .nearby } label: { Label("Find people nearby to start chatting", systemImage: "person.badge.plus") }
                }
                ForEach(mesh.filteredChats) { chat in ChatRow(chat: chat).tag(chat.id) }
            }
        }
        .searchable(text: $mesh.chatSearch, prompt: "Search chats")
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { panel = .nearby } label: { Label("Find people", systemImage: "person.badge.plus") }
                Button { mesh.editGroup() } label: { Label("New group", systemImage: "person.3") }
                    .disabled(mesh.recording || mesh.requestingMicrophone || mesh.preparingMedia)
                Button { panel = .settings } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
    }
}

struct NetworkBanner: View {
    @ObservedObject var mesh: MeshModel
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(mesh.running ? Color.green : Color.secondary).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(mesh.running ? "Mesh on" : "Mesh off").font(.subheadline.bold())
                Text(mesh.running ? "\(mesh.connected.count) connected · carrying \(mesh.relayCarried) for others" : "Turn on to send and receive without internet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(mesh.running ? "Stop" : "Start") { mesh.setMesh(!mesh.running) }
                .buttonStyle(.borderedProminent).tint(mesh.running ? .red : .green)
        }.padding(.vertical, 4)
    }
}

struct ChatRow: View {
    let chat: ChatSummary
    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Avatar(name: chat.title, group: chat.isGroup)
                if chat.online { Circle().fill(.green).frame(width: 12, height: 12).overlay(Circle().stroke(.background, lineWidth: 2)) }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(chat.isGroup ? chat.title : "@" + chat.title).font(.headline).lineLimit(1)
                    if let tag = chat.tag { Text("#" + tag).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    if chat.verified { Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.blue) }
                    Spacer()
                    if let time = chat.lastTime { Text(Date(timeIntervalSince1970: Double(time) / 1000), style: .time).font(.caption).foregroundStyle(.secondary) }
                }
                Text(chat.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 4)
    }
}

struct ConversationView: View {
    @ObservedObject var mesh: MeshModel
    @Binding var panel: Panel?
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if let notice = mesh.chatNotice {
                            Text(notice).font(.caption).multilineTextAlignment(.center).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule()).padding(.vertical, 8)
                        }
                        ForEach(mesh.messages, id: \.id) { e in Bubble(mesh: mesh, envelope: e).id(e.id) }
                    }.padding(.horizontal, 10).padding(.vertical, 8)
                }
                .onChange(of: mesh.messages.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
                .onAppear { if let id = mesh.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            Divider()
            Composer(mesh: mesh)
        }
        .navigationTitle(mesh.chatTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { panel = .chatInfo } label: { Label(mesh.selectedGroup == nil ? "Contact info" : "Group info", systemImage: "info.circle") }
            }
        }
    }
}

struct Bubble: View {
    @ObservedObject var mesh: MeshModel
    let envelope: Envelope
    private var mine: Bool { envelope.sender == mesh.identity }
    var body: some View {
        HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 4) {
                if !mine, mesh.selectedGroup != nil { Text(mesh.senderName(envelope.sender)).font(.caption.bold()).foregroundStyle(Color.accentColor) }
                content
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(Date(timeIntervalSince1970: Double(envelope.created) / 1000), style: .time)
                    if mine { Image(systemName: mesh.deliveryIcon(envelope)) }
                }.font(.caption2).foregroundStyle(mine ? Color.white.opacity(0.85) : Color.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(mine ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(mine ? Color.white : Color.primary)
            .frame(maxWidth: 520, alignment: mine ? .trailing : .leading)
            .help(mine ? mesh.deliveryStatus(envelope) : "")
            .contextMenu {
                if let text = envelope.text { Button { copy(text) } label: { Label("Copy", systemImage: "doc.on.doc") } }
                if mine { Text(mesh.deliveryStatus(envelope)) }
            }
            if !mine { Spacer(minLength: 48) }
        }
    }
    @ViewBuilder private var content: some View {
        if let media = envelope.media {
            if mesh.mediaAvailable(envelope) {
                Button { mesh.play(envelope) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: media.kind == "audio" ? "play.circle.fill" : "play.rectangle.fill").font(.largeTitle)
                        VStack(alignment: .leading) {
                            Text(media.kind == "audio" ? "Audio" : "Video").bold()
                            Text(ByteCountFormatter.string(fromByteCount: media.bytes, countStyle: .file)).font(.caption)
                        }
                    }
                }.buttonStyle(.plain)
            } else { Label("Receiving \(media.kind)…", systemImage: "arrow.down.circle") }
        } else { Text(envelope.text ?? "").textSelection(.enabled) }
    }
    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Every chat gets the same composer: attachments, emoji, text, and voice recording.
struct Composer: View {
    @ObservedObject var mesh: MeshModel
    private let emojis = ["😀", "😂", "😍", "🥰", "😎", "🤔", "😢", "😡", "👍", "👎", "🙏", "👏", "🎉", "❤️", "🔥", "✅"]
    private var busy: Bool { !mesh.canCompose || mesh.requestingMicrophone || mesh.preparingMedia }
    private var trimmed: String { mesh.draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(spacing: 6) {
            if mesh.preparingMedia { ProgressView("Preparing video…").font(.caption) }
            if mesh.recording {
                HStack(spacing: 12) {
                    Image(systemName: "record.circle").foregroundStyle(.red).symbolEffect(.pulse)
                    TimelineView(.periodic(from: mesh.recordingStarted, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(mesh.recordingStarted)))
                        Text(String(format: "%d:%02d / 2:00", seconds / 60, seconds % 60)).monospacedDigit()
                    }
                    Spacer()
                    Button(role: .destructive) { mesh.cancelRecording() } label: { Image(systemName: "trash").font(.title3) }
                        .accessibilityLabel("Cancel recording")
                    Button { mesh.toggleRecording() } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .accessibilityLabel("Send recording")
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    Menu {
                        Button { mesh.chooseMedia("audio") } label: { Label("Audio file", systemImage: "music.note") }
                        Button { mesh.chooseMedia("video") } label: { Label("Video file", systemImage: "film") }
                        #if os(iOS)
                        Button { mesh.showPhotos = true } label: { Label("Video from Photos", systemImage: "photo.on.rectangle") }
                        #endif
                    } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                        .disabled(busy).accessibilityLabel("Attach")
                    Menu {
                        ForEach(emojis, id: \.self) { emoji in Button(emoji) { if mesh.draft.utf16.count + emoji.utf16.count <= 2000 { mesh.draft += emoji } } }
                    } label: { Image(systemName: "face.smiling").font(.title2) }
                        .disabled(busy).accessibilityLabel("Emoji")
                    TextField(mesh.canCompose ? "Message" : "Can't send right now", text: $mesh.draft, axis: .vertical)
                        .lineLimit(1...5).textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                        .disabled(!mesh.canCompose)
                    if trimmed.isEmpty {
                        Button { mesh.toggleRecording() } label: { Image(systemName: mesh.requestingMicrophone ? "hourglass.circle" : "mic.circle.fill").font(.title) }
                            .disabled(busy).accessibilityLabel("Record voice message")
                    } else {
                        Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                            .disabled(!mesh.canCompose || mesh.draft.utf16.count > 2000)
                            .keyboardShortcut(.return, modifiers: .command).accessibilityLabel("Send")
                    }
                }
                if mesh.draft.utf16.count > 1800 { Text("\(mesh.draft.utf16.count)/2000").font(.caption2).foregroundStyle(mesh.draft.utf16.count > 2000 ? Color.red : Color.secondary) }
            }
        }
        .buttonStyle(.borderless)
        .padding(10)
        .background(.bar)
        #if os(iOS)
        .photosPicker(isPresented: $mesh.showPhotos, selection: $mesh.pickedVideo, matching: .videos)
        .onChange(of: mesh.pickedVideo) { _, item in
            guard let item else { return }
            mesh.preparingMedia = true
            Task {
                do {
                    if let video = try await item.loadTransferable(type: PickedVideo.self) {
                        mesh.importFile(video.url, kind: "video"); try? FileManager.default.removeItem(at: video.url)
                    }
                } catch { mesh.status(error.localizedDescription) }
                mesh.preparingMedia = false; mesh.pickedVideo = nil
            }
        }
        #endif
    }
    private func send() { if mesh.send(mesh.draft) { mesh.draft = "" } }
}

struct ChatInfoView: View {
    @ObservedObject var mesh: MeshModel
    @Binding var panel: Panel?
    private var media: [Envelope] { mesh.messages.filter { $0.media != nil && mesh.mediaAvailable($0) } }
    var body: some View {
        NavigationStack {
            Form {
                if let group = mesh.selectedGroup {
                    Section {
                        HStack(spacing: 14) {
                            Avatar(name: group.name, group: true, size: 64)
                            VStack(alignment: .leading) {
                                Text(group.name).font(.title2.bold())
                                Text(group.contains(mesh.identity) ? "\(group.members.count) members" : "You were removed").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Members") {
                        ForEach(group.members) { member in
                            HStack {
                                Avatar(name: mesh.nickname(member.id) ?? member.username, size: 32)
                                Text(member.id == mesh.identity ? "You" : "@" + (mesh.nickname(member.id) ?? member.username) + (mesh.contactTag(member.id).map { "#" + $0 } ?? ""))
                                if member.id != mesh.identity, mesh.isVerified(member.id) { Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.blue) }
                                Spacer()
                                if member.id == group.ownerID { Text("Owner").font(.caption).foregroundStyle(.secondary) }
                                else if member.id != mesh.identity { Text(mesh.reachability(member.id)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if group.ownerID == mesh.identity {
                            Button { mesh.editGroup(group) } label: { Label("Add or remove members", systemImage: "person.badge.plus") }
                        }
                    }
                } else if let contact = mesh.selectedContact {
                    Section {
                        HStack(spacing: 14) {
                            Avatar(name: mesh.contactName(contact.id), size: 64)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(mesh.contactHandle(contact.id)).font(.title2.bold())
                                    if mesh.isVerified(contact.id) { Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue) }
                                }
                                if mesh.nickname(contact.id) != nil { Text("@" + contact.username).font(.caption).foregroundStyle(.secondary) }
                                Text(mesh.reachability(contact.id)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        HStack {
                            Text("Nickname")
                            Spacer()
                            TextField("Their name on this device", text: $mesh.nicknameDraft)
                                .multilineTextAlignment(.trailing)
                                #if os(iOS)
                                .textInputAutocapitalization(.words)
                                #endif
                                .onAppear { mesh.beginNicknameEdit(contact.id) }
                            Button("Save") { mesh.commitNickname() }.disabled(mesh.nicknameDraft == (mesh.nickname(contact.id) ?? ""))
                        }
                    } footer: { Text("A private label only you see. Leave blank to show their chosen username.") }
                    Section {
                        LabeledContent("Device ID") { Text(contact.id).font(.caption.monospaced()).textSelection(.enabled) }
                        LabeledContent("Tag") { Text("#" + (mesh.contactTag(contact.id) ?? "----")).monospaced() }
                        LabeledContent("Safety code") { Text(mesh.safetyCode(for: contact.id) ?? "Not exchanged yet").monospaced() }
                    } header: { Text("Security") } footer: { Text(mesh.isVerified(contact.id) ? "Added by scanning their code — identity verified." : "Compare this code with the one in their Settings, in person. If they match, nobody is impersonating them.") }
                }
                Section("Media") {
                    if media.isEmpty { Text("No audio or video in this chat.").foregroundStyle(.secondary) }
                    ForEach(media, id: \.id) { e in
                        Button {
                            panel = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { mesh.play(e) }
                        } label: {
                            HStack {
                                Label(e.media?.kind == "audio" ? "Audio" : "Video", systemImage: e.media?.kind == "audio" ? "music.note" : "film")
                                Spacer()
                                Text(mesh.senderName(e.sender)).font(.caption).foregroundStyle(.secondary)
                                Text(Date(timeIntervalSince1970: Double(e.created) / 1000), style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(mesh.selectedGroup == nil ? "Contact info" : "Group info")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
        }.frame(minWidth: 380, minHeight: 460)
    }
}

struct SettingsView: View {
    @ObservedObject var mesh: MeshModel
    @Binding var panel: Panel?
    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    HStack(spacing: 14) {
                        Avatar(name: mesh.username, size: 56)
                        VStack(alignment: .leading) {
                            Text(mesh.myHandle).font(.title3.bold())
                            Text("Device \(String(mesh.identity.prefix(8)))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        TextField("Username", text: $mesh.usernameDraft)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .onSubmit { mesh.saveUsername() }
                            .onChange(of: mesh.usernameDraft) { _, _ in mesh.usernameMessage = nil }
                        Button("Save") { mesh.saveUsername() }.disabled(mesh.recording || mesh.preparingMedia || mesh.usernameDraft == mesh.username)
                    }
                    if let message = mesh.usernameMessage { Text(message).font(.callout).foregroundStyle(mesh.usernameFailed ? .red : .green) }
                    Text("3–24 lowercase letters, numbers or _, starting with a letter. Usernames are nearby aliases, not global accounts.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Device ID") { Text(mesh.identity).font(.caption.monospaced()).textSelection(.enabled) }
                    LabeledContent("Safety code") { Text(mesh.safetyCode).monospaced().textSelection(.enabled) }
                } header: { Text("Security") } footer: { Text("Contacts compare this code in person to confirm it's really you.") }
                Section {
                    NavigationLink { MyQRView(mesh: mesh) } label: { Label("My QR code", systemImage: "qrcode") }
                    #if os(iOS)
                    NavigationLink { ScanQRView(mesh: mesh) } label: { Label("Scan a code", systemImage: "qrcode.viewfinder") }
                    #endif
                    HStack {
                        TextField("Paste an sm:// link", text: $mesh.pasteLink)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                        Button("Add") { if mesh.addFromCard(mesh.pasteLink) { mesh.pasteLink = "" } }
                            .disabled(mesh.pasteLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let message = mesh.addContactMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
                } header: { Text("Add people") } footer: { Text("Share your code, or scan/paste someone's, to add them as a verified contact without meeting on the mesh first.") }
                Section {
                    Toggle("Mesh network", isOn: Binding(get: { mesh.running }, set: { mesh.setMesh($0) }))
                    LabeledContent("Connected devices", value: "\(mesh.connected.count)")
                    LabeledContent("Carrying for others", value: "\(mesh.relayCarried)")
                } header: { Text("Network") } footer: { Text("Keep Wi-Fi and Bluetooth on and the app open. No internet needed. Text hops across devices; files need a direct connection.") }
                Section("Limits") {
                    Text("Messages and files expire after 1 hour. Text up to 2,000 characters. Audio/video up to 20 MB. Voice up to 2 minutes. Groups up to 16 people.").font(.caption)
                }
                Section("Network log") {
                    if mesh.log.isEmpty { Text("No events yet.").foregroundStyle(.secondary) }
                    ForEach(Array(mesh.log.enumerated().reversed()), id: \.offset) { _, line in Text(line).font(.caption).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
        }.frame(minWidth: 420, minHeight: 520)
    }
}

struct NearbyView: View {
    @ObservedObject var mesh: MeshModel
    @Binding var panel: Panel?
    var body: some View {
        NavigationStack {
            List {
                if !mesh.running {
                    Section { Button { mesh.setMesh(true) } label: { Label("Turn on the mesh to discover people", systemImage: "antenna.radiowaves.left.and.right") } }
                }
                Section {
                    if mesh.running && mesh.filteredNearby.isEmpty { Text("Looking for people nearby running version 0.6…").foregroundStyle(.secondary) }
                    ForEach(mesh.filteredNearby) { peer in
                        HStack {
                            Avatar(name: peer.profile.username, size: 36)
                            VStack(alignment: .leading) {
                                Text("@" + peer.profile.username + "#" + peer.tag)
                                Text(String(peer.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if mesh.isConnected(peer.id) { Text("Connected").font(.caption).foregroundStyle(.green) }
                            else {
                                Button(mesh.pendingRequests.contains(peer.id) ? "Requested" : mesh.contacts.contains(where: { $0.id == peer.id }) ? "Reconnect" : "Request chat") { mesh.invite(peer) }
                                    .buttonStyle(.borderedProminent).disabled(mesh.pendingRequests.contains(peer.id))
                            }
                        }
                    }
                } header: { Text("Nearby") } footer: { Text("They must accept your first request. After that you're friends: you reconnect automatically whenever you're both nearby with the app open.") }
                Section("Contacts") {
                    if mesh.contacts.isEmpty { Text("Accepted requests appear here.").foregroundStyle(.secondary) }
                    ForEach(mesh.contacts) { contact in
                        Button {
                            mesh.selectContact(contact.id); panel = nil
                        } label: {
                            HStack {
                                Avatar(name: mesh.contactName(contact.id), size: 32)
                                Text(mesh.contactHandle(contact.id))
                                if mesh.isVerified(contact.id) { Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.blue) }
                                Spacer()
                                Text(mesh.reachability(contact.id)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $mesh.search, prompt: "Username or device ID")
            .navigationTitle("Find people")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { panel = nil } } }
        }.frame(minWidth: 400, minHeight: 480)
    }
}

struct GroupEditor: View {
    @ObservedObject var mesh: MeshModel
    var candidates: [ChatProfile] {
        var people = mesh.contacts
        if let id = mesh.editingGroupID, let group = mesh.groups.first(where: { $0.id == id }) {
            for member in group.members where member.id != mesh.identity && !people.contains(where: { $0.id == member.id }) { people.append(member) }
        }
        return people
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Group name", text: $mesh.groupName) } footer: { Text("You are the owner and manage members.") }
                Section {
                    if candidates.isEmpty { Text("No contacts yet. Accept a chat request from someone nearby first.").foregroundStyle(.orange) }
                    ForEach(candidates) { contact in
                        Toggle(isOn: Binding(get: { mesh.groupMembers.contains(contact.id) }, set: { included in
                            if included { mesh.groupMembers.insert(contact.id) } else { mesh.groupMembers.remove(contact.id) }
                        })) {
                            HStack { Avatar(name: contact.username, size: 28); Text("@" + contact.username) }
                        }
                    }
                } header: { Text("Members (\(mesh.groupMembers.count)/15)") } footer: { Text("Unchecking removes a member. Changes reach devices when they connect to you or through the mesh.") }
                if let problem = mesh.groupError { Section { Text(problem).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle(mesh.editingGroupID == nil ? "New group" : "Edit members")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { mesh.showGroupEditor = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { mesh.saveGroup() } }
            }
        }.frame(minWidth: 380, minHeight: 440)
    }
}

#if os(iOS)
struct PickedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let source = received.file
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= MediaVault.maxBytes else { throw FeatureError.invalidMedia }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + source.pathExtension)
            try FileManager.default.copyItem(at: source, to: url)
            return PickedVideo(url: url)
        }
    }
}
#endif

/// SwiftUI's VideoPlayer aborts on macOS when its AVKit superclass is not loaded, so the Mac
/// build hosts AVPlayerView directly. iOS keeps the SwiftUI player.
#if os(macOS)
struct MediaPlayerView: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}
#else
struct MediaPlayerView: View {
    let player: AVPlayer?
    var body: some View { VideoPlayer(player: player) }
}
#endif
