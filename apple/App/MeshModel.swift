import Foundation
import Combine
import AVFoundation
#if os(iOS)
import PhotosUI
import SwiftUI
#endif

struct ChatSummary: Identifiable, Equatable {
    let id: String
    let title: String
    let isGroup: Bool
    let preview: String
    let lastTime: Int64?
    let online: Bool
}

final class MeshModel: ObservableObject {
    @Published var chatList: [ChatSummary] = []
    /// View state lives here: plain swiftc builds (build-mac.sh) cannot load SwiftUI's @State macro plugin.
    @Published var panel: Panel?
    @Published var showPhotos = false
    @Published var recordingStarted = Date()
    @Published var chatSearch = ""
    @Published var draft = ""
    @Published var search = ""
    @Published var usernameDraft = ""
    @Published private(set) var username = ""
    @Published var nearby: [NearbyPeer] = []
    @Published var contacts: [ChatProfile] = []
    @Published var connected: [ChatProfile] = []
    @Published var pendingRequests: Set<String> = []
    @Published var selectedContactID: String?
    @Published var selectedGroupID: String?
    @Published var groups: [MeshGroup] = []
    @Published var messages: [Envelope] = []
    @Published var receipts: [String: Set<String>] = [:]
    @Published var log: [String] = []
    @Published var running = false
    @Published var pendingInvitation: ChatProfile?
    @Published var showGroupEditor = false
    @Published var groupName = ""
    @Published var groupMembers: Set<String> = []
    @Published var groupError: String?
    @Published var usernameMessage: String?
    @Published var usernameFailed = false
    @Published var editingGroupID: String?
    @Published var showImporter = false
    @Published var importKind = "audio"
    @Published var recording = false
    @Published var requestingMicrophone = false
    @Published var preparingMedia = false
    #if os(iOS)
    @Published var pickedVideo: PhotosPickerItem?
    #endif
    @Published var player: AVPlayer?
    @Published var showPlayer = false
    @Published var relayCarried = 0
    let identity: String
    private var contactBook: ContactBook?
    private var groupBook: GroupBook?
    private var vault: MediaVault?
    private var invitationReply: ((Bool) -> Void)?
    private var transport: MultipeerTransport?
    private var engine: MeshEngine?
    private var nodeKeys: NodeKeys?
    private var router: RelayRouter?
    private static let relayKinds: Set<String> = ["text", "ack", "group"]
    private var timer: Timer?
    private let recorder = VoiceRecorder()

    var selectedContact: ChatProfile? { contacts.first { $0.id == selectedContactID } }
    var selectedGroup: MeshGroup? { groups.first { $0.id == selectedGroupID } }
    var canCompose: Bool { running && (selectedContact != nil || selectedGroup?.contains(identity) == true) }
    var chatTitle: String { selectedGroup?.name ?? selectedContact.map { "@" + $0.username } ?? "Chats" }
    var filteredChats: [ChatSummary] {
        let term = chatSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return term.isEmpty ? chatList : chatList.filter { $0.title.lowercased().contains(term) }
    }
    /// "c:<contact id>" or "g:<group id>", for list selection.
    var selectedChatKey: String? {
        get { selectedGroupID.map { "g:" + $0 } ?? selectedContactID.map { "c:" + $0 } }
        set {
            guard newValue != selectedChatKey else { return }
            guard let value = newValue else { clearSelection(); return }
            if value.hasPrefix("g:") { selectGroup(String(value.dropFirst(2))) }
            else if value.hasPrefix("c:") { selectContact(String(value.dropFirst(2))) }
        }
    }
    func clearSelection() { guard !recording, !requestingMicrophone, !preparingMedia else { return }; selectedContactID = nil; selectedGroupID = nil; draft = ""; refresh() }
    var chatNotice: String? {
        if let group = selectedGroup, !group.contains(identity) { return "You were removed from this group." }
        if !running { return "Mesh is off. Turn it on from the chat list to send and receive." }
        if let contact = selectedContact, !isConnected(contact.id) {
            return reachableViaMesh(contact.id) ? "Not nearby. Text travels through the mesh; files need a direct connection."
                                                : "Offline. Messages are delivered when you reconnect within one hour."
        }
        if messages.isEmpty { return "Messages and files expire after one hour." }
        return nil
    }
    func reachability(_ id: String) -> String { isConnected(id) ? "Nearby" : reachableViaMesh(id) ? "Via mesh" : "Offline" }
    func safetyCode(for id: String) -> String? { contactBook?.keys(for: id)?.fingerprint }
    var filteredNearby: [NearbyPeer] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "@", with: "")
        return nearby.filter { term.isEmpty || $0.profile.username.contains(term) || $0.id.hasPrefix(term) }
    }
    func isConnected(_ id: String) -> Bool { connected.contains { $0.id == id } }
    func selectContact(_ id: String) { guard !recording, !requestingMicrophone, !preparingMedia else { return }; selectedGroupID = nil; selectedContactID = id; draft = ""; refresh() }
    func selectGroup(_ id: String) { guard !recording, !requestingMicrophone, !preparingMedia else { return }; selectedContactID = nil; selectedGroupID = id; draft = ""; refresh() }

    init() {
        var nodeID = UUID().uuidString.lowercased()
        var storageError: Error?
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var directory = support.appendingPathComponent("org.semanticmesh.apple")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true; try directory.setResourceValues(values)
            let identityFile = directory.appendingPathComponent("node-id.txt")
            if FileManager.default.fileExists(atPath: identityFile.path) {
                let saved = try String(contentsOf: identityFile, encoding: .utf8)
                guard UUID(uuidString: saved) != nil else { throw MeshError.invalidEnvelope }; nodeID = saved
            } else { try nodeID.write(to: identityFile, atomically: true, encoding: .utf8) }
            let storage = try MessageStore(file: directory.appendingPathComponent("messages.json"))
            contactBook = try ContactBook(file: directory.appendingPathComponent("contacts.json"), defaultUsername: "mesh_" + nodeID.prefix(6))
            groupBook = try GroupBook(file: directory.appendingPathComponent("groups.json"))
            vault = try MediaVault(directory: directory.appendingPathComponent("media"))
            nodeKeys = try NodeKeys(file: directory.appendingPathComponent("node-keys.json"))
            router = RelayRouter(local: nodeID, store: try RelayStore(file: directory.appendingPathComponent("relay.json")))
            engine = MeshEngine(identity: nodeID, store: storage)
        } catch { storageError = error; engine = nil }
        identity = nodeID
        if let engine, let book = contactBook {
            username = book.username; usernameDraft = book.username; contacts = book.contacts
            engine.transmit = { [weak self] data, _ in self?.transmit(data) }
            engine.authorizeIncoming = { [weak self] e, peer in self?.authorized(e, from: peer) == true }
            engine.received = { [weak self] _ in self?.refresh() }
            engine.error = { [weak self] error in self?.status(error.localizedDescription) }
            router?.send = { [weak self] data, peer in self?.transport?.send(data, to: peer) }
            router?.keysFor = { [weak self] id in self?.contactBook?.keys(for: id) }
            refresh()
        } else { status("Storage unavailable: \(storageError?.localizedDescription ?? "unknown error"). Sending is disabled.") }
    }

    private func transmit(_ data: Data) {
        guard let e = try? Envelope.decode(data), e.sender == identity else { return }
        if e.kind == "group" {
            guard let id = e.groupID, groupBook?.group(id) == e.group else { return }
        }
        if (e.kind == "text" || e.kind == "media"), let id = e.groupID {
            guard let group = groupBook?.group(id), group.contains(identity), group.revision == e.groupRevision else { return }
            for member in group.members where member.id != identity && contactBook?.profile(for: member.id) != nil {
                var addressed = e; addressed.to = member.id
                deliver(addressed)
            }
        } else if let to = e.to, contactBook?.profile(for: to) != nil { deliver(e) }
    }
    /// Direct link when the recipient is connected; otherwise an end-to-end sealed frame any device can carry.
    /// Media files still need a direct link.
    private func deliver(_ e: Envelope) {
        guard let to = e.to else { return }
        if isConnected(to) { if let frame = try? e.encoded() { transport?.send(frame, to: to) }; return }
        guard Self.relayKinds.contains(e.kind), let keys = contactBook?.keys(for: to), let nodeKeys, let router,
              !router.store.contains(SealedFrame.frameID(inner: e.id, to: to)), !acknowledged(e, by: to) else { return }
        do { try router.originate(SealedFrame.seal(e, keys: nodeKeys, recipient: keys)) }
        catch { status("Mesh relay: \(error.localizedDescription)") }
    }
    private func acknowledged(_ e: Envelope, by peer: String) -> Bool {
        e.kind != "ack" && engine?.store.active().contains { $0.kind == "ack" && $0.ackFor == e.id && $0.sender == peer } == true
    }
    private func relayed(_ frame: SealedFrame, from peer: String) {
        guard let router, let nodeKeys else { return }
        do {
            switch try router.accept(frame, from: peer) {
            case .duplicate: return
            case .carried: relayCarried = router.carriedCount()
            case .forMe:
                guard let keys = contactBook?.keys(for: frame.from) else { status("Dropped a relayed message from an unverified sender."); return }
                let e = try frame.open(keys: nodeKeys, local: identity, sender: keys)
                guard Self.relayKinds.contains(e.kind) else { return }
                try process(e, data: e.encoded(), from: frame.from)
                if e.kind == "text" { status("Received through the mesh (\(frame.hops) hop\(frame.hops == 1 ? "" : "s")).") }
            }
        } catch { status(error.localizedDescription) }
    }
    private func pinKeys(_ note: KeyAnnouncement, from peer: String) {
        guard note.id == peer, let book = contactBook, book.profile(for: peer) != nil else { return }
        do {
            if try book.pin(note.keys, for: peer) {
                status("Mesh keys saved for @\(book.profile(for: peer)?.username ?? "contact") (safety code \(note.keys.fingerprint)). They can now be reached through other devices.")
                sync()
            }
        } catch { status(error.localizedDescription) }
    }
    var safetyCode: String { nodeKeys?.publicKeys.fingerprint ?? "unavailable" }
    func reachableViaMesh(_ id: String) -> Bool { contactBook?.keys(for: id) != nil }
    private func authorized(_ e: Envelope, from peer: String) -> Bool {
        guard e.expires > Envelope.now(), contactBook?.allows(e, localIdentity: identity, peerIdentity: peer) == true else { return false }
        switch e.kind {
        case "group":
            guard let group = e.group, group.ownerID == peer else { return false }
            if let old = groupBook?.group(group.id) { return old.ownerID == peer && group.revision >= old.revision }
            return group.contains(identity)
        case "ack", "media_ready":
            guard let original = engine?.store.active().first(where: { $0.id == e.ackFor && $0.sender == identity }),
                  original.groupID == e.groupID, original.groupRevision == e.groupRevision else { return false }
            if e.kind == "media_ready", original.kind != "media" { return false }
            if let id = original.groupID, original.kind != "group" {
                guard let group = groupBook?.group(id) else { return false }
                return group.contains(identity) && group.contains(peer) && group.revision == original.groupRevision
            }
            return original.to == peer
        case "text", "media":
            return e.groupID == nil || groupBook?.permits(e, local: identity, peer: peer) == true
        default: return false
        }
    }
    private func receive(_ data: Data, from peer: String) {
        if let frame = try? SealedFrame.decode(data) { relayed(frame, from: peer); return }
        if let note = try? KeyAnnouncement.decode(data) { pinKeys(note, from: peer); return }
        do { try process(Envelope.decode(data), data: data, from: peer) } catch { status(error.localizedDescription) }
    }
    /// `peer` is the authenticated author: the direct link, or the verified sender of a sealed frame.
    private func process(_ e: Envelope, data: Data, from peer: String) throws {
        do {
            guard authorized(e, from: peer), let engine else { return }
            switch e.kind {
            case "group":
                guard let group = e.group else { return }
                let old = groupBook?.group(group.id)
                try groupBook?.apply(group, from: peer)
                if old != group { transport?.cancelFiles() }
                engine.receive(data, from: peer); try engine.acknowledge(e); refresh()
            case "media_ready":
                guard let original = engine.store.active().first(where: { $0.id == e.ackFor }), let media = original.media,
                      let url = try vault?.url(for: media), vault?.available(media) == true else { return }
                transport?.sendFile(url, name: original.id, to: peer)
            case "media":
                engine.receive(data, from: peer)
                guard let saved = engine.store.active().first(where: { $0.id == e.id }), saved == e else { return }
                if let media = e.media, vault?.available(media) == true { try engine.acknowledge(e) }
                else { transport?.send(try Envelope.ready(sender: identity, for: e).encoded(), to: peer) }
            default: engine.receive(data, from: peer)
            }
        } catch { status(error.localizedDescription) }
    }
    private func attachment(_ id: String, from peer: String) -> Envelope? {
        guard let e = engine?.store.active().first(where: { $0.id == id && $0.kind == "media" }), authorized(e, from: peer) else { return nil }
        return e
    }
    private func receiveFile(_ url: URL, name: String, from peer: String) {
        do {
            guard let e = attachment(name, from: peer), let media = e.media else { return }
            try vault?.install(url, as: media)
            try engine?.acknowledge(e); refresh(); status("\(media.kind.capitalized) received and verified.")
        } catch { status("Attachment rejected: \(error.localizedDescription)") }
    }
    private func sync() {
        // Membership updates precede content, and are renewed after their delivery envelope expires.
        if let engine, let groupBook {
            for group in groupBook.groups where group.ownerID == identity {
                for member in groupBook.audience(group.id) where member.id != identity && isConnected(member.id) {
                    let exists = engine.store.active().contains { $0.kind == "group" && $0.group == group && $0.to == member.id }
                    if !exists { do { try engine.submit(Envelope.groupUpdate(group, to: member.id)) } catch { status(error.localizedDescription) } }
                }
            }
            let updates = engine.store.active().filter { $0.kind == "group" }
            for e in updates { if let data = try? e.encoded() { transmit(data) } }
            engine.sync()
            router?.flush()
            transport?.autoConnect()
            // Re-announced every sync: the other side may not have saved us as a contact yet on first connect.
            if let keys = nodeKeys?.publicKeys, let note = try? JSONEncoder().encode(KeyAnnouncement(id: identity, keys: keys)) {
                for peer in connected { transport?.send(note, to: peer.id) }
            }
        }
        refresh()
    }
    func saveUsername() {
        guard let book = contactBook else { usernameFailed = true; usernameMessage = "Storage unavailable on this device."; return }
        do {
            try book.setUsername(usernameDraft)
            username = book.username; usernameDraft = book.username
            if let profile = try? ChatProfile(id: identity, username: username) { transport?.updateProfile(profile) }
            usernameFailed = false
            usernameMessage = "Saved as @\(username). Connected people see the new name after they reconnect."
            status("Username saved. It is discoverable nearby, not globally registered.")
        } catch { usernameFailed = true; usernameMessage = error.localizedDescription; status(error.localizedDescription) }
    }
    func start() {
        guard !running, engine != nil, let profile = try? ChatProfile(id: identity, username: username) else { return }
        let transport = MultipeerTransport(profile: profile); self.transport = transport
        transport.discovered = { [weak self] peer in guard let self else { return }; self.nearby.removeAll { $0.id == peer.id }; self.nearby.append(peer) }
        transport.lost = { [weak self] name in self?.nearby.removeAll { $0.peer.displayName == name } }
        transport.connected = { [weak self] profile in
            guard let self, let book = self.contactBook else { return false }
            do { try book.accept(profile); self.contacts = book.contacts; return true }
            catch { self.status("Could not save contact: \(error.localizedDescription)"); return false }
        }
        transport.connectionChanged = { [weak self] peers in
            guard let self else { return }
            self.connected = peers
            self.router?.setPeers(Set(peers.map(\.id)))
            self.sync()
        }
        transport.requestChanged = { [weak self] id, pending in if pending { self?.pendingRequests.insert(id) } else { self?.pendingRequests.remove(id) } }
        transport.incoming = { [weak self] data, peer in self?.receive(data, from: peer) }
        transport.allowResource = { [weak self] name, peer in self?.attachment(name, from: peer) != nil }
        transport.incomingResource = { [weak self] url, name, peer in self?.receiveFile(url, name: name, from: peer) }
        transport.status = { [weak self] text in self?.status(text) }
        transport.isFriend = { [weak self] id in self?.contactBook?.keys(for: id) != nil }
        transport.signInvite = { [weak self] to, name, time in
            guard let self, let keys = self.nodeKeys else { return nil }
            return InviteProof.sign(keys: keys, from: self.identity, to: to, peerName: name, time: time)
        }
        transport.verifyInvite = { [weak self] profile, name, time, sig in
            guard let self, let keys = self.contactBook?.keys(for: profile.id) else { return false }
            return InviteProof.verify(sig, keys: keys, from: profile.id, to: self.identity, peerName: name, time: time)
        }
        transport.invitation = { [weak self] profile, reply in guard let self, self.invitationReply == nil else { reply(false); return }; self.invitationReply = reply; self.pendingInvitation = profile }
        running = true; transport.start()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.sync() }
        status("Nearby discovery started. Friends reconnect automatically when they are nearby with the app open.")
    }
    /// Whether the mesh should run whenever the app is open. On by default; the Stop button turns it off.
    var meshEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "meshEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "meshEnabled") }
    }
    func setMesh(_ on: Bool) { meshEnabled = on; on ? start() : stop() }
    func resume() { if meshEnabled { start() } }
    func stop() {
        answerInvitation(false); recorder.cancel(); recording = false; requestingMicrophone = false
        timer?.invalidate(); timer = nil; transport?.stop(); transport = nil
        running = false; nearby = []; connected = []; pendingRequests = []; router?.setPeers([])
    }
    func invite(_ peer: NearbyPeer) { if !pendingRequests.contains(peer.id) { transport?.invite(peer) } }
    func answerInvitation(_ accept: Bool) { let reply = invitationReply; invitationReply = nil; pendingInvitation = nil; reply?(accept) }
    func send(_ text: String) -> Bool {
        guard canCompose, let engine else { status("Start the network and select a chat you belong to."); return false }
        do {
            var e = try Envelope.message(sender: identity, text: text.trimmingCharacters(in: .whitespacesAndNewlines), to: selectedContactID)
            if let group = selectedGroup { e.groupID = group.id; e.groupRevision = group.revision }
            try engine.submit(e); return true
        } catch { status(error.localizedDescription); return false }
    }
    func editGroup(_ group: MeshGroup? = nil) {
        guard !recording, !requestingMicrophone, !preparingMedia else { return }
        editingGroupID = group?.id; groupName = group?.name ?? ""; groupError = nil
        groupMembers = Set(group?.members.map(\.id).filter { $0 != identity } ?? [])
        showGroupEditor = true
    }
    func saveGroup() {
        guard let book = groupBook, let me = try? ChatProfile(id: identity, username: username) else {
            groupError = "Group storage is unavailable on this device."; return
        }
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { groupError = "Type a group name first."; return }
        if name.utf16.count > 60 { groupError = "Group name must be 60 characters or fewer."; return }
        if groupMembers.isEmpty { groupError = "Choose at least one contact to add."; return }
        if groupMembers.count > 15 { groupError = "Choose at most 15 other members."; return }
        groupError = nil
        do {
            let old = editingGroupID.flatMap { book.group($0) }
            if let old, old.ownerID != identity { throw FeatureError.ownerOnly }
            let candidates = contacts + (old?.members.filter { !contacts.contains($0) } ?? [])
            var members = [me]
            for profile in candidates where groupMembers.contains(profile.id) && !members.contains(where: { $0.id == profile.id }) { members.append(profile) }
            let group = MeshGroup(id: old?.id ?? UUID().uuidString.lowercased(), ownerID: identity,
                                  name: name, revision: (old?.revision ?? 0) + 1, members: members)
            try book.apply(group, from: identity); transport?.cancelFiles()
            showGroupEditor = false; groups = book.groups; selectGroup(group.id); sync()
            status("Group saved. Membership changes reach people when they reconnect with you.")
        } catch { groupError = error.localizedDescription; status(error.localizedDescription) }
    }
    func chooseMedia(_ kind: String) { guard canCompose, !recording else { return }; importKind = kind; showImporter = true }
    func importFile(_ url: URL, kind: String) {
        guard canCompose, !recording, let engine, let vault else { return }
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            refresh() // Remove expired attachments before checking the local storage quota.
            let media = try vault.importFile(url, kind: kind)
            try engine.submit(Envelope.attachment(sender: identity, media: media, to: selectedContactID, group: selectedGroup))
            status("\(kind.capitalized) queued. Delivery is confirmed after the recipient verifies the file.")
        } catch { refresh(); status(error.localizedDescription) }
    }
    func toggleRecording() {
        if recording { recorder.finish(); return }
        guard canCompose, !requestingMicrophone else { return }
        requestingMicrophone = true
        recorder.requestPermission { [weak self] allowed in
            guard let self, self.requestingMicrophone else { return }; self.requestingMicrophone = false
            guard allowed, self.canCompose else { self.status("Microphone access is required for voice messages. Enable it in system settings."); return }
            do {
                try self.recorder.start { [weak self] result in
                    guard let self else { return }; self.recording = false
                    switch result {
                    case .success(let url): self.importFile(url, kind: "audio"); try? FileManager.default.removeItem(at: url)
                    case .failure(let error): self.status(error.localizedDescription)
                    }
                }
                self.recording = true; self.recordingStarted = Date(); self.status("Recording voice message, up to 2 minutes. Tap Send recording when finished.")
            } catch { self.recorder.cancel(); self.status(error.localizedDescription) }
        }
    }
    func cancelRecording() { recorder.cancel(); recording = false; requestingMicrophone = false }
    func mediaAvailable(_ e: Envelope) -> Bool { e.media.map { vault?.available($0) == true } ?? false }
    func play(_ e: Envelope) { guard let media = e.media, mediaAvailable(e), let url = try? vault?.url(for: media) else { return }; player = AVPlayer(url: url); showPlayer = true; player?.play() }
    func endPlayback() { player?.pause(); player = nil; showPlayer = false }
    func senderName(_ id: String) -> String { id == identity ? "You" : "@" + (contacts.first { $0.id == id }?.username ?? selectedGroup?.members.first { $0.id == id }?.username ?? String(id.prefix(8))) }
    func deliveryStatus(_ e: Envelope) -> String {
        let count = receipts[e.id]?.count ?? 0
        if let id = e.groupID {
            let delivered = "Delivered to \(count) member\(count == 1 ? "" : "s")"
            if groupBook?.group(id)?.revision != e.groupRevision { return delivered + "; queued delivery stopped after membership changed" }
            return delivered
        }
        if count > 0 { return "Delivered to app" }
        guard let to = e.to, !isConnected(to) else { return "Awaiting delivery" }
        if router?.store.contains(SealedFrame.frameID(inner: e.id, to: to)) == true { return "In the mesh: any connected device can carry it" }
        if e.kind == "media" { return "Waiting for a direct connection (files are not relayed)" }
        return reachableViaMesh(to) ? "Queued for the mesh" : "Waiting for a direct connection (meet once on v0.5 to enable relay)"
    }
    /// SF Symbol for the bubble: queued, travelling through the mesh, or delivered.
    func deliveryIcon(_ e: Envelope) -> String {
        if (receipts[e.id]?.count ?? 0) > 0 { return "checkmark.circle.fill" }
        if e.groupID == nil, let to = e.to, router?.store.contains(SealedFrame.frameID(inner: e.id, to: to)) == true { return "point.3.connected.trianglepath.dotted" }
        return "clock"
    }
    private func preview(_ e: Envelope?, group: Bool) -> String {
        guard let e else { return group ? "Group created" : "Tap to start chatting" }
        let body = e.media.map { $0.kind == "audio" ? "🎵 Audio" : "🎬 Video" } ?? (e.text ?? "")
        let who = e.sender == identity ? "You: " : group ? senderName(e.sender) + ": " : ""
        return who + body
    }
    private func refresh() {
        guard let engine else { return }
        groups = groupBook?.groups ?? []
        let active = engine.store.active()
        messages = Array(active.filter { e in
            guard e.kind == "text" || e.kind == "media" else { return false }
            if let selectedGroupID { return e.groupID == selectedGroupID }
            guard e.groupID == nil, let selectedContactID else { return false }
            return (e.sender == identity && e.to == selectedContactID) || (e.sender == selectedContactID && e.to == identity)
        }.suffix(100))
        var grouped: [String: Set<String>] = [:]
        for e in active where e.kind == "ack" && e.to == identity { if let id = e.ackFor { grouped[id, default: []].insert(e.sender) } }
        receipts = grouped
        relayCarried = router?.carriedCount() ?? 0
        let visible = active.filter { $0.kind == "text" || $0.kind == "media" }
        var summaries: [ChatSummary] = []
        for contact in contacts {
            let last = visible.last { $0.groupID == nil && (($0.sender == identity && $0.to == contact.id) || ($0.sender == contact.id && $0.to == identity)) }
            summaries.append(ChatSummary(id: "c:" + contact.id, title: contact.username, isGroup: false, preview: preview(last, group: false), lastTime: last?.created, online: isConnected(contact.id)))
        }
        for group in groups {
            let last = visible.last { $0.groupID == group.id }
            summaries.append(ChatSummary(id: "g:" + group.id, title: group.name, isGroup: true, preview: preview(last, group: true), lastTime: last?.created, online: false))
        }
        chatList = summaries.sorted { ($0.lastTime ?? 0, $1.title) > ($1.lastTime ?? 0, $0.title) }
        vault?.prune(keeping: Set(active.compactMap { $0.media?.id }))
    }
    func status(_ text: String) { log.append(text); if log.count > 50 { log.removeFirst(log.count - 50) } }
}

final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var completion: ((Result<URL, Error>) -> Void)?
    func requestPermission(_ reply: @escaping (Bool) -> Void) {
        #if os(iOS)
        AVAudioApplication.requestRecordPermission { allowed in DispatchQueue.main.async { reply(allowed) } }
        #else
        AVCaptureDevice.requestAccess(for: .audio) { allowed in DispatchQueue.main.async { reply(allowed) } }
        #endif
    }
    func start(completion: @escaping (Result<URL, Error>) -> Void) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker]); try session.setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48000])
        recorder.delegate = self
        guard recorder.prepareToRecord(), recorder.record(forDuration: 120) else { throw FeatureError.invalidMedia }
        self.recorder = recorder; self.completion = completion
    }
    func finish() { recorder?.stop() }
    func cancel() {
        let old = recorder; completion = nil; recorder = nil; old?.stop()
        if let old { try? FileManager.default.removeItem(at: old.url) }; releaseAudioSession()
    }
    private func releaseAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let callback = completion; completion = nil; self.recorder = nil; releaseAudioSession()
        if flag { callback?(.success(recorder.url)) }
        else { try? FileManager.default.removeItem(at: recorder.url); callback?(.failure(FeatureError.invalidMedia)) }
    }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let callback = completion; cancel(); callback?(.failure(error ?? FeatureError.invalidMedia))
    }
}
