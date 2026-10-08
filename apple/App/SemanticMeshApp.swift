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
                                TextField("Username", text: $mesh.usernameDraft).autocorrectionDisabled()
                                Button("Save") { mesh.saveUsername() }
                            }
                            Text("@\(mesh.username) · \(mesh.identity.prefix(8))").font(.caption).textSelection(.enabled)
                            Text("3–24 letters, numbers or underscores. Usernames are nearby aliases and may be duplicated; compare device IDs.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Keep Wi-Fi and Bluetooth enabled and both apps open. Names are unverified. No internet or SIM is needed.").font(.caption)
                    HStack {
                        Button(mesh.running ? "Stop network" : "Start network") { mesh.running ? mesh.stop() : mesh.start() }
                            .buttonStyle(.borderedProminent)
                        Text("\(mesh.connected.count) connected").font(.caption)
                    }
                    GroupBox("Find people nearby") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Search nearby username or device ID", text: $mesh.search).autocorrectionDisabled()
                            if mesh.filteredNearby.isEmpty { Text(mesh.running ? "No matching nearby users. Start this version on the other device." : "Start the network to discover people nearby.").font(.caption).foregroundStyle(.secondary) }
                            ForEach(mesh.filteredNearby) { peer in
                                HStack {
                                    Text(peer.name).font(.subheadline)
                                    Spacer()
                                    if mesh.isConnected(peer.id) { Text("Connected").font(.caption).foregroundStyle(.green) }
                                    else {
                                        Button(mesh.pendingRequests.contains(peer.id) ? "Requested" : mesh.contacts.contains(where: { $0.id == peer.id }) ? "Reconnect" : "Request chat") { mesh.invite(peer) }
                                            .disabled(mesh.pendingRequests.contains(peer.id))
                                    }
                                }
                            }
                            Text("Search finds nearby devices only. Chat requests require the other person's approval.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox("Contacts") {
                        VStack(alignment: .leading, spacing: 10) {
                            if mesh.contacts.isEmpty { Text("Accepted chat requests appear here.").foregroundStyle(.secondary) }
                            ForEach(mesh.contacts) { contact in
                                Button { mesh.selectedContactID = contact.id } label: {
                                    HStack {
                                        Image(systemName: mesh.selectedContactID == contact.id ? "checkmark.circle.fill" : "person.crop.circle")
                                        Text(contact.label)
                                        Spacer()
                                        Text(mesh.isConnected(contact.id) ? "Nearby" : "Offline").font(.caption)
                                    }
                                }.buttonStyle(.bordered)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let contact = mesh.selectedContact {
                        GroupBox("Chat with @\(contact.username)") {
                            VStack(alignment: .leading, spacing: 12) {
                                if !mesh.isConnected(contact.id) { Text("Offline. Messages stay queued for up to one hour; reconnect nearby to deliver.").font(.caption).foregroundStyle(.secondary) }
                                if mesh.messages.isEmpty { Text("No live messages in this chat.").foregroundStyle(.secondary) }
                                ForEach(mesh.messages, id: \.id) { e in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(e.sender == mesh.identity ? "You" : "@\(contact.username)").font(.caption).foregroundStyle(.secondary)
                                        Text(e.text ?? "").textSelection(.enabled)
                                        HStack {
                                            Text(Date(timeIntervalSince1970: Double(e.created) / 1000), style: .time)
                                            if e.sender == mesh.identity { Text(mesh.receipts[e.id]?.contains(contact.id) == true ? "Delivered to app" : "Awaiting delivery") }
                                        }.font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    Divider()
                                }
                                TextField("Message", text: $mesh.draft, axis: .vertical).lineLimit(2...5)
                                HStack {
                                    Text("\(mesh.draft.utf16.count)/2000").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Send") { if mesh.send(mesh.draft) { mesh.draft = "" } }
                                        .disabled(!mesh.running || mesh.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mesh.draft.utf16.count > 2000)
                                }
                            }
                        }
                        Text("Delivery means stored by the recipient's app, not read by a person. Chats use encrypted local sessions; identities are not cryptographically verified.").font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Network log") {
                        ForEach(Array(mesh.log.enumerated()), id: \.offset) { _, line in Text(line).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }.padding()
            }.navigationTitle("Semantic Mesh")
                .alert("Chat request", isPresented: Binding(get: { mesh.pendingInvitation != nil }, set: { if !$0 { mesh.answerInvitation(false) } })) {
                    Button("Accept") { mesh.answerInvitation(true) }
                    Button("Reject", role: .cancel) { mesh.answerInvitation(false) }
                } message: { Text("\(mesh.pendingInvitation?.label ?? "Nearby user") wants to chat. Confirm their device ID in person; usernames alone do not prove identity.") }
        }
    }
}
