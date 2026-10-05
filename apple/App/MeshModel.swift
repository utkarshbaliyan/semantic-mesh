import Foundation
import Combine

final class MeshModel: ObservableObject {
    @Published var draft = ""
    @Published var nearby: [NearbyPeer] = []
    @Published var connected: [String] = []
    @Published var messages: [Envelope] = []
    @Published var receipts: [String: Set<String>] = [:]
    @Published var log: [String] = []
    @Published var running = false
    @Published var pendingInvitation: String?
    let identity: String
    private var invitationReply: ((Bool) -> Void)?
    private var transport: MultipeerTransport?
    private var engine: MeshEngine?
    private var timer: Timer?

    init() {
        var nodeID = UUID().uuidString.lowercased()
        var storage: MessageStore?
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
        } catch { storageError = error }
        identity = nodeID
        if let store = storage {
            let engine = MeshEngine(identity: identity, store: store)
            self.engine = engine
            engine.transmit = { [weak self] data, peer in self?.transport?.send(data, excluding: peer) }
            engine.received = { [weak self] _ in self?.refresh() }
            engine.error = { [weak self] error in self?.status(error.localizedDescription) }
            refresh()
        } else { status("Storage unavailable: \(storageError?.localizedDescription ?? "unknown error"). Sending is disabled.") }
    }
    func start() {
        guard !running, engine != nil else { return }
        let transport = MultipeerTransport(identity: identity)
        self.transport = transport
        transport.discovered = { [weak self] peer in
            guard let self else { return }
            self.nearby.removeAll { $0.id == peer.id }; self.nearby.append(peer)
        }
        transport.lost = { [weak self] token in self?.nearby.removeAll { $0.id == token } }
        transport.connectionChanged = { [weak self] peers in self?.connected = peers; self?.engine?.sync() }
        transport.incoming = { [weak self] data, peer in self?.engine?.receive(data, from: peer) }
        transport.status = { [weak self] text in self?.status(text) }
        transport.invitation = { [weak self] name, reply in
            guard let self, self.invitationReply == nil else { reply(false); return }
            self.invitationReply = reply; self.pendingInvitation = name
        }
        running = true; transport.start()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.engine?.sync(); self?.refresh() }
        status("Nearby discovery started. Keep Wi-Fi enabled; internet is not required.")
    }
    func stop() {
        answerInvitation(false)
        timer?.invalidate(); timer = nil
        transport?.stop(); transport = nil
        running = false; nearby = []; connected = []
    }
    func invite(_ peer: NearbyPeer) { transport?.invite(peer.peer) }
    func answerInvitation(_ accept: Bool) {
        let reply = invitationReply
        invitationReply = nil; pendingInvitation = nil
        reply?(accept)
    }
    func send(_ text: String) -> Bool {
        guard running, let engine else { status("Start the network first."); return false }
        do {
            try engine.send(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
            if connected.isEmpty { status("Stored locally; awaiting a connection.") }
            return true
        } catch { status(error.localizedDescription); return false }
    }
    private func refresh() {
        guard let engine else { return }
        let active = engine.store.active()
        messages = Array(active.filter { $0.kind == "text" }.suffix(100))
        var grouped: [String: Set<String>] = [:]
        for e in active where e.kind == "ack" && e.to == identity {
            if let id = e.ackFor { grouped[id, default: []].insert(e.sender) }
        }
        receipts = grouped
    }
    private func status(_ text: String) { log.append(text); if log.count > 50 { log.removeFirst(log.count - 50) } }
}
