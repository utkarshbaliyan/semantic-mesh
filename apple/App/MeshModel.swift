import Foundation
import Combine

final class MeshModel: ObservableObject {
    @Published var draft = ""
    @Published var search = ""
    @Published var usernameDraft = ""
    @Published private(set) var username = ""
    @Published var nearby: [NearbyPeer] = []
    @Published var contacts: [ChatProfile] = []
    @Published var connected: [ChatProfile] = []
    @Published var pendingRequests: Set<String> = []
    @Published var selectedContactID: String? { didSet { draft = ""; refresh() } }
    @Published var messages: [Envelope] = []
    @Published var receipts: [String: Set<String>] = [:]
    @Published var log: [String] = []
    @Published var running = false
    @Published var pendingInvitation: ChatProfile?
    let identity: String
    private var contactBook: ContactBook?
    private var invitationReply: ((Bool) -> Void)?
    private var transport: MultipeerTransport?
    private var engine: MeshEngine?
    private var timer: Timer?

    var selectedContact: ChatProfile? { contacts.first { $0.id == selectedContactID } }
    var filteredNearby: [NearbyPeer] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "@", with: "")
        return nearby.filter { term.isEmpty || $0.profile.username.contains(term) || $0.id.hasPrefix(term) }
    }
    func isConnected(_ id: String) -> Bool { connected.contains { $0.id == id } }

    init() {
        var nodeID = UUID().uuidString.lowercased()
        var storage: MessageStore?
        var book: ContactBook?
        var storageError: Error?
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var directory = support.appendingPathComponent("org.semanticmesh.apple")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let identityFile = directory.appendingPathComponent("node-id.txt")
            if FileManager.default.fileExists(atPath: identityFile.path) {
                let saved = try String(contentsOf: identityFile, encoding: .utf8)
                guard UUID(uuidString: saved) != nil else { throw MeshError.invalidEnvelope }
                nodeID = saved
            } else { try nodeID.write(to: identityFile, atomically: true, encoding: .utf8) }
            storage = try MessageStore(file: directory.appendingPathComponent("messages.json"))
            book = try ContactBook(file: directory.appendingPathComponent("contacts.json"), defaultUsername: "mesh_" + nodeID.prefix(6))
        } catch { storageError = error }
        identity = nodeID
        if let store = storage, let book {
            contactBook = book; username = book.username; usernameDraft = book.username; contacts = book.contacts
            selectedContactID = contacts.first?.id
            let engine = MeshEngine(identity: identity, store: store)
            self.engine = engine
            engine.transmit = { [weak self] data, _ in
                guard let self, let e = try? Envelope.decode(data), e.sender == self.identity,
                      let to = e.to, self.contactBook?.profile(for: to) != nil else { return }
                self.transport?.send(data, to: to)
            }
            engine.authorizeIncoming = { [weak self] e, peer in
                guard let self, self.contactBook?.allows(e, localIdentity: self.identity, peerIdentity: peer) == true else { return false }
                if e.kind == "ack" {
                    return store.active().contains { $0.id == e.ackFor && $0.sender == self.identity && $0.to == peer }
                }
                return true
            }
            engine.received = { [weak self] _ in self?.refresh() }
            engine.error = { [weak self] error in self?.status(error.localizedDescription) }
            refresh()
        } else { status("Storage unavailable: \(storageError?.localizedDescription ?? "unknown error"). Sending is disabled.") }
    }
    func saveUsername() {
        guard let book = contactBook else { return }
        do {
            try book.setUsername(usernameDraft)
            let restart = running
            if restart { stop() }
            username = book.username; usernameDraft = book.username
            if restart { start() }
            status("Username saved. It is discoverable nearby, not globally registered.")
        } catch { status(error.localizedDescription) }
    }
    func start() {
        guard !running, engine != nil, let profile = try? ChatProfile(id: identity, username: username) else { return }
        let transport = MultipeerTransport(profile: profile)
        self.transport = transport
        transport.discovered = { [weak self] peer in
            guard let self else { return }
            self.nearby.removeAll { $0.id == peer.id }; self.nearby.append(peer)
        }
        transport.lost = { [weak self] name in self?.nearby.removeAll { $0.peer.displayName == name } }
        transport.connected = { [weak self] profile in
            guard let self, let book = self.contactBook else { return false }
            do {
                try book.accept(profile); self.contacts = book.contacts
                if self.selectedContactID == nil { self.selectedContactID = profile.id }
                return true
            } catch { self.status("Could not save contact: \(error.localizedDescription)"); return false }
        }
        transport.connectionChanged = { [weak self] peers in self?.connected = peers; self?.engine?.sync() }
        transport.requestChanged = { [weak self] id, pending in
            if pending { self?.pendingRequests.insert(id) } else { self?.pendingRequests.remove(id) }
        }
        transport.incoming = { [weak self] data, peer in self?.engine?.receive(data, from: peer) }
        transport.status = { [weak self] text in self?.status(text) }
        transport.invitation = { [weak self] profile, reply in
            guard let self, self.invitationReply == nil else { reply(false); return }
            self.invitationReply = reply; self.pendingInvitation = profile
        }
        running = true; transport.start()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.engine?.sync(); self?.refresh() }
        status("Nearby username discovery started. Both devices must run this chat version.")
    }
    func stop() {
        answerInvitation(false)
        timer?.invalidate(); timer = nil
        transport?.stop(); transport = nil
        running = false; nearby = []; connected = []; pendingRequests = []
    }
    func invite(_ peer: NearbyPeer) { if !pendingRequests.contains(peer.id) { transport?.invite(peer) } }
    func answerInvitation(_ accept: Bool) {
        let reply = invitationReply
        invitationReply = nil; pendingInvitation = nil
        reply?(accept)
    }
    func send(_ text: String) -> Bool {
        guard running, let engine, let contact = selectedContact, contactBook?.profile(for: contact.id) != nil else {
            status("Start the network and select an accepted contact."); return false
        }
        do {
            try engine.send(text: text.trimmingCharacters(in: .whitespacesAndNewlines), to: contact.id)
            if !isConnected(contact.id) { status("Queued for \(contact.label). Reconnect within one hour to deliver.") }
            return true
        } catch { status(error.localizedDescription); return false }
    }
    private func refresh() {
        guard let engine else { return }
        let active = engine.store.active()
        messages = Array(active.filter { e in
            guard let selectedContactID else { return false }
            return e.kind == "text" && ((e.sender == identity && e.to == selectedContactID) || (e.sender == selectedContactID && e.to == identity))
        }.suffix(100))
        var grouped: [String: Set<String>] = [:]
        for e in active where e.kind == "ack" && e.to == identity {
            if let id = e.ackFor { grouped[id, default: []].insert(e.sender) }
        }
        receipts = grouped
    }
    private func status(_ text: String) { log.append(text); if log.count > 50 { log.removeFirst(log.count - 50) } }
}
