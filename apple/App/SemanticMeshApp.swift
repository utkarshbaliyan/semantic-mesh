import SwiftUI
import AVKit
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
import CoreTransferable
#endif

@main
struct SemanticMeshApp: App {
    @StateObject private var mesh = MeshModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            MeshView(mesh: mesh)
                .onChange(of: scenePhase) { _, phase in if phase == .background { mesh.stop() } }
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 640)
                #endif
        }
    }
}

struct MeshView: View {
    @ObservedObject var mesh: MeshModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Your profile") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Username", text: $mesh.usernameDraft)
                                    .autocorrectionDisabled()
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    #endif
                                    .onSubmit { mesh.saveUsername() }
                                    .onChange(of: mesh.usernameDraft) { _, _ in mesh.usernameMessage = nil }
                                Button("Save") { mesh.saveUsername() }.buttonStyle(.borderedProminent).disabled(mesh.recording || mesh.preparingMedia)
                            }
                            Text("3–24 characters: lowercase letters, numbers or _ — must start with a letter. Example: utkarsh_2").font(.caption).foregroundStyle(.secondary)
                            if let message = mesh.usernameMessage { Text(message).font(.callout).foregroundStyle(mesh.usernameFailed ? .red : .green) }
                            Text("@\(mesh.username) · \(mesh.identity.prefix(8))").font(.caption).textSelection(.enabled)
                            Text("Usernames are nearby aliases. Compare device IDs when names match.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Keep Wi-Fi and Bluetooth enabled and both apps open. Nearby messaging works without internet.").font(.caption)
                    HStack {
                        Button(mesh.running ? "Stop network" : "Start network") { mesh.running ? mesh.stop() : mesh.start() }.buttonStyle(.borderedProminent)
                        Text("\(mesh.connected.count) connected").font(.caption)
                    }
                    PeopleView(mesh: mesh)
                    GroupsView(mesh: mesh)
                    if mesh.selectedContact != nil || mesh.selectedGroup != nil { ConversationView(mesh: mesh) }
                    if let latest = mesh.log.last { Text(latest).font(.caption).foregroundStyle(.secondary) }
                    DisclosureGroup("Network log") {
                        ForEach(Array(mesh.log.enumerated()), id: \.offset) { _, line in Text(line).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }.padding()
            }.navigationTitle("Semantic Mesh")
                .alert("Chat request", isPresented: Binding(get: { mesh.pendingInvitation != nil }, set: { if !$0 { mesh.answerInvitation(false) } })) {
                    Button("Accept") { mesh.answerInvitation(true) }
                    Button("Reject", role: .cancel) { mesh.answerInvitation(false) }
                } message: { Text("\(mesh.pendingInvitation?.label ?? "Nearby user") wants to chat. Confirm their device ID in person.") }
                .sheet(isPresented: $mesh.showGroupEditor) { GroupEditor(mesh: mesh) }
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
}

struct PeopleView: View {
    @ObservedObject var mesh: MeshModel
    var body: some View {
        VStack(spacing: 18) {
            GroupBox("Find people nearby") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Search username or device ID", text: $mesh.search).autocorrectionDisabled()
                    if mesh.filteredNearby.isEmpty { Text(mesh.running ? "No matching nearby users. Open version 0.4 on the other device." : "Start the network to discover people.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(mesh.filteredNearby) { peer in
                        HStack {
                            Text(peer.name).font(.subheadline)
                            Spacer()
                            if mesh.isConnected(peer.id) { Text("Connected").font(.caption).foregroundStyle(.green) }
                            else {
                                Button(mesh.pendingRequests.contains(peer.id) ? "Requested" : mesh.contacts.contains(where: { $0.id == peer.id }) ? "Reconnect" : "Request chat") { mesh.invite(peer) }.disabled(mesh.pendingRequests.contains(peer.id))
                            }
                        }
                    }
                    Text("Chat requests require the other person's approval.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Contacts") {
                VStack(alignment: .leading, spacing: 10) {
                    if mesh.contacts.isEmpty { Text("Accepted chat requests appear here.").foregroundStyle(.secondary) }
                    ForEach(mesh.contacts) { contact in
                        Button { mesh.selectContact(contact.id) } label: {
                            HStack {
                                Image(systemName: mesh.selectedContactID == contact.id ? "checkmark.circle.fill" : "person.crop.circle")
                                Text(contact.label)
                                Spacer()
                                Text(mesh.isConnected(contact.id) ? "Nearby" : "Offline").font(.caption)
                            }
                        }.buttonStyle(.bordered).disabled(mesh.recording || mesh.requestingMicrophone || mesh.preparingMedia)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct GroupsView: View {
    @ObservedObject var mesh: MeshModel
    var body: some View {
        GroupBox("Groups") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(mesh.groups) { group in
                    Button { mesh.selectGroup(group.id) } label: {
                        HStack {
                            Image(systemName: mesh.selectedGroupID == group.id ? "checkmark.circle.fill" : "person.3")
                            Text(group.name)
                            Spacer()
                            Text(group.contains(mesh.identity) ? "\(group.members.count) members" : "Removed").font(.caption)
                        }
                    }.buttonStyle(.bordered).disabled(mesh.recording || mesh.requestingMicrophone || mesh.preparingMedia)
                }
                Button("Create group") { mesh.editGroup() }.buttonStyle(.borderedProminent).disabled(mesh.recording || mesh.requestingMicrophone || mesh.preparingMedia)
                Text("The creator manages membership. Members must accept chat requests from one another to exchange messages directly.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("Group name", text: $mesh.groupName)
                    Text("You are the owner. Choose up to 15 other members.").font(.caption)
                    if candidates.isEmpty { Text("No contacts yet. Accept a chat request from someone nearby, then add them here.").font(.caption).foregroundStyle(.orange) }
                    ForEach(candidates) { contact in
                        Toggle(contact.label, isOn: Binding(get: { mesh.groupMembers.contains(contact.id) }, set: { included in
                            if included { mesh.groupMembers.insert(contact.id) } else { mesh.groupMembers.remove(contact.id) }
                        }))
                    }
                    Text("Uncheck a member to remove them. Changes reach disconnected devices when they reconnect with you.").font(.caption).foregroundStyle(.secondary)
                    if let problem = mesh.groupError { Text(problem).font(.callout).foregroundStyle(.red) }
                    HStack {
                        Button("Cancel") { mesh.showGroupEditor = false }
                        Spacer()
                        Button("Save group") { mesh.saveGroup() }.buttonStyle(.borderedProminent)
                    }
                }.padding()
            }.navigationTitle(mesh.editingGroupID == nil ? "Create group" : "Manage members")
        }.frame(minWidth: 320, minHeight: 360)
    }
}

struct ConversationView: View {
    @ObservedObject var mesh: MeshModel
    var body: some View {
        GroupBox(mesh.chatTitle) {
            VStack(alignment: .leading, spacing: 12) {
                if let group = mesh.selectedGroup {
                    Text(group.members.map { mesh.senderName($0.id) }.joined(separator: ", ")).font(.caption)
                    if !group.contains(mesh.identity) { Text("You were removed from this group.").foregroundStyle(.secondary) }
                    if group.ownerID == mesh.identity { Button("Add / remove members") { mesh.editGroup(group) }.disabled(mesh.recording || mesh.preparingMedia) }
                } else if let contact = mesh.selectedContact, !mesh.isConnected(contact.id) {
                    Text("Offline. Reconnect nearby within one hour to deliver queued messages.").font(.caption).foregroundStyle(.secondary)
                }
                if mesh.messages.isEmpty { Text("No live messages in this chat.").foregroundStyle(.secondary) }
                ForEach(mesh.messages, id: \.id) { e in MessageView(mesh: mesh, envelope: e); Divider() }
                TextField("Message", text: $mesh.draft, axis: .vertical).lineLimit(2...5)
                HStack {
                    ForEach(["😀", "😂", "❤️", "👍", "🎉", "🙏"], id: \.self) { emoji in
                        Button(emoji) { mesh.draft += emoji }.disabled(!mesh.canCompose || mesh.draft.utf16.count + emoji.utf16.count > 2000)
                    }
                }
                HStack {
                    Text("\(mesh.draft.utf16.count)/2000").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Send") { if mesh.send(mesh.draft) { mesh.draft = "" } }
                        .disabled(!mesh.canCompose || mesh.recording || mesh.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mesh.draft.utf16.count > 2000)
                }
                MediaComposer(mesh: mesh)
                Text("Audio/video: up to 20 MB. Voice: up to 2 minutes. Messages and attachments expire after one hour. Delivery confirms storage, not reading.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MessageView: View {
    @ObservedObject var mesh: MeshModel
    let envelope: Envelope
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(mesh.senderName(envelope.sender)).font(.caption).foregroundStyle(.secondary)
            if let media = envelope.media {
                if mesh.mediaAvailable(envelope) {
                    Button { mesh.play(envelope) } label: { Label("Play \(media.kind) · \(ByteCountFormatter.string(fromByteCount: media.bytes, countStyle: .file))", systemImage: media.kind == "audio" ? "play.circle" : "video") }
                } else { Text("Waiting for \(media.kind) attachment…").foregroundStyle(.secondary) }
            } else { Text(envelope.text ?? "").textSelection(.enabled) }
            HStack {
                Text(Date(timeIntervalSince1970: Double(envelope.created) / 1000), style: .time)
                if envelope.sender == mesh.identity { Text(mesh.deliveryStatus(envelope)) }
            }.font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
    }
}

struct MediaComposer: View {
    @ObservedObject var mesh: MeshModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Audio file") { mesh.chooseMedia("audio") }
                Button("Video file") { mesh.chooseMedia("video") }
                #if os(iOS)
                PhotosPicker(selection: $mesh.pickedVideo, matching: .videos) { Text("Photos video") }
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
            }.disabled(!mesh.canCompose || mesh.recording || mesh.requestingMicrophone || mesh.preparingMedia)
            if mesh.preparingMedia { ProgressView("Preparing video…") }
            HStack {
                Button(mesh.recording ? "Send recording" : mesh.requestingMicrophone ? "Waiting for microphone…" : "Record voice") { mesh.toggleRecording() }
                    .disabled(!mesh.canCompose || mesh.requestingMicrophone || mesh.preparingMedia)
                if mesh.recording { Button("Cancel recording") { mesh.cancelRecording() } }
            }
        }
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
