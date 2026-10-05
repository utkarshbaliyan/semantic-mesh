import Foundation
import MultipeerConnectivity

struct NearbyPeer: Identifiable {
    let id: String
    let name: String
    let peer: MCPeerID
}

/// All app callbacks and sends run on the main queue; MC delegates are marshalled there.
final class MultipeerTransport: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var tokens: [MCPeerID: String] = [:]
    private var active = false
    var discovered: (NearbyPeer) -> Void = { _ in }
    var lost: (String) -> Void = { _ in }
    var connectionChanged: ([String]) -> Void = { _ in }
    var incoming: (Data, String) -> Void = { _, _ in }
    var invitation: (String, @escaping (Bool) -> Void) -> Void = { _, reply in reply(false) }
    var status: (String) -> Void = { _ in }

    init(identity: String) {
        let name = "Mesh-" + identity.prefix(8)
        let local = MCPeerID(displayName: String(name))
        session = MCSession(peer: local, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: local, discoveryInfo: ["protocol": "1"], serviceType: "semantic-mesh")
        browser = MCNearbyServiceBrowser(peer: local, serviceType: "semantic-mesh")
        super.init()
        session.delegate = self; advertiser.delegate = self; browser.delegate = self
    }
    func start() { active = true; advertiser.startAdvertisingPeer(); browser.startBrowsingForPeers() }
    func stop() { active = false; advertiser.stopAdvertisingPeer(); browser.stopBrowsingForPeers(); session.disconnect() }
    func invite(_ peer: MCPeerID) {
        guard active, !session.connectedPeers.contains(peer) else { return }
        browser.invitePeer(peer, to: session, withContext: Data("semantic-mesh-v1".utf8), timeout: 20)
        status("Invitation sent to \(peer.displayName). Accept it on the other device.")
    }
    private func token(_ peer: MCPeerID) -> String {
        if let existing = tokens[peer] { return existing }
        let id = UUID().uuidString; tokens[peer] = id; return id
    }
    func send(_ data: Data, excluding: String?) {
        guard active else { return }
        for peer in session.connectedPeers where token(peer) != excluding {
            do { try session.send(data, toPeers: [peer], with: .reliable) }
            catch { status("Send failed to \(peer.displayName): \(error.localizedDescription)") }
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, info?["protocol"] == "1" else { return }
            self.discovered(NearbyPeer(id: self.token(peerID), name: peerID.displayName, peer: peerID))
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in guard let self, self.active else { return }; self.lost(self.token(peerID)) }
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
            guard let self, self.active, context == Data("semantic-mesh-v1".utf8) else { invitationHandler(false, nil); return }
            self.invitation(peerID.displayName) { [weak self] accept in
                guard let self, self.active else { invitationHandler(false, nil); return }
                invitationHandler(accept, accept ? self.session : nil)
            }
        }
    }
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active else { return }
            let label: String
            switch state { case .connected: label = "Connected"; case .connecting: label = "Connecting"; default: label = "Disconnected" }
            self.status("\(label): \(peerID.displayName)")
            self.connectionChanged(session.connectedPeers.map(\.displayName))
        }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= Envelope.maxBytes else { return }
        DispatchQueue.main.async { [weak self] in guard let self, self.active else { return }; self.incoming(data, self.token(peerID)) }
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { stream.close() }
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { progress.cancel() }
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) { }
}
