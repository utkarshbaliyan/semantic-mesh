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
    var discovered: (NearbyPeer) -> Void = { _ in }
    var lost: (String) -> Void = { _ in }
    var connected: (ChatProfile) -> Bool = { _ in false }
    var connectionChanged: ([ChatProfile]) -> Void = { _ in }
    var requestChanged: (String, Bool) -> Void = { _, _ in }
    var incoming: (Data, String) -> Void = { _, _ in }
    var invitation: (ChatProfile, @escaping (Bool) -> Void) -> Void = { _, reply in reply(false) }
    var status: (String) -> Void = { _ in }

    init(profile: ChatProfile) {
        localProfile = profile
        let local = MCPeerID(displayName: "@\(profile.username)-\(profile.id.prefix(8))")
        session = MCSession(peer: local, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: local, discoveryInfo: ["protocol": "1", "chat": "1", "id": profile.id, "username": profile.username], serviceType: "semantic-mesh")
        browser = MCNearbyServiceBrowser(peer: local, serviceType: "semantic-mesh")
        super.init()
        session.delegate = self; advertiser.delegate = self; browser.delegate = self
    }
    func start() { active = true; advertiser.startAdvertisingPeer(); browser.startBrowsingForPeers() }
    func stop() { active = false; advertiser.stopAdvertisingPeer(); browser.stopBrowsingForPeers(); session.disconnect(); approved.removeAll() }
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
            guard let self, self.active, info?["protocol"] == "1", info?["chat"] == "1",
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
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { progress.cancel() }
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) { }
}
