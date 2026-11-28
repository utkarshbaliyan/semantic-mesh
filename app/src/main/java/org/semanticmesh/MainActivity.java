package org.semanticmesh;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.bluetooth.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.Color;
import android.graphics.Typeface;
import android.media.MediaRecorder;
import android.net.Uri;
import android.os.*;
import android.provider.OpenableColumns;
import android.text.InputType;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.MimeTypeMap;
import android.widget.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;

/**
 * One screen: profile, network, nearby devices, contacts, groups and the selected conversation.
 * All chat state lives on the single `engine` thread; the UI draws immutable snapshots of it.
 */
// Bluetooth and microphone calls are gated by Activity runtime permissions.
@android.annotation.SuppressLint({"MissingPermission", "SetTextI18n"})
public final class MainActivity extends Activity implements BluetoothTransport.Listener, MeshNode.Links, MeshNode.Events {
    private static final int REQUEST_BLUETOOTH = 1, REQUEST_MICROPHONE = 2, PICK_AUDIO = 3, PICK_VIDEO = 4;
    private static final int RED = 0xFFC62828, GREEN = 0xFF2E7D32, ORANGE = 0xFFEF6C00, GREY = 0xFF6B6B6B;
    private final ScheduledExecutorService engine = Executors.newSingleThreadScheduledExecutor();
    private final AtomicBoolean renderQueued = new AtomicBoolean();
    private BluetoothAdapter adapter;
    private volatile BluetoothTransport transport;
    private MeshNode node;
    private String identity;
    // Engine-thread state.
    private String selectedContact, selectedGroup;
    // UI-thread state.
    private final Map<String, BluetoothDevice> discovered = new LinkedHashMap<>();
    private boolean registered, invitationOpen, logOpen;
    private MediaRecorder recorder;
    private File recordingFile;
    private Snapshot shown = new Snapshot();
    private EditText usernameField, draft;
    private TextView profileLabel, usernameMessage, connectedCount, lastStatus, chatTitle, chatInfo, log;
    private Button networkButton, logButton, sendButton, audioButton, videoButton, recordButton, cancelRecordButton, manageButton;
    private LinearLayout nearby, contactList, groupList, conversation, messages;
    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        public void onReceive(Context c, Intent i) {
            if (BluetoothDevice.ACTION_FOUND.equals(i.getAction())) {
                BluetoothDevice d = i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
                if (d != null) { discovered.put(d.getAddress(), d); draw(shown); }
            }
        }
    };

    /** Everything the screen shows, captured on the engine thread. */
    private static final class Snapshot {
        boolean running, canCompose;
        String username = "";
        List<ChatProfile> contacts = new ArrayList<>();
        Set<String> connected = new HashSet<>();
        List<BluetoothTransport.PeerView> peers = new ArrayList<>();
        List<MeshGroup> groups = new ArrayList<>();
        String selectedContact, selectedGroup;
        ChatProfile contact;
        MeshGroup group;
        String groupMembers = "";
        List<Row> rows = new ArrayList<>();
    }
    private static final class Row { String header, text, kind; File file; long bytes; }

    // Lifecycle ----------------------------------------------------------------------------------
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        SharedPreferences prefs = getSharedPreferences("node", MODE_PRIVATE);
        identity = prefs.getString("id", null);
        if (identity == null) { identity = UUID.randomUUID().toString(); prefs.edit().putString("id", identity).apply(); }
        adapter = ((BluetoothManager) getSystemService(BLUETOOTH_SERVICE)).getAdapter();
        buildViews();
        engine.execute(() -> {
            try {
                File dir = getFilesDir();
                node = new MeshNode(identity, new MessageStore(this), new ContactBook(new File(dir, "contacts.json"), "mesh_" + identity.substring(0, 6)),
                    new GroupBook(new File(dir, "groups.json")), new MediaVault(new File(dir, "media")), this, this);
                List<ChatProfile> contacts = node.contacts.contacts();
                if (!contacts.isEmpty()) selectedContact = contacts.get(0).id;
                String name = node.contacts.username();
                runOnUiThread(() -> usernameField.setText(name));
            } catch (Exception e) { status("Storage unavailable: " + MeshNode.message(e) + ". Sending is disabled."); }
            render();
        });
        engine.scheduleWithFixedDelay(() -> { if (node != null && transport != null) node.sync(); }, 15, 15, TimeUnit.SECONDS);
    }
    @Override public void onDestroy() {
        cancelRecording();
        if (registered) unregisterReceiver(receiver);
        BluetoothTransport t = transport; transport = null;
        if (t != null) t.close();
        engine.shutdownNow();
        super.onDestroy();
    }

    // Layout -------------------------------------------------------------------------------------
    private void buildViews() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(16), dp(16), dp(16), dp(32));
        ScrollView scroll = new ScrollView(this);
        scroll.addView(root);
        setContentView(scroll);

        TextView title = text(root, getString(R.string.node_title, identity.substring(0, 8)), 13, GREY);
        title.setPadding(0, 0, 0, dp(8));

        section(root, "Your profile");
        LinearLayout nameRow = row(root);
        usernameField = new EditText(this);
        usernameField.setHint("Username");
        usernameField.setSingleLine(true);
        usernameField.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        usernameField.setOnEditorActionListener((v, action, event) -> { saveUsername(); return true; });
        nameRow.addView(usernameField, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        button(nameRow, "Save", this::saveUsername);
        profileLabel = text(root, "", 13, GREY);
        text(root, "3–24 characters: lowercase letters, numbers or _ — must start with a letter. Example: utkarsh_2", 12, GREY);
        usernameMessage = text(root, "", 14, GREEN);
        usernameMessage.setVisibility(View.GONE);

        section(root, "Network");
        text(root, "Keep Bluetooth on and the app open on every phone. Works without internet or SIM.", 12, GREY);
        LinearLayout netRow = row(root);
        networkButton = button(netRow, "Start network", this::toggleNetwork);
        connectedCount = text(netRow, "0 connected", 13, GREY);
        connectedCount.setPadding(dp(12), 0, 0, 0);
        LinearLayout findRow = row(root);
        button(findRow, "Make discoverable", this::makeDiscoverable);
        button(findRow, "Scan nearby", this::scan);
        lastStatus = text(root, "", 13, GREY);

        section(root, "Find people nearby");
        nearby = column(root);

        section(root, "Contacts");
        contactList = column(root);

        section(root, "Groups");
        groupList = column(root);
        text(root, "Any device can create a group; its creator manages membership. Members must accept chat requests from one another to exchange messages directly.", 12, GREY);

        conversation = column(root);
        chatTitle = text(conversation, "", 18, Color.BLACK);
        chatTitle.setTypeface(Typeface.DEFAULT_BOLD);
        chatTitle.setPadding(0, dp(20), 0, dp(4));
        chatInfo = text(conversation, "", 12, GREY);
        manageButton = button(conversation, "Add / remove members", () -> editGroup(shown.selectedGroup));
        messages = column(conversation);
        draft = new EditText(this);
        draft.setHint("Message (max 2000 characters)");
        draft.setMinLines(2);
        conversation.addView(draft);
        LinearLayout sendRow = row(conversation);
        sendButton = button(sendRow, "Send", this::sendText);
        audioButton = button(sendRow, "Audio file", () -> pick("audio/*", PICK_AUDIO));
        videoButton = button(sendRow, "Video", () -> pick("video/*", PICK_VIDEO));
        LinearLayout recordRow = row(conversation);
        recordButton = button(recordRow, "Record voice", this::toggleRecording);
        cancelRecordButton = button(recordRow, "Cancel recording", this::cancelRecording);

        logButton = button(root, "Show network log", () -> { logOpen = !logOpen; draw(shown); });
        log = text(root, "", 12, GREY);
        log.setTextIsSelectable(true);
        draw(shown);
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private TextView text(ViewGroup parent, String value, int sp, int color) {
        TextView t = new TextView(this); t.setText(value); t.setTextSize(sp); t.setTextColor(color); parent.addView(t); return t;
    }
    private void section(ViewGroup parent, String title) {
        TextView t = text(parent, title, 16, Color.BLACK); t.setTypeface(Typeface.DEFAULT_BOLD); t.setPadding(0, dp(18), 0, dp(4));
    }
    private LinearLayout row(ViewGroup parent) {
        LinearLayout l = new LinearLayout(this); l.setOrientation(LinearLayout.HORIZONTAL); l.setGravity(android.view.Gravity.CENTER_VERTICAL); parent.addView(l); return l;
    }
    private LinearLayout column(ViewGroup parent) {
        LinearLayout l = new LinearLayout(this); l.setOrientation(LinearLayout.VERTICAL); parent.addView(l); return l;
    }
    private Button button(ViewGroup parent, String label, Runnable action) {
        Button b = new Button(this); b.setText(label); b.setAllCaps(false);
        b.setOnClickListener(v -> { try { action.run(); } catch (Exception e) { status(MeshNode.message(e)); } });
        parent.addView(b); return b;
    }

    // Rendering ----------------------------------------------------------------------------------
    private void render() {
        if (!renderQueued.compareAndSet(false, true)) return;
        try {
            engine.execute(() -> {
                renderQueued.set(false);
                Snapshot s = snapshot();
                runOnUiThread(() -> draw(s));
            });
        } catch (RejectedExecutionException ignored) { }
    }
    private Snapshot snapshot() {
        Snapshot s = new Snapshot();
        BluetoothTransport t = transport;
        s.running = t != null;
        if (t != null) s.peers = t.peers();
        if (node == null) return s;
        try {
            s.username = node.contacts.username();
            s.contacts = node.contacts.contacts();
            s.groups = node.groups.groups();
            for (ChatProfile c : s.contacts) if (t != null && t.connected(c.id)) s.connected.add(c.id);
            s.contact = selectedContact == null ? null : node.contacts.profile(selectedContact);
            s.group = selectedGroup == null ? null : node.groups.group(selectedGroup);
            if (s.contact == null) selectedContact = null;
            if (s.group == null) selectedGroup = null;
            s.selectedContact = selectedContact; s.selectedGroup = selectedGroup;
            s.canCompose = s.running && (s.contact != null || (s.group != null && s.group.contains(identity)));
            if (s.group != null) {
                StringBuilder names = new StringBuilder();
                for (ChatProfile m : s.group.members) names.append(names.length() == 0 ? "" : ", ").append(node.senderName(m.id, s.group));
                s.groupMembers = names.toString();
            }
            if (s.contact != null || s.group != null) {
                Map<String, Set<String>> receipts = node.receipts();
                for (Envelope e : node.conversation(selectedContact, selectedGroup)) {
                    Row r = new Row();
                    r.header = node.senderName(e.sender(), s.group) + " · " + (e.sender().equals(identity) ? node.deliveryStatus(e, receipts) : "received");
                    MediaDescriptor m = e.media();
                    if (m != null) { r.kind = m.kind; r.bytes = m.bytes; r.file = node.mediaFile(e); } else r.text = e.text();
                    s.rows.add(r);
                }
            }
        } catch (Exception e) { status(MeshNode.message(e)); }
        return s;
    }
    private void draw(Snapshot s) {
        if (isFinishing() || isDestroyed()) return;
        shown = s;
        boolean busy = recorder != null;
        profileLabel.setText("@" + s.username + " · " + identity.substring(0, 8));
        networkButton.setText(s.running ? "Stop network" : "Start network");
        connectedCount.setText(s.connected.size() + " connected");

        nearby.removeAllViews();
        Set<String> linked = new HashSet<>();
        for (BluetoothTransport.PeerView p : s.peers) {
            linked.add(p.address);
            if (p.profile == null) { text(nearby, "Connecting to " + (p.deviceName != null ? p.deviceName : p.address) + "…", 14, GREY); continue; }
            String who = p.profile.label();
            if (p.approved) button(nearby, "✓ Chatting with " + who, () -> selectContact(p.profile.id)).setEnabled(!busy);
            else if (p.requested) button(nearby, "Waiting for " + who + " to accept…", () -> { }).setEnabled(false);
            else button(nearby, "Send chat request to " + who, () -> engine.execute(() -> { BluetoothTransport t = transport; if (t != null) t.requestChat(p.profile.id); }));
        }
        for (BluetoothDevice d : discovered.values()) {
            if (linked.contains(d.getAddress())) continue;
            String name = d.getName() == null ? "Unknown device" : d.getName();
            button(nearby, "Connect: " + name + " · " + d.getAddress(), () -> connect(d)).setEnabled(s.running);
        }
        if (nearby.getChildCount() == 0)
            text(nearby, s.running ? "No devices yet. Tap Scan nearby, or Make discoverable on the other phone." : "Tap Start network first.", 13, GREY);

        contactList.removeAllViews();
        if (s.contacts.isEmpty()) text(contactList, "Accepted chat requests appear here.", 13, GREY);
        for (ChatProfile c : s.contacts) {
            String mark = c.id.equals(s.selectedContact) ? "● " : "○ ";
            button(contactList, mark + c.label() + "   " + (s.connected.contains(c.id) ? "Nearby" : "Offline"), () -> selectContact(c.id)).setEnabled(!busy);
        }

        groupList.removeAllViews();
        for (MeshGroup g : s.groups) {
            String mark = g.id.equals(s.selectedGroup) ? "● " : "○ ";
            String count = g.contains(identity) ? g.members.size() + " members" : "Removed";
            button(groupList, mark + g.name + "   " + count, () -> selectGroup(g.id)).setEnabled(!busy);
        }
        button(groupList, "Create group", () -> editGroup(null)).setEnabled(!busy && node != null);

        boolean open = s.contact != null || s.group != null;
        conversation.setVisibility(open ? View.VISIBLE : View.GONE);
        if (open) {
            chatTitle.setText(s.group != null ? s.group.name : s.contact.label());
            String info = s.group != null ? s.groupMembers + (s.group.contains(identity) ? "" : "\nYou were removed from this group.")
                : (s.connected.contains(s.contact.id) ? "Nearby — messages send now." : "Offline — messages wait up to 1 hour for them to reconnect.");
            chatInfo.setText(info);
            manageButton.setVisibility(s.group != null && s.group.ownerID.equals(identity) ? View.VISIBLE : View.GONE);
            manageButton.setEnabled(!busy);
            messages.removeAllViews();
            if (s.rows.isEmpty()) text(messages, "No messages in the last hour.", 13, GREY);
            for (Row r : s.rows) {
                TextView header = text(messages, r.header, 12, GREY);
                header.setPadding(0, dp(10), 0, 0);
                if (r.text != null) text(messages, r.text, 15, Color.BLACK);
                else {
                    String label = (r.kind.equals("audio") ? "Audio" : "Video") + " · " + Math.max(1, r.bytes / 1024) + " KB";
                    if (r.file != null) button(messages, "▶ Play " + label, () -> play(r.file));
                    else text(messages, label + " — waiting for the file to arrive…", 14, ORANGE);
                }
            }
            boolean compose = s.canCompose && !busy;
            sendButton.setEnabled(compose); audioButton.setEnabled(compose); videoButton.setEnabled(compose);
            draft.setEnabled(s.canCompose);
            recordButton.setEnabled(busy || s.canCompose);
            recordButton.setText(busy ? "Send recording" : "Record voice");
            cancelRecordButton.setVisibility(busy ? View.VISIBLE : View.GONE);
        }
        logButton.setText(logOpen ? "Hide network log" : "Show network log");
        log.setVisibility(logOpen ? View.VISIBLE : View.GONE);
    }

    // Actions ------------------------------------------------------------------------------------
    private void saveUsername() {
        String raw = usernameField.getText().toString();
        engine.execute(() -> {
            if (node == null) return;
            boolean ok; String message, saved = null;
            try {
                node.contacts.setUsername(raw);
                ChatProfile me = node.me();
                saved = me.username;
                BluetoothTransport t = transport;
                if (t != null) t.updateProfile(me);
                ok = true; message = "Saved as @" + me.username + ". Connected contacts see the new name right away.";
            } catch (Exception e) { ok = false; message = MeshNode.message(e); }
            final boolean success = ok; final String text = message, name = saved;
            runOnUiThread(() -> {
                usernameMessage.setVisibility(View.VISIBLE);
                usernameMessage.setText(text);
                usernameMessage.setTextColor(success ? GREEN : RED);
                if (name != null) usernameField.setText(name);
            });
            render();
        });
    }
    private void selectContact(String id) { engine.execute(() -> { selectedGroup = null; selectedContact = id; render(); }); }
    private void selectGroup(String id) { engine.execute(() -> { selectedContact = null; selectedGroup = id; render(); }); }
    private void sendText() {
        String text = draft.getText().toString();
        if (text.trim().isEmpty()) { status("Type a message first."); return; }
        draft.setText("");
        engine.execute(() -> {
            try { node.sendText(text, selectedContact, selectedGroup); }
            catch (Exception e) { status(MeshNode.message(e)); runOnUiThread(() -> draft.setText(text)); }
            render();
        });
    }
    private void editGroup(String groupID) {
        engine.execute(() -> {
            if (node == null) return;
            MeshGroup old = groupID == null ? null : node.groups.group(groupID);
            List<ChatProfile> candidates = node.contacts.contacts();
            Set<String> chosen = new HashSet<>();
            if (old != null) for (ChatProfile m : old.members) {
                if (m.id.equals(identity)) continue;
                chosen.add(m.id);
                boolean listed = false;
                for (ChatProfile c : candidates) if (c.id.equals(m.id)) listed = true;
                if (!listed) candidates.add(m);
            }
            runOnUiThread(() -> showGroupEditor(old, candidates, chosen));
        });
    }
    private void showGroupEditor(MeshGroup old, List<ChatProfile> candidates, Set<String> chosen) {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(20), dp(8), dp(20), 0);
        EditText name = new EditText(this);
        name.setHint("Group name");
        name.setSingleLine(true);
        if (old != null) name.setText(old.name);
        box.addView(name);
        text(box, "You are the owner. Choose up to 15 other members.", 12, GREY);
        if (candidates.isEmpty()) text(box, "No contacts yet. Accept a chat request from someone nearby, then add them here.", 13, ORANGE);
        for (ChatProfile c : candidates) {
            CheckBox check = new CheckBox(this);
            check.setText(c.label());
            check.setChecked(chosen.contains(c.id));
            check.setOnCheckedChangeListener((v, on) -> { if (on) chosen.add(c.id); else chosen.remove(c.id); });
            box.addView(check);
        }
        if (old != null) text(box, "Uncheck a member to remove them. Changes reach disconnected devices when they reconnect with you.", 12, GREY);
        TextView error = text(box, "", 14, RED);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(box);
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle(old == null ? "Create group" : "Manage members").setView(scroll)
            .setPositiveButton("Save group", null).setNegativeButton("Cancel", null).create();
        dialog.setOnShowListener(d -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            String groupName = name.getText().toString();
            Set<String> members = new HashSet<>(chosen);
            engine.execute(() -> {
                try {
                    MeshGroup saved = node.saveGroup(old == null ? null : old.id, groupName, members);
                    selectedContact = null; selectedGroup = saved.id;
                    status("Group saved. Membership changes reach people when they reconnect with you.");
                    runOnUiThread(dialog::dismiss);
                } catch (Exception e) { runOnUiThread(() -> error.setText(MeshNode.message(e))); }
                render();
            });
        }));
        dialog.show();
    }

    // Network ------------------------------------------------------------------------------------
    private String[] bluetoothPermissions() {
        return Build.VERSION.SDK_INT >= 31
            ? new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE}
            : new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
    }
    private boolean bluetoothReady() {
        for (String p : bluetoothPermissions()) if (checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) { requestPermissions(bluetoothPermissions(), REQUEST_BLUETOOTH); return false; }
        if (adapter == null) { status("Bluetooth is not available on this device."); return false; }
        if (!adapter.isEnabled()) { startActivity(new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)); status("Turn Bluetooth on, then tap Start network again."); return false; }
        return true;
    }
    private void toggleNetwork() {
        if (transport != null) {
            BluetoothTransport t = transport; transport = null;
            engine.execute(t::close);
            status("Network stopped.");
            render();
            return;
        }
        if (node == null) { status("Storage unavailable. Sending is disabled."); return; }
        if (!bluetoothReady()) return;
        engine.execute(() -> {
            try {
                BluetoothTransport t = new BluetoothTransport(adapter, this, node.me(), getCacheDir());
                t.start();
                transport = t;
                status("Listening. Tap Scan nearby, or Make discoverable on the other phone.");
                runOnUiThread(() -> {
                    if (!registered) {
                        IntentFilter filter = new IntentFilter(BluetoothDevice.ACTION_FOUND);
                        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED);
                        else registerReceiver(receiver, filter);
                        registered = true;
                    }
                    for (BluetoothDevice d : adapter.getBondedDevices()) discovered.put(d.getAddress(), d);
                });
            } catch (Exception e) { status("Could not start: " + MeshNode.message(e)); }
            render();
        });
    }
    private void makeDiscoverable() {
        if (!bluetoothReady()) return;
        Intent i = new Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE);
        i.putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 120);
        startActivity(i);
    }
    private void scan() {
        if (!bluetoothReady()) return;
        if (transport == null) { status("Tap Start network first."); return; }
        for (BluetoothDevice d : adapter.getBondedDevices()) discovered.put(d.getAddress(), d);
        if (!adapter.startDiscovery()) status("Discovery could not start.");
        else status("Scanning for nearby phones…");
        draw(shown);
    }
    private void connect(BluetoothDevice d) {
        BluetoothTransport t = transport;
        if (t == null) { status("Tap Start network first."); return; }
        status("Connecting to " + (d.getName() == null ? d.getAddress() : d.getName()) + "… accept the pairing prompt on both phones if asked.");
        t.connect(d);
    }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        boolean granted = results.length > 0;
        for (int r : results) granted &= r == PackageManager.PERMISSION_GRANTED;
        if (request == REQUEST_BLUETOOTH) { if (granted) toggleNetwork(); else status("Bluetooth permissions are required to find nearby phones."); }
        if (request == REQUEST_MICROPHONE) { if (granted) startRecording(); else status("Microphone access is required for voice messages. Enable it in system settings."); }
    }

    // Media --------------------------------------------------------------------------------------
    private void pick(String type, int request) {
        if (!shown.canCompose) { status("Choose a contact or group first."); return; }
        Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(type);
        try { startActivityForResult(i, request); } catch (ActivityNotFoundException e) { status("No file picker is available."); }
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (result != RESULT_OK || data == null || data.getData() == null) return;
        if (request != PICK_AUDIO && request != PICK_VIDEO) return;
        Uri uri = data.getData();
        String kind = request == PICK_AUDIO ? "audio" : "video";
        engine.execute(() -> { importUri(uri, kind); render(); });
    }
    private void importUri(Uri uri, String kind) {
        File copy = null;
        try {
            String extension = extension(displayName(uri), getContentResolver().getType(uri), kind);
            copy = new File(getCacheDir(), "pick-" + UUID.randomUUID() + "." + extension);
            try (InputStream in = getContentResolver().openInputStream(uri); OutputStream out = new FileOutputStream(copy)) {
                if (in == null) throw new IOException("Could not open the file.");
                byte[] buffer = new byte[65536];
                long total = 0;
                for (int n; (n = in.read(buffer)) > 0; ) {
                    total += n;
                    if (total > MediaVault.MAX_BYTES) throw new Exception(MediaDescriptor.INVALID);
                    out.write(buffer, 0, n);
                }
            }
            node.sendMedia(copy, extension, kind, selectedContact, selectedGroup);
            status((kind.equals("audio") ? "Audio" : "Video") + " queued. Delivery is confirmed after the recipient verifies the file.");
        } catch (Exception e) { status(MeshNode.message(e)); }
        finally { if (copy != null) copy.delete(); }
    }
    private String displayName(Uri uri) {
        try (Cursor c = getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst()) return c.getString(0);
        } catch (Exception ignored) { }
        return null;
    }
    private static String extension(String name, String mime, String kind) throws Exception {
        if (name != null && name.lastIndexOf('.') >= 0) {
            String ext = name.substring(name.lastIndexOf('.') + 1).toLowerCase(Locale.ROOT);
            if (MediaDescriptor.supported(kind, ext)) return ext;
        }
        String fromMime = mime == null ? null : MimeTypeMap.getSingleton().getExtensionFromMimeType(mime);
        if ("audio/mp4".equals(mime) || "audio/x-m4a".equals(mime) || "audio/m4a".equals(mime)) fromMime = "m4a";
        if ("audio/mpeg".equals(mime)) fromMime = "mp3";
        if ("audio/x-wav".equals(mime) || "audio/wav".equals(mime)) fromMime = "wav";
        if ("video/quicktime".equals(mime)) fromMime = "mov";
        if (MediaDescriptor.supported(kind, fromMime)) return fromMime;
        throw new Exception(kind.equals("audio") ? "Choose an m4a, mp3, aac, wav or caf audio file up to 20 MB." : "Choose an mp4, mov or m4v video up to 20 MB.");
    }
    private void toggleRecording() {
        if (recorder != null) { finishRecording(); return; }
        if (!shown.canCompose) { status("Choose a contact or group first."); return; }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQUEST_MICROPHONE);
            return;
        }
        startRecording();
    }
    @SuppressWarnings("deprecation")
    private void startRecording() {
        if (recorder != null || !shown.canCompose) return;
        File file = new File(getCacheDir(), "voice-" + UUID.randomUUID() + ".m4a");
        MediaRecorder r = Build.VERSION.SDK_INT >= 31 ? new MediaRecorder(this) : new MediaRecorder();
        try {
            r.setAudioSource(MediaRecorder.AudioSource.MIC);
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            r.setAudioSamplingRate(24000);
            r.setAudioChannels(1);
            r.setAudioEncodingBitRate(48000);
            r.setMaxDuration(120_000);
            r.setOutputFile(file.getAbsolutePath());
            r.setOnInfoListener((mr, what, extra) -> { if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_DURATION_REACHED) finishRecording(); });
            r.prepare();
            r.start();
        } catch (Exception e) {
            r.release(); file.delete();
            status("Could not start recording: " + MeshNode.message(e));
            return;
        }
        recorder = r; recordingFile = file;
        status("Recording voice message, up to 2 minutes. Tap Send recording when finished.");
        draw(shown);
    }
    private void finishRecording() {
        MediaRecorder r = recorder; File file = recordingFile;
        if (r == null) return;
        recorder = null; recordingFile = null;
        boolean ok = true;
        try { r.stop(); } catch (RuntimeException e) { ok = false; }
        r.release();
        draw(shown);
        if (!ok || file.length() == 0) { file.delete(); status("The recording was too short. Hold on a little longer."); return; }
        engine.execute(() -> {
            try { node.sendMedia(file, "m4a", "audio", selectedContact, selectedGroup); status("Voice message queued. Delivery is confirmed after the recipient verifies it."); }
            catch (Exception e) { status(MeshNode.message(e)); }
            finally { file.delete(); }
            render();
        });
    }
    private void cancelRecording() {
        MediaRecorder r = recorder; File file = recordingFile;
        if (r == null) return;
        recorder = null; recordingFile = null;
        try { r.stop(); } catch (RuntimeException ignored) { }
        r.release();
        if (file != null) file.delete();
        if (!isDestroyed()) draw(shown);
    }
    private void play(File file) {
        Dialog dialog = new Dialog(this);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(dp(12), dp(12), dp(12), dp(12));
        VideoView video = new VideoView(this);
        box.addView(video, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(260)));
        MediaController controls = new MediaController(this);
        controls.setAnchorView(video);
        video.setMediaController(controls);
        video.setVideoPath(file.getAbsolutePath());
        video.setOnPreparedListener(mp -> { video.start(); controls.show(0); });
        video.setOnErrorListener((mp, what, extra) -> { status("This file could not be played on this phone."); dialog.dismiss(); return true; });
        Button close = new Button(this);
        close.setText("Close");
        close.setOnClickListener(v -> dialog.dismiss());
        box.addView(close);
        dialog.setContentView(box);
        dialog.setOnDismissListener(d -> video.stopPlayback());
        dialog.show();
        if (dialog.getWindow() != null) dialog.getWindow().setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    // BluetoothTransport.Listener ----------------------------------------------------------------
    @Override public boolean isContact(String id) { return node != null && node.contacts.profile(id) != null; }
    @Override public boolean approved(ChatProfile profile) {
        if (node == null) return false;
        try {
            node.contacts.accept(profile);
            engine.execute(() -> { if (selectedContact == null && selectedGroup == null) selectedContact = profile.id; node.sync(); });
            return true;
        } catch (Exception e) { status("Could not save contact: " + MeshNode.message(e)); return false; }
    }
    @Override public void chatRequest(ChatProfile from, Consumer<Boolean> reply) {
        runOnUiThread(() -> {
            if (invitationOpen || isFinishing()) { reply.accept(false); return; }
            invitationOpen = true;
            boolean[] answered = {false};
            new AlertDialog.Builder(this).setTitle("Chat request")
                .setMessage(from.label() + " wants to chat. Confirm their device ID in person.")
                .setPositiveButton("Accept", (d, w) -> { answered[0] = true; reply.accept(true); })
                .setNegativeButton("Reject", (d, w) -> { answered[0] = true; reply.accept(false); })
                .setOnDismissListener(d -> { invitationOpen = false; if (!answered[0]) { answered[0] = true; reply.accept(false); } })
                .show();
        });
    }
    @Override public void peersChanged() {
        try { engine.execute(() -> { if (node != null && transport != null) node.sync(); render(); }); } catch (RejectedExecutionException ignored) { }
    }
    @Override public void frame(byte[] envelope, String peer) {
        try { engine.execute(() -> { if (node != null) node.receive(envelope, peer); }); } catch (RejectedExecutionException ignored) { }
    }
    @Override public MediaDescriptor allowFile(String name, String peer) {
        try { return engine.submit(() -> node == null ? null : node.allowFile(name, peer)).get(5, TimeUnit.SECONDS); }
        catch (Exception e) { return null; }
    }
    @Override public void fileReceived(File file, String name, String peer) {
        try { engine.execute(() -> { try { if (node != null) node.fileReceived(file, name, peer); } finally { file.delete(); } }); }
        catch (RejectedExecutionException e) { file.delete(); }
    }

    // MeshNode.Links -----------------------------------------------------------------------------
    @Override public void send(byte[] frame, String peer) { BluetoothTransport t = transport; if (t != null) t.send(frame, peer); }
    @Override public boolean connected(String peer) { BluetoothTransport t = transport; return t != null && t.connected(peer); }
    @Override public void sendFile(File file, String name, String peer) { BluetoothTransport t = transport; if (t != null) t.sendFile(file, name, peer); }
    @Override public void cancelFiles() { BluetoothTransport t = transport; if (t != null) t.cancelFiles(); }

    // MeshNode.Events ----------------------------------------------------------------------------
    @Override public void changed() { render(); }
    @Override public void status(String text) {
        runOnUiThread(() -> {
            if (log == null) return;
            lastStatus.setText(text);
            log.append(text + "\n\n");
            if (log.length() > 30000) log.setText(log.getText().subSequence(log.length() - 20000, log.length()));
        });
    }
}
