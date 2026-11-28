package org.semanticmesh;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothServerSocket;
import android.bluetooth.BluetoothSocket;
import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;

/**
 * Secure RFCOMM links. Each frame is a 4-byte length, a 1-byte type and a payload. Type 0 carries an
 * envelope, type 1 a link-control JSON object: hello (identity), resume (both sides already contacts),
 * request/accept/reject (chat requests), chunk/cancel (attachment transfer).
 * Envelopes are only delivered for approved links, and each person has at most one link.
 */
// Bluetooth calls are gated by Activity runtime permissions.
@android.annotation.SuppressLint("MissingPermission")
final class BluetoothTransport {
    interface Listener {
        boolean isContact(String id);
        /** Saves the peer as a contact; false refuses the link. */
        boolean approved(ChatProfile profile);
        void chatRequest(ChatProfile from, Consumer<Boolean> reply);
        void peersChanged();
        void frame(byte[] envelope, String peer);
        MediaDescriptor allowFile(String name, String peer);
        void fileReceived(File file, String name, String peer);
        void status(String text);
    }
    /** What the UI shows for one connected device. */
    static final class PeerView {
        final String address, deviceName; final ChatProfile profile; final boolean approved, requested;
        PeerView(Link l) { address = l.address; deviceName = l.deviceName; profile = l.profile; approved = l.approved; requested = l.requested; }
    }

    private static final UUID SERVICE = UUID.fromString("fc6cbad0-8e78-4b17-992f-a646c7ac97f1");
    private static final int ENVELOPE = 0, CONTROL = 1, CHUNK = 8192, MAX_TRANSFERS = 2;
    private final BluetoothAdapter adapter;
    private final Listener listener;
    private final File scratch;
    private volatile ChatProfile local;
    private final Map<String, Link> links = new ConcurrentHashMap<>();
    private final Set<BluetoothSocket> pending = ConcurrentHashMap.newKeySet();
    private final Map<String, AtomicBoolean> outgoing = new ConcurrentHashMap<>();
    private final ExecutorService workers = Executors.newCachedThreadPool();
    private final ScheduledExecutorService timers = Executors.newSingleThreadScheduledExecutor();
    private BluetoothServerSocket server;
    private volatile boolean closed;

    BluetoothTransport(BluetoothAdapter adapter, Listener listener, ChatProfile local, File scratch) {
        this.adapter = adapter; this.listener = listener; this.local = local; this.scratch = scratch;
    }
    synchronized void start() throws IOException {
        if (server != null) return;
        server = adapter.listenUsingRfcommWithServiceRecord("Semantic Mesh", SERVICE);
        workers.execute(() -> {
            while (!closed) {
                try { attach(server.accept()); }
                catch (Exception e) { if (!closed) listener.status("Listener stopped: " + e.getMessage()); break; }
            }
        });
    }
    void connect(BluetoothDevice device) {
        if (links.containsKey(device.getAddress())) return;
        workers.execute(() -> {
            BluetoothSocket s = null;
            try {
                adapter.cancelDiscovery();
                s = device.createRfcommSocketToServiceRecord(SERVICE); pending.add(s);
                s.connect(); attach(s);
            } catch (Exception e) {
                listener.status("Connection failed: " + e.getMessage() + ". Open Semantic Mesh and tap Start network on the other phone.");
                if (s != null) try { s.close(); } catch (IOException ignored) { }
            } finally { if (s != null) pending.remove(s); }
        });
    }

    // Link lifecycle -----------------------------------------------------------------------------
    private void attach(BluetoothSocket socket) throws IOException {
        BluetoothDevice device = socket.getRemoteDevice();
        Link link = new Link(socket, device.getAddress(), device.getName());
        if (closed || links.putIfAbsent(link.address, link) != null) { socket.close(); return; }
        workers.execute(() -> {
            try {
                link.sendControl(hello());
                listener.peersChanged();
                while (!closed) {
                    int length = link.in.readInt();
                    if (length < 2 || length > Envelope.MAX_BYTES + 1) throw new IOException("Invalid frame size");
                    int type = link.in.readUnsignedByte();
                    byte[] payload = new byte[length - 1];
                    link.in.readFully(payload);
                    if (type == ENVELOPE) { ChatProfile p = link.profile; if (link.approved && p != null) listener.frame(payload, p.id); }
                    else if (type == CONTROL) control(link, new JSONObject(new String(payload, StandardCharsets.UTF_8)));
                    else throw new IOException("Unknown frame type");
                }
            } catch (Exception e) {
                if (!closed) listener.status("Disconnected " + link.label() + ": " + e.getMessage());
            } finally {
                links.remove(link.address, link);
                link.dropIncoming();
                try { socket.close(); } catch (IOException ignored) { }
                listener.peersChanged();
            }
        });
    }
    private void control(Link link, JSONObject j) throws Exception {
        switch (j.getString("t")) {
            case "hello": hello(link, new ChatProfile(j.getString("id"), j.getString("username"))); break;
            case "resume": link.gotResume = true; if (link.sentResume) approve(link); break;
            case "request": request(link, j); break;
            case "accept": if (link.requested) approve(link); break;
            case "reject":
                if (link.requested) { link.requested = false; listener.status(link.label() + " declined the chat request."); listener.peersChanged(); }
                break;
            case "chunk": chunk(link, j); break;
            case "cancel": cancelTransfer(link, j.getString("name")); break;
            default: throw new IOException("Unknown control message");
        }
    }
    private void hello(Link link, ChatProfile peer) throws Exception {
        if (peer.id.equals(local.id)) throw new IOException("Connected to itself");
        ChatProfile previous = link.profile;
        if (previous != null && !previous.id.equals(peer.id)) throw new IOException("Peer identity changed");
        for (Link other : links.values())
            if (other != link && other.profile != null && other.profile.id.equals(peer.id)) throw new IOException("Already connected to " + peer.label());
        link.profile = peer;
        if (link.approved) listener.approved(peer); // Username change from a connected contact.
        else if (!link.sentResume && listener.isContact(peer.id)) {
            link.sentResume = true;
            link.sendControl(control("resume"));
            if (link.gotResume) approve(link);
        }
        listener.peersChanged();
    }
    private void request(Link link, JSONObject j) throws Exception {
        ChatProfile from = new ChatProfile(j.getString("id"), j.getString("username"));
        ChatProfile known = link.profile;
        if (known == null || !known.id.equals(from.id) || !local.id.equals(j.getString("to"))) return;
        if (link.approved || link.requested) { link.sendControl(control("accept")); approve(link); return; }
        listener.chatRequest(from, accept -> workers.execute(() -> {
            try {
                if (accept && links.get(link.address) == link) { link.sendControl(control("accept")); approve(link); }
                else link.sendControl(control("reject"));
            } catch (Exception e) { link.close(); }
        }));
    }
    private void approve(Link link) {
        ChatProfile p;
        synchronized (link.state) {
            p = link.profile;
            if (link.approved || p == null || !listener.approved(p)) return;
            link.approved = true; link.requested = false;
        }
        listener.status("Connected: " + p.label());
        listener.peersChanged();
    }

    // Public API ---------------------------------------------------------------------------------
    void requestChat(String identity) {
        Link link = linkFor(identity, false);
        if (link == null || link.approved || link.requested) return;
        try {
            ChatProfile me = local;
            link.sendControl(control("request").put("to", identity).put("id", me.id).put("username", me.username));
            link.requested = true;
            listener.status("Chat request sent to " + link.label() + ". Waiting for acceptance.");
            listener.peersChanged();
            timers.schedule(() -> {
                if (link.requested && !link.approved) {
                    link.requested = false;
                    listener.status("Request to " + link.label() + " was not answered. You can retry.");
                    listener.peersChanged();
                }
            }, 30, TimeUnit.SECONDS);
        } catch (Exception e) { listener.status("Request failed: " + e.getMessage()); link.close(); }
    }
    void send(byte[] envelope, String identity) {
        Link link = linkFor(identity, true);
        if (link == null) return;
        try { link.send(ENVELOPE, envelope); } catch (IOException e) { link.close(); }
    }
    boolean connected(String identity) { return linkFor(identity, true) != null; }
    List<PeerView> peers() {
        List<PeerView> list = new ArrayList<>();
        for (Link l : links.values()) list.add(new PeerView(l));
        list.sort((a, b) -> a.address.compareTo(b.address));
        return list;
    }
    /** Re-announces a new username on every link without disconnecting. */
    void updateProfile(ChatProfile profile) {
        if (!profile.id.equals(local.id)) return;
        local = profile;
        for (Link l : links.values()) workers.execute(() -> { try { l.sendControl(hello()); } catch (Exception e) { l.close(); } });
    }
    private Link linkFor(String identity, boolean approvedOnly) {
        for (Link l : links.values()) {
            ChatProfile p = l.profile;
            if (p != null && p.id.equals(identity) && (!approvedOnly || l.approved)) return l;
        }
        return null;
    }
    private JSONObject hello() throws Exception { ChatProfile me = local; return control("hello").put("id", me.id).put("username", me.username); }
    private static JSONObject control(String type) throws Exception { return new JSONObject().put("t", type); }

    // Attachments --------------------------------------------------------------------------------
    void sendFile(File file, String name, String identity) {
        Link link = linkFor(identity, true);
        if (link == null || closed) return;
        String key = identity + ":" + name;
        AtomicBoolean cancelled = new AtomicBoolean();
        if (outgoing.size() >= MAX_TRANSFERS || outgoing.putIfAbsent(key, cancelled) != null) return;
        workers.execute(() -> {
            try (InputStream in = new FileInputStream(file)) {
                long total = file.length(), offset = 0;
                byte[] buffer = new byte[CHUNK];
                for (int n; (n = in.read(buffer)) > 0; offset += n) {
                    if (cancelled.get() || closed) { link.sendControl(control("cancel").put("name", name)); return; }
                    link.sendControl(control("chunk").put("name", name).put("offset", offset).put("total", total)
                        .put("data", Base64.getEncoder().encodeToString(Arrays.copyOf(buffer, n))));
                }
            } catch (Exception e) {
                listener.status("Attachment transfer failed: " + e.getMessage() + ". Retrying while the message is live.");
            } finally { outgoing.remove(key, cancelled); }
        });
    }
    void cancelFiles() {
        for (AtomicBoolean flag : outgoing.values()) flag.set(true);
        for (Link l : links.values()) l.dropIncoming();
    }
    private void cancelTransfer(Link link, String name) {
        ChatProfile p = link.profile;
        if (p != null) { AtomicBoolean flag = outgoing.get(p.id + ":" + name); if (flag != null) flag.set(true); }
        Incoming in = link.incoming.remove(name);
        if (in != null) in.discard();
    }
    private void chunk(Link link, JSONObject j) throws Exception {
        ChatProfile p = link.profile;
        if (!link.approved || p == null) return;
        String name = Envelope.uuid(j.getString("name"));
        long offset = j.getLong("offset"), total = j.getLong("total");
        byte[] data = Base64.getDecoder().decode(j.getString("data"));
        Incoming in = link.incoming.get(name);
        if (in == null) {
            if (offset != 0) return; // Tail of a refused or cancelled transfer.
            MediaDescriptor media = link.incoming.size() < MAX_TRANSFERS ? listener.allowFile(name, p.id) : null;
            if (media == null || media.bytes != total) { link.sendControl(control("cancel").put("name", name)); return; }
            in = new Incoming(File.createTempFile("incoming-", ".part", scratch), total);
            link.incoming.put(name, in);
        }
        try {
            if (offset != in.received || in.received + data.length > in.total) throw new IOException("Out-of-order attachment data");
            in.out.write(data);
            in.received += data.length;
        } catch (IOException e) {
            link.incoming.remove(name, in); in.discard();
            link.sendControl(control("cancel").put("name", name));
            return;
        }
        if (in.received == in.total) {
            link.incoming.remove(name, in);
            in.out.close();
            listener.fileReceived(in.file, name, p.id);
        }
    }

    synchronized void close() {
        closed = true;
        if (server != null) try { server.close(); } catch (IOException ignored) { }
        for (Link l : links.values()) l.close();
        for (BluetoothSocket s : pending) try { s.close(); } catch (IOException ignored) { }
        cancelFiles();
        workers.shutdownNow();
        timers.shutdownNow();
    }

    private static final class Link {
        final BluetoothSocket socket; final DataInputStream in; final DataOutputStream out;
        final String address, deviceName;
        final Object state = new Object();
        final Map<String, Incoming> incoming = new ConcurrentHashMap<>();
        volatile ChatProfile profile;
        volatile boolean approved, sentResume, gotResume, requested;
        Link(BluetoothSocket s, String address, String deviceName) throws IOException {
            socket = s; this.address = address; this.deviceName = deviceName;
            in = new DataInputStream(new BufferedInputStream(s.getInputStream()));
            out = new DataOutputStream(new BufferedOutputStream(s.getOutputStream()));
        }
        synchronized void send(int type, byte[] payload) throws IOException {
            out.writeInt(payload.length + 1); out.writeByte(type); out.write(payload); out.flush();
        }
        void sendControl(JSONObject j) throws IOException { send(CONTROL, j.toString().getBytes(StandardCharsets.UTF_8)); }
        String label() { ChatProfile p = profile; return p != null ? p.label() : deviceName != null ? deviceName : address; }
        void dropIncoming() { for (Incoming i : incoming.values()) i.discard(); incoming.clear(); }
        void close() { try { socket.close(); } catch (IOException ignored) { } }
    }
    private static final class Incoming {
        final File file; final OutputStream out; final long total; long received;
        Incoming(File file, long total) throws IOException { this.file = file; this.total = total; out = new BufferedOutputStream(new FileOutputStream(file)); }
        void discard() { try { out.close(); } catch (IOException ignored) { } file.delete(); }
    }
}
