import SwiftUI

@main
struct SemanticMeshApp: App {
    @StateObject private var mesh = MeshModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            MeshView(mesh: mesh)
                .onChange(of: scenePhase) { _, phase in if phase == .background { mesh.stop() } }
                #if os(macOS)
                .frame(minWidth: 480, minHeight: 580)
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
                    Text("Node \(mesh.identity.prefix(8)) · foreground prototype").font(.caption).foregroundStyle(.secondary)
                    Text("Keep Wi-Fi and Bluetooth enabled. No internet or SIM is needed. Reports and identities are unverified.").font(.caption)
                    HStack {
                        Button(mesh.running ? "Stop network" : "Start network") { mesh.running ? mesh.stop() : mesh.start() }
                            .buttonStyle(.borderedProminent)
                        Text("\(mesh.connected.count) connected").font(.caption)
                    }
                    if !mesh.connected.isEmpty { Text(mesh.connected.joined(separator: ", ")).font(.caption).foregroundStyle(.green) }
                    GroupBox("Nearby") {
                        VStack(alignment: .leading, spacing: 8) {
                            if mesh.nearby.isEmpty { Text("Start on both devices, then wait for discovery.").foregroundStyle(.secondary) }
                            ForEach(mesh.nearby) { peer in
                                HStack { Text(peer.name); Spacer(); Button("Connect") { mesh.invite(peer) } }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Send a text report") {
                        VStack {
                            TextField("Message (max 2000 characters)", text: $mesh.draft, axis: .vertical).lineLimit(2...5)
                            HStack { Text("\(mesh.draft.utf16.count)/2000").font(.caption).foregroundStyle(.secondary); Spacer()
                                Button("Send") { if mesh.send(mesh.draft) { mesh.draft = "" } }
                                    .disabled(!mesh.running || mesh.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mesh.draft.utf16.count > 2000)
                            }
                        }.padding(4)
                    }
                    Text("Messages").font(.headline)
                    Text("Receipt means stored by another app, not read or verified by a person.").font(.caption).foregroundStyle(.secondary)
                    if mesh.messages.isEmpty { Text("No live messages yet.").foregroundStyle(.secondary) }
                    ForEach(mesh.messages.reversed(), id: \.id) { e in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(e.sender == mesh.identity ? "You" : "Node \(e.sender.prefix(8))")
                                    Spacer(); Text("\(e.id.prefix(8)) · hop \(e.hops)")
                                }.font(.caption).foregroundStyle(.secondary)
                                Text(e.text ?? "").textSelection(.enabled)
                                Text(Date(timeIntervalSince1970: Double(e.created) / 1000), style: .time).font(.caption)
                                if e.sender == mesh.identity {
                                    let count = mesh.receipts[e.id]?.count ?? 0
                                    Text(count == 0 ? "Stored locally · awaiting receipt" : "Stored by \(count) peer(s)").font(.caption)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    DisclosureGroup("Network log") {
                        ForEach(Array(mesh.log.enumerated()), id: \.offset) { _, line in Text(line).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }.padding()
            }.navigationTitle("Semantic Mesh")
                .alert("Connection invitation", isPresented: Binding(get: { mesh.pendingInvitation != nil }, set: { if !$0 { mesh.answerInvitation(false) } })) {
                    Button("Accept") { mesh.answerInvitation(true) }
                    Button("Reject", role: .cancel) { mesh.answerInvitation(false) }
                } message: { Text("\(mesh.pendingInvitation ?? "Nearby device") wants to connect. Accept only the device you are testing with; names are not authenticated.") }
        }
    }
}
