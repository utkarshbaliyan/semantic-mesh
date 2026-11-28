import Foundation
import MultipeerConnectivity

struct NearbyPeer: Identifiable {
    let profile: ChatProfile
    let peer: MCPeerID
    /// The signing public key the peer advertises, so we can show username#TAG before connecting.
    let signKey: String?
    var id: String { profile.id }
    var name: String { profile.label }
    var tag: String { signKey.map { PeerKeys.tag(forSignKey: $0) } ?? "----" }
}

/// Session invitations are explicit chat requests. Only approved peers may exchange direct frames.
/// Friends (contacts whose keys are pinned) reconnect on their own: whenever one is discovered and not connected,
/// a signed invitation is sent, and the friend accepts it without a prompt after checking the signature.
/// Each remote peer gets its own MCSession: a shared session lets Multipeer join third devices to each other
/// without an approved request, which then blocks the real request between them.
final class MultipeerTransport: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    private struct Request: Codable {
        let profile: ChatProfile; let to: String
        /// Present when the inviter could sign with its pinned keys; `auto` marks background reconnects.
        var time: Int64? = nil; var sig: String? = nil; var auto: Bool? = nil
        /// A relay-only link: no chat, no contact, carries sealed frames for the mesh only.
        var relay: Bool? = nil
    }
    private var localProfile: ChatProfile
    /// This device's advertised signing public key (base64), so peers can show our tag before connecting.
    private let localSign: String
    private let localPeer: MCPeerID
    private var sessions: [MCPeerID: MCSession] = [:]
    private var advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var approved: [MCPeerID: ChatProfile] = [:]
    private var active = false
    private var transfers: [String: Progress] = [:]
    /// Latest advertisement per identity; a peer that restarts the app comes back with a new MCPeerID.
    private var found: [String: NearbyPeer] = [:]
    private var usedProofs: Set<String> = []
    /// Relay-only links to non-contacts (peer → their device id), used to carry sealed frames for the mesh.
    private var relayLinks: [MCPeerID: (session: MCSession, id: String)] = [:]
    private let maxRelayPeers = 8
    /// Per-peer hourly accept budget: at most 200 frames and 5 MB from each relay-only peer.
    private var relayBudget: [String: (count: Int, bytes: Int, start: Int64)] = [:]
    /// When true, this device carries frames for any nearby app user, not only friends.
    var carryForOthers = false
    var relayConnectionsChanged: ([String]) -> Void = { _ in }
    var relayLinkOpened: (String) -> Void = { _ in }
    var incomingRelay: (Data, String) -> Void = { _, _ in }
    /// True for contacts this device can reconnect to automatically (keys pinned).
    var isFriend: (String) -> Bool = { _ in false }
    var signInvite: (_ to: String, _ peerName: String, _ time: Int64) -> String? = { _, _, _ in nil }
    var verifyInvite: (_ profile: ChatProfile, _ peerName: String, _ time: Int64, _ sig: String) -> Bool = { _, _, _, _ in false }
    var discovered: (NearbyPeer) -> Void = { _ in }
    var lost: (String) -> Void = { _ in }
    var connected: (ChatProfile) -> Bool = { _ in false }
    var connectionChanged: ([ChatProfile]) -> Void = { _ in }
    var requestChanged: (String, Bool) -> Void = { _, _ in }
    var incoming: (Data, String) -> Void = { _, _ in }
    var allowResource: (String, String) -> Bool = { _, _ in false }
    var incomingResource: (URL, String, String) -> Void = { _, _, _ in }
    var invitation: (ChatProfile, @escaping (Bool) -> Void) -> Void = { _, reply in reply(false) }
    var status: (String) -> Void = { _ in }

    init(profile: ChatProfile, signKey: String) {
        localProfile = profile
        localSign = signKey
        let local = MCPeerID(displayName: "@\(profile.username)-\(profile.id.prefix(8))")
        localPeer = local
        advertiser = Self.makeAdvertiser(local, profile, signKey)
        browser = MCNearbyServiceBrowser(peer: local, serviceType: "semantic-mesh")
        super.init()
        advertiser.delegate = self; browser.delegate = self
    }
    private static func makeAdvertiser(_ peer: MCPeerID, _ profile: ChatProfile, _ sign: String) -> MCNearbyServiceAdvertiser {
        // "chat" is the discovery protocol version; 4 adds the advertised signing key (0.6.0 wire format).
        MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["protocol": "1", "chat": "4", "id": profile.id, "username": profile.username, "sign": sign], serviceType: "semantic-mesh")
    }
    /// The signing key a nearby peer advertised, used to reject a connect whose announced key doesn't match.
    func advertisedSign(for id: String) -> String? { found[id]?.signKey }
    /// Re-advertises the new username without dropping existing chat sessions.
    func updateProfile(_ profile: ChatProfile) {
        guard profile.id == localProfile.id else { return }
        localProfile = profile
        advertiser.stopAdvertisingPeer(); advertiser.delegate = nil
        advertiser = Self.makeAdvertiser(localPeer, profile, localSign); advertiser.delegate = self
        if active { advertiser.startAdvertisingPeer() }
    }
    private func makeSession(for peer: MCPeerID) -> MCSession {
        sessions[peer]?.disconnect()
        let session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        sessions[peer] = session
        return session
    }
    private func isConnected(_ peer: MCPeerID) -> Bool { sessions[peer]?.connectedPeers.contains(peer) == true }
    private func connectedPeers() -> [MCPeerID] { sessions.keys.filter { isConnected($0) } }
    private func dropSession(for peer: MCPeerID, ifSame session: MCSession? = nil) {
        guard let current = sessions[peer], session == nil || current === session else { return }
        current.delegate = nil; current.disconnect(); sessions.removeValue(forKey: peer)
    }
    func start() { active = true; advertiser.startAdvertisingPeer(); browser.startBrowsingForPeers() }
    func stop() { active = false; found.removeAll(); usedProofs.removeAll(); relayBudget.removeAll(); advertiser.stopAdvertisingPeer(); browser.stopBrowsingForPeers(); transfers.values.forEach { $0.cancel() }; transfers.removeAll(); sessions.values.forEach { $0.delegate = nil; $0.disconnect() }; sessions.removeAll(); relayLinks.values.forEach { $0.session.delegate = nil; $0.session.disconnect() }; relayLinks.removeAll(); approved.removeAll() }
    /// Enables or disables carrying frames for non-contacts. Turning it off drops all relay-only links.
    func setCarryForOthers(_ on: Bool) {
        carryForOthers = on
        if !on { for (peer, _) in relayLinks { dropRelay(peer) }; relayConnectionsChanged([]) }
        else { connectRelayPeers() }
    }
    func relayPeerIDs() -> [String] { Array(Set(relayLinks.compactMap { $0.value.session.connectedPeers.contains($0.key) ? $0.value.id : nil })) }
    func cancelFiles() { transfers.values.forEach { $0.cancel() }; transfers.removeAll() }
    func sendFile(_ url: URL, name: String, to identity: String) {
        guard active, UUID(uuidString: name) != nil,
              let peer = connectedPeers().first(where: { approved[$0]?.id == identity }),
              let session = sessions[peer] else { return }
        let key = identity + ":" + name
        guard transfers[key] == nil, transfers.count < 2 else { return }
        let progress = session.sendResource(at: url, withName: name, toPeer: peer) { [weak self] error in
            DispatchQueue.main.async {
                self?.transfers.removeValue(forKey: key)
                if let error { self?.status("Attachment transfer failed: \(error.localizedDescription). Retrying while the message is live.") }
            }
        }
        if let progress { transfers[key] = progress }
    }
    func invite(_ peer: NearbyPeer, automatic: Bool = false) {
        guard active, peer.id != localProfile.id, !isConnected(peer.peer) else { return }
        var request = Request(profile: localProfile, to: peer.id)
        let time = Envelope.now()
        if let sig = signInvite(peer.id, localPeer.displayName, time) { request.time = time; request.sig = sig }
        if automatic { guard request.sig != nil else { return }; request.auto = true }
        guard let context = try? JSONEncoder().encode(request) else { return }
        approved[peer.peer] = peer.profile
        requestChanged(peer.id, true)
        let session = makeSession(for: peer.peer)
        browser.invitePeer(peer.peer, to: session, withContext: context, timeout: 20)
        if !automatic { status("Chat request sent to \(peer.name). Waiting for acceptance.") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.active else { return }
            self.requestChanged(peer.id, false)
            if !self.isConnected(peer.peer) {
                self.dropSession(for: peer.peer, ifSame: session)
                if self.sessions[peer.peer] == nil { self.approved.removeValue(forKey: peer.peer) }
                if !automatic { self.status("Request to \(peer.name) was declined or timed out. You can retry.") }
            }
        }
    }
    /// Invites every friend that is advertising nearby but not connected or already being invited.
    /// On first sight only the lower identity invites, so two friends don't cross invitations; retries come from both.
    func autoConnect(firstSight: Bool = false) {
        guard active else { return }
        for peer in found.values where isFriend(peer.id) && sessions[peer.peer] == nil && !connectedIdentities().contains(peer.id) {
            if firstSight && localProfile.id > peer.id { continue }
            invite(peer, automatic: true)
        }
        connectRelayPeers()
    }
    /// Opens relay-only links to nearby non-contacts, up to the peer limit. The lower identity initiates.
    private func connectRelayPeers() {
        guard active, carryForOthers else { return }
        for peer in found.values where !isFriend(peer.id) && sessions[peer.peer] == nil && relayLinks[peer.peer] == nil {
            guard relayLinks.count < maxRelayPeers else { break }
            guard localProfile.id < peer.id else { continue }
            inviteRelay(peer)
        }
    }
    private func inviteRelay(_ peer: NearbyPeer) {
        guard active, carryForOthers, relayLinks.count < maxRelayPeers, sessions[peer.peer] == nil, relayLinks[peer.peer] == nil,
              let context = try? JSONEncoder().encode(Request(profile: localProfile, to: peer.id, relay: true)) else { return }
        let session = makeRelaySession(for: peer.peer, deviceID: peer.id)
        browser.invitePeer(peer.peer, to: session, withContext: context, timeout: 15)
        DispatchQueue.main.asyncAfter(deadline: .now() + 18) { [weak self] in
            guard let self, let link = self.relayLinks[peer.peer], link.session === session, !session.connectedPeers.contains(peer.peer) else { return }
            self.dropRelay(peer.peer)
        }
    }
    private func makeRelaySession(for peer: MCPeerID, deviceID: String) -> MCSession {
        relayLinks[peer]?.session.disconnect()
        let session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        relayLinks[peer] = (session, deviceID)
        return session
    }
    private func dropRelay(_ peer: MCPeerID) {
        guard let link = relayLinks[peer] else { return }
        link.session.delegate = nil; link.session.disconnect(); relayLinks.removeValue(forKey: peer)
    }
    /// Periodically drops relay-only links so frames reach a fresh set of carriers.
    func rotateRelayPeers() {
        guard active else { return }
        for (peer, _) in relayLinks { dropRelay(peer) }
        relayConnectionsChanged([]); connectRelayPeers()
    }
    /// Enforces the hourly per-peer accept budget for relay-only traffic.
    private func relayAllow(_ id: String, bytes: Int) -> Bool {
        let now = Envelope.now()
        var budget = relayBudget[id] ?? (0, 0, now)
        if now - budget.start > 3_600_000 { budget = (0, 0, now) }
        guard budget.count < 200, budget.bytes + bytes <= 5 * 1024 * 1024 else { relayBudget[id] = budget; return false }
        budget.count += 1; budget.bytes += bytes; relayBudget[id] = budget; return true
    }
    private func handleRelayState(_ peerID: MCPeerID, _ session: MCSession, _ state: MCSessionState) {
        guard let id = relayLinks[peerID]?.id else { return }
        if state == .connected {
            relayConnectionsChanged(relayPeerIDs()); relayLinkOpened(id)
        } else if state == .notConnected {
            dropRelay(peerID); relayConnectionsChanged(relayPeerIDs())
        }
    }
    private func connectedIdentities() -> Set<String> { Set(connectedPeers().compactMap { approved[$0]?.id }) }
    /// Drops links to older MCPeerIDs of the same person, left behind when they restarted the app.
    private func dropStale(_ id: String, keeping peer: MCPeerID) {
        for (other, profile) in approved where profile.id == id && other != peer {
            dropSession(for: other); approved.removeValue(forKey: other)
        }
    }
    func send(_ data: Data, to identity: String) {
        guard active else { return }
        if data.count <= Envelope.maxBytes {
            for peer in connectedPeers() where approved[peer]?.id == identity {
                guard let session = sessions[peer] else { continue }
                do { try session.send(data, toPeers: [peer], with: .reliable) }
                catch { status("Send failed: \(error.localizedDescription)") }
            }
        }
        // Relay-only peers carry sealed frames and digests only.
        for (peer, link) in relayLinks where link.id == identity && link.session.connectedPeers.contains(peer) {
            try? link.session.send(data, toPeers: [peer], with: .reliable)
        }
    }
    private func publishConnections() { connectionChanged(connectedPeers().compactMap { approved[$0] }) }
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, info?["protocol"] == "1", info?["chat"] == "4",
                  let id = info?["id"], let username = info?["username"],
                  let profile = try? ChatProfile(id: id, username: username), profile.id != self.localProfile.id else { return }
            let peer = NearbyPeer(profile: profile, peer: peerID, signKey: info?["sign"])
            self.found[profile.id] = peer
            self.discovered(peer)
            self.autoConnect(firstSight: true)
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active else { return }
            self.found = self.found.filter { $0.value.peer != peerID }
            self.lost(peerID.displayName)
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in self?.status("Discovery failed: \(error.localizedDescription). Check Local Network permission.") }
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in self?.status("Advertising failed: \(error.localizedDescription). Check Local Network permission.") }
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, let context, context.count <= 2048,
                  let request = try? JSONDecoder().decode(Request.self, from: context),
                  let profile = try? request.profile.validated(), request.to == self.localProfile.id, profile.id != self.localProfile.id else {
                invitationHandler(false, nil); return
            }
            if self.isConnected(peerID) { invitationHandler(false, nil); return }
            // Relay-only request: accept silently if we're carrying for others and have room, no contact created.
            if request.relay == true {
                guard self.carryForOthers, self.sessions[peerID] == nil, self.relayLinks[peerID] == nil,
                      self.relayLinks.count < self.maxRelayPeers else { invitationHandler(false, nil); return }
                invitationHandler(true, self.makeRelaySession(for: peerID, deviceID: profile.id)); return
            }
            // Both sides invited each other at once: the lower identity keeps its own request.
            if self.sessions[peerID] != nil, self.localProfile.id < profile.id { invitationHandler(false, nil); return }
            // A friend's signed reconnect is accepted without asking; each signature works once.
            if let time = request.time, let sig = request.sig {
                if !self.usedProofs.contains(sig), self.verifyInvite(profile, peerID.displayName, time, sig) {
                    self.usedProofs.insert(sig)
                    self.dropStale(profile.id, keeping: peerID)
                    self.approved[peerID] = profile
                    invitationHandler(true, self.makeSession(for: peerID)); return
                }
            }
            // Background reconnects never prompt: we may have removed them, or their keys don't match.
            if request.auto == true { invitationHandler(false, nil); return }
            self.invitation(profile) { [weak self] accept in
                guard let self, self.active else { invitationHandler(false, nil); return }
                guard accept else { invitationHandler(false, nil); return }
                self.approved[peerID] = profile
                invitationHandler(true, self.makeSession(for: peerID))
            }
        }
    }
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active else { return }
            if let link = self.relayLinks[peerID], link.session === session { self.handleRelayState(peerID, session, state); return }
            guard self.sessions[peerID] === session else {
                // A link to a peer this session was not created for is never approved.
                if state != .notConnected { session.cancelConnectPeer(peerID) }
                return
            }
            guard let profile = self.approved[peerID] else { self.dropSession(for: peerID, ifSame: session); return }
            if state == .connected {
                self.dropRelay(peerID) // a friend link supersedes any relay-only link to the same peer
                self.dropStale(profile.id, keeping: peerID)
                guard self.connected(profile) else { self.dropSession(for: peerID, ifSame: session); self.approved.removeValue(forKey: peerID); self.publishConnections(); return }
                self.requestChanged(profile.id, false); self.status("Connected: \(profile.label)")
            } else if state == .notConnected {
                self.dropSession(for: peerID, ifSame: session)
                self.requestChanged(profile.id, false); self.status("Disconnected: \(profile.label)")
                // Brief drops are common on Bluetooth; try again while the friend is still advertising.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.autoConnect() }
            }
            self.publishConnections()
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, session.connectedPeers.contains(peerID) else { return }
            if self.sessions[peerID] === session, let profile = self.approved[peerID], data.count <= Envelope.maxBytes {
                self.incoming(data, profile.id); return
            }
            // Relay-only traffic: capped larger (digests) and rate-limited per peer; only frames/digests flow.
            if let link = self.relayLinks[peerID], link.session === session, data.count <= 262_144, self.relayAllow(link.id, bytes: data.count) {
                self.incomingRelay(data, link.id)
            }
        }
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { stream.close() }
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.sessions[peerID] === session, let profile = self.approved[peerID],
                  progress.totalUnitCount > 0, progress.totalUnitCount <= MediaVault.maxBytes,
                  self.allowResource(resourceName, profile.id), self.transfers.count < 2 else { progress.cancel(); return }
            self.transfers[profile.id + ":" + resourceName] = progress
        }
    }
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let profile = self.approved[peerID] else { return }
            self.transfers.removeValue(forKey: profile.id + ":" + resourceName)
            if let error { self.status("Receiving attachment failed: \(error.localizedDescription)") }
        }
        // Multipeer deletes its temporary resource after this callback returns.
        guard error == nil, let localURL, UUID(uuidString: resourceName) != nil,
              let size = try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= MediaVault.maxBytes else { return }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.copyItem(at: localURL, to: copy) } catch { return }
        DispatchQueue.main.async { [weak self] in
            defer { try? FileManager.default.removeItem(at: copy) }
            guard let self, self.active, let profile = self.approved[peerID] else { return }
            self.transfers.removeValue(forKey: profile.id + ":" + resourceName)
            guard self.allowResource(resourceName, profile.id) else { return }
            self.incomingResource(copy, resourceName, profile.id)
        }
    }
}
