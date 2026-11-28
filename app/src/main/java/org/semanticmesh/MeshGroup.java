package org.semanticmesh;

import org.json.JSONArray;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Set;

/** Owner-managed group, same shape and limits as the Apple app (owner plus up to 15 members). */
final class MeshGroup {
    static final String INVALID = "Use a group name up to 60 characters and at most 16 members.";
    final String id;
    final String ownerID;
    final String name;
    final int revision;
    final List<ChatProfile> members;

    MeshGroup(String id, String ownerID, String name, int revision, List<ChatProfile> members) throws Exception {
        this.id = Envelope.uuid(id).toLowerCase(Locale.ROOT);
        this.ownerID = Envelope.uuid(ownerID).toLowerCase(Locale.ROOT);
        this.name = name;
        this.revision = revision;
        this.members = Collections.unmodifiableList(new ArrayList<>(members));
        Set<String> ids = new HashSet<>();
        for (ChatProfile m : members) ids.add(m.id);
        if (revision <= 0 || name == null || name.trim().isEmpty() || name.length() > 60 || members.isEmpty() || members.size() > 16
                || ids.size() != members.size() || !ids.contains(this.ownerID)) throw new Exception(INVALID);
    }
    static MeshGroup fromJson(JSONObject j) throws Exception {
        JSONArray a = j.getJSONArray("members");
        if (a.length() > 16) throw new Exception(INVALID);
        List<ChatProfile> members = new ArrayList<>();
        for (int i = 0; i < a.length(); i++) members.add(ChatProfile.fromJson(a.getJSONObject(i)));
        return new MeshGroup(j.getString("id"), j.getString("ownerID"), j.getString("name"), j.getInt("revision"), members);
    }
    JSONObject toJson() throws Exception {
        JSONArray a = new JSONArray();
        for (ChatProfile m : members) a.put(m.toJson());
        return new JSONObject().put("id", id).put("ownerID", ownerID).put("name", name).put("revision", revision).put("members", a);
    }
    boolean contains(String profileID) {
        for (ChatProfile m : members) if (m.id.equals(profileID)) return true;
        return false;
    }
    @Override public boolean equals(Object o) {
        if (!(o instanceof MeshGroup)) return false;
        MeshGroup g = (MeshGroup) o;
        return g.id.equals(id) && g.ownerID.equals(ownerID) && g.name.equals(name) && g.revision == revision && g.members.equals(members);
    }
    @Override public int hashCode() { return Objects.hash(id, revision); }
}
