import Foundation
import MultipeerConnectivity

struct NearbyPeer: Identifiable {
    let profile: ChatProfile
    let peer: MCPeerID
    var id: String { profile.id }
    var name: String { profile.label }
}

/// Session invitations are explicit chat requests. Only approved peers may exchange direct frames.
final class MultipeerTransport: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    private struct Request: Codable { let profile: ChatProfile; let to: String }
    private let localProfile: ChatProfile
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var approved: [MCPeerID: ChatProfile] = [:]
    private var active = false
    private var transfers: [String: Progress] = [:]
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

    init(profile: ChatProfile) {
        localProfile = profile
        let local = MCPeerID(displayName: "@\(profile.username)-\(profile.id.prefix(8))")
        session = MCSession(peer: local, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: local, discoveryInfo: ["protocol": "1", "chat": "2", "id": profile.id, "username": profile.username], serviceType: "semantic-mesh")
        browser = MCNearbyServiceBrowser(peer: local, serviceType: "semantic-mesh")
        super.init()
        session.delegate = self; advertiser.delegate = self; browser.delegate = self
    }
    func start() { active = true; advertiser.startAdvertisingPeer(); browser.startBrowsingForPeers() }
    func stop() { active = false; advertiser.stopAdvertisingPeer(); browser.stopBrowsingForPeers(); transfers.values.forEach { $0.cancel() }; transfers.removeAll(); session.disconnect(); approved.removeAll() }
    func cancelFiles() { transfers.values.forEach { $0.cancel() }; transfers.removeAll() }
    func sendFile(_ url: URL, name: String, to identity: String) {
        guard active, UUID(uuidString: name) != nil,
              let peer = session.connectedPeers.first(where: { approved[$0]?.id == identity }) else { return }
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
    func invite(_ peer: NearbyPeer) {
        guard active, peer.id != localProfile.id, !session.connectedPeers.contains(peer.peer) else { return }
        guard let context = try? JSONEncoder().encode(Request(profile: localProfile, to: peer.id)) else { return }
        approved[peer.peer] = peer.profile
        requestChanged(peer.id, true)
        browser.invitePeer(peer.peer, to: session, withContext: context, timeout: 20)
        status("Chat request sent to \(peer.name). Waiting for acceptance.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.active else { return }
            self.requestChanged(peer.id, false)
            if !self.session.connectedPeers.contains(peer.peer) {
                self.approved.removeValue(forKey: peer.peer)
                self.status("Request to \(peer.name) was declined or timed out. You can retry.")
            }
        }
    }
    func send(_ data: Data, to identity: String) {
        guard active, data.count <= Envelope.maxBytes else { return }
        for peer in session.connectedPeers where approved[peer]?.id == identity {
            do { try session.send(data, toPeers: [peer], with: .reliable) }
            catch { status("Send failed: \(error.localizedDescription)") }
        }
    }
    private func publishConnections() { connectionChanged(session.connectedPeers.compactMap { approved[$0] }) }
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, info?["protocol"] == "1", info?["chat"] == "2",
                  let id = info?["id"], let username = info?["username"],
                  let profile = try? ChatProfile(id: id, username: username), profile.id != self.localProfile.id else { return }
            self.discovered(NearbyPeer(profile: profile, peer: peerID))
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in guard let self, self.active else { return }; self.lost(peerID.displayName) }
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
            self.invitation(profile) { [weak self] accept in
                guard let self, self.active else { invitationHandler(false, nil); return }
                if accept { self.approved[peerID] = profile }
                invitationHandler(accept, accept ? self.session : nil)
            }
        }
    }
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, let profile = self.approved[peerID] else { return }
            if state == .connected {
                guard self.connected(profile) else { self.approved.removeValue(forKey: peerID); self.publishConnections(); return }
                self.requestChanged(profile.id, false); self.status("Connected: \(profile.label)")
            } else if state == .notConnected {
                self.requestChanged(profile.id, false); self.status("Disconnected: \(profile.label)")
            }
            self.publishConnections()
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= Envelope.maxBytes else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, let profile = self.approved[peerID], session.connectedPeers.contains(peerID) else { return }
            self.incoming(data, profile.id)
        }
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { stream.close() }
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, let profile = self.approved[peerID],
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
