package org.semanticmesh;

import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.util.ArrayList;
import java.util.List;

/** Groups this device knows, plus everyone who was ever a member (so removals reach them). Thread-safe. */
final class GroupBook {
    static final String OWNER_ONLY = "Only the group owner can change membership.";
    static final String STALE = "Group membership is out of date. Reconnect with the owner.";
    private static final class Entry {
        final MeshGroup group; final List<ChatProfile> audience;
        Entry(MeshGroup group, List<ChatProfile> audience) { this.group = group; this.audience = audience; }
    }
    private final File file;
    private List<Entry> entries = new ArrayList<>();

    GroupBook(File file) throws Exception {
        this.file = file;
        if (!file.exists()) return;
        JSONArray a = new JSONArray(Storage.read(file));
        if (a.length() > 100) throw new Exception(MeshGroup.INVALID);
        for (int i = 0; i < a.length(); i++) {
            JSONObject o = a.getJSONObject(i);
            MeshGroup group = MeshGroup.fromJson(o.getJSONObject("group"));
            List<ChatProfile> audience = new ArrayList<>();
            JSONArray people = o.getJSONArray("audience");
            for (int k = 0; k < people.length(); k++) audience.add(ChatProfile.fromJson(people.getJSONObject(k)));
            entries.add(new Entry(group, audience));
        }
    }
    synchronized List<MeshGroup> groups() {
        List<MeshGroup> list = new ArrayList<>();
        for (Entry e : entries) list.add(e.group);
        list.sort((a, b) -> a.name.compareTo(b.name));
        return list;
    }
    synchronized MeshGroup group(String id) {
        for (Entry e : entries) if (e.group.id.equals(id)) return e.group;
        return null;
    }
    synchronized List<ChatProfile> audience(String id) {
        for (Entry e : entries) if (e.group.id.equals(id)) return new ArrayList<>(e.audience);
        return new ArrayList<>();
    }
    synchronized void apply(MeshGroup group, String sender) throws Exception {
        if (!sender.equals(group.ownerID)) throw new Exception(OWNER_ONLY);
        List<Entry> next = new ArrayList<>(entries);
        int index = -1;
        for (int i = 0; i < next.size(); i++) if (next.get(i).group.id.equals(group.id)) index = i;
        if (index >= 0) {
            Entry old = next.get(index);
            if (!old.group.ownerID.equals(sender)) throw new Exception(OWNER_ONLY);
            if (group.revision == old.group.revision) { if (!group.equals(old.group)) throw new Exception(STALE); return; }
            if (group.revision < old.group.revision) throw new Exception(STALE);
            List<ChatProfile> audience = new ArrayList<>(old.audience);
            for (ChatProfile m : group.members) {
                boolean known = false;
                for (ChatProfile a : audience) if (a.id.equals(m.id)) known = true;
                if (!known) audience.add(m);
            }
            if (audience.size() > 500) throw new Exception(MeshGroup.INVALID);
            next.set(index, new Entry(group, audience));
        } else {
            if (next.size() >= 100) throw new Exception(MeshGroup.INVALID);
            next.add(new Entry(group, new ArrayList<>(group.members)));
        }
        JSONArray a = new JSONArray();
        for (Entry e : next) {
            JSONArray people = new JSONArray();
            for (ChatProfile p : e.audience) people.put(p.toJson());
            a.put(new JSONObject().put("group", e.group.toJson()).put("audience", people));
        }
        Storage.writeAtomic(file, a.toString());
        entries = next;
    }
    /** Group content must come from a current member, addressed to this device, at the current revision. */
    synchronized boolean permits(Envelope e, String local, String peer) throws Exception {
        String id = e.groupID();
        MeshGroup group = id == null ? null : group(id);
        if (group == null || e.groupRevision() != group.revision || !group.contains(local) || !group.contains(peer)
                || !e.sender().equals(peer) || !local.equals(e.to())) return false;
        return e.kind().equals("text") || e.kind().equals("media");
    }
}
