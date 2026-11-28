package org.semanticmesh;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import java.util.UUID;
import java.util.regex.Pattern;

/** Transport-independent v1 envelope. Field names and rules match the Apple app's Envelope. */
final class Envelope {
    static final int MAX_BYTES = 16384;
    static final long LIFETIME = 3_600_000;
    private static final Pattern UUID_TEXT = Pattern.compile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$");
    final JSONObject json;

    Envelope(JSONObject json) throws Exception {
        this.json = json;
        long now = System.currentTimeMillis();
        if (json.getInt("v") != 1) throw new Exception("Unsupported protocol");
        uuid(json.getString("id"));
        String sender = uuid(json.getString("sender"));
        String kind = json.getString("kind");
        int hops = json.getInt("hops");
        if (hops < 0 || hops > 8) throw new Exception("Invalid hops");
        long created = json.getLong("created"), expires = json.getLong("expires");
        if (expires <= created) throw new Exception("Invalid expiry");
        if (created < 0 || expires - created > LIFETIME || created > now + 300_000) throw new Exception("Invalid lifetime or clock skew");
        if (json.has("to")) uuid(json.getString("to"));
        if (json.has("groupID")) {
            uuid(json.getString("groupID"));
            if (!json.has("groupRevision") || json.getInt("groupRevision") <= 0) throw new Exception("Invalid group revision");
        } else if (json.has("groupRevision")) throw new Exception("Invalid group revision");
        if (!kind.equals("group") && json.has("group")) throw new Exception("Unexpected group");
        if (!kind.equals("media") && json.has("media")) throw new Exception("Unexpected media");
        switch (kind) {
            case "text": {
                String text = json.getString("text");
                if (text.trim().isEmpty() || text.length() > 2000) throw new Exception("Invalid text");
                break;
            }
            case "ack": uuid(json.getString("ackFor")); uuid(json.getString("to")); break;
            case "media_ready": uuid(json.getString("ackFor")); if (!json.has("to")) throw new Exception("Missing recipient"); break;
            case "group": {
                MeshGroup group = MeshGroup.fromJson(json.getJSONObject("group"));
                if (!json.has("to") || !group.ownerID.equals(sender.toLowerCase(java.util.Locale.ROOT)) || !group.id.equals(json.optString("groupID").toLowerCase(java.util.Locale.ROOT))
                        || group.revision != json.optInt("groupRevision")) throw new Exception("Invalid group update");
                break;
            }
            case "media": MediaDescriptor.fromJson(json.getJSONObject("media")); break;
            default: throw new Exception("Invalid kind");
        }
    }

    static String uuid(String value) throws Exception {
        if (value == null || !UUID_TEXT.matcher(value).matches()) throw new Exception("Invalid identifier");
        return value;
    }

    // Factories ----------------------------------------------------------------------------------
    private static JSONObject base(String sender, String kind, String to) throws JSONException {
        long now = System.currentTimeMillis();
        JSONObject j = new JSONObject().put("v", 1).put("id", UUID.randomUUID().toString()).put("sender", sender)
            .put("kind", kind).put("created", now).put("expires", now + LIFETIME).put("hops", 0);
        if (to != null) j.put("to", to);
        return j;
    }
    private static void groupFields(JSONObject j, String groupID, int revision) throws JSONException {
        if (groupID != null) j.put("groupID", groupID).put("groupRevision", revision);
    }
    static Envelope message(String sender, String text, String to, MeshGroup group) throws Exception {
        JSONObject j = base(sender, "text", to).put("text", text);
        if (group != null) groupFields(j, group.id, group.revision);
        return new Envelope(j);
    }
    static Envelope receipt(String sender, Envelope original) throws Exception {
        JSONObject j = base(sender, "ack", original.sender()).put("ackFor", original.id());
        groupFields(j, original.groupID(), original.groupRevision());
        return new Envelope(j);
    }
    static Envelope groupUpdate(MeshGroup group, String to) throws Exception {
        JSONObject j = base(group.ownerID, "group", to).put("group", group.toJson());
        groupFields(j, group.id, group.revision);
        return new Envelope(j);
    }
    static Envelope attachment(String sender, MediaDescriptor media, String to, MeshGroup group) throws Exception {
        JSONObject j = base(sender, "media", to).put("media", media.toJson());
        if (group != null) groupFields(j, group.id, group.revision);
        return new Envelope(j);
    }
    static Envelope ready(String sender, Envelope original) throws Exception {
        JSONObject j = base(sender, "media_ready", original.sender()).put("ackFor", original.id());
        groupFields(j, original.groupID(), original.groupRevision());
        return new Envelope(j);
    }
    /** Kept for the original protocol tests: a text message (ackFor null) or a receipt. */
    static Envelope create(String sender, String text, String ackFor, String to) throws Exception {
        if (ackFor == null) return message(sender, text, null, null);
        return new Envelope(base(sender, "ack", to).put("ackFor", ackFor));
    }

    // Accessors ----------------------------------------------------------------------------------
    String id() throws JSONException { return json.getString("id"); }
    String sender() throws JSONException { return json.getString("sender"); }
    String kind() throws JSONException { return json.getString("kind"); }
    String text() { return json.optString("text", ""); }
    String to() throws JSONException { return json.has("to") ? json.getString("to") : null; }
    String ackFor() throws JSONException { return json.has("ackFor") ? json.getString("ackFor") : null; }
    String groupID() throws JSONException { return json.has("groupID") ? json.getString("groupID") : null; }
    int groupRevision() { return json.optInt("groupRevision", 0); }
    int hops() throws JSONException { return json.getInt("hops"); }
    long created() throws JSONException { return json.getLong("created"); }
    MeshGroup group() throws Exception { return json.has("group") ? MeshGroup.fromJson(json.getJSONObject("group")) : null; }
    MediaDescriptor media() throws Exception { return json.has("media") ? MediaDescriptor.fromJson(json.getJSONObject("media")) : null; }
    boolean expired() throws JSONException { return json.getLong("expires") <= System.currentTimeMillis(); }

    Envelope forwarded() throws Exception { return new Envelope(new JSONObject(json.toString()).put("hops", json.getInt("hops") + 1)); }
    Envelope addressedTo(String to) throws Exception { return new Envelope(new JSONObject(json.toString()).put("to", to)); }

    byte[] encoded() throws Exception {
        byte[] data = json.toString().getBytes(StandardCharsets.UTF_8);
        if (data.length > MAX_BYTES) throw new Exception("Message exceeds the frame limit.");
        return data;
    }
    static Envelope decode(byte[] data) throws Exception {
        if (data.length == 0 || data.length > MAX_BYTES) throw new Exception("Message exceeds the frame limit.");
        return new Envelope(new JSONObject(new String(data, StandardCharsets.UTF_8)));
    }

    /** Same content regardless of key order or relay hop count. */
    boolean sameContent(Envelope other) throws JSONException {
        JSONObject a = new JSONObject(json.toString()), b = new JSONObject(other.json.toString());
        a.remove("hops"); b.remove("hops");
        return canonical(a).equals(canonical(b));
    }
    private static String canonical(Object value) throws JSONException {
        if (value instanceof JSONObject) {
            JSONObject o = (JSONObject) value;
            List<String> keys = new ArrayList<>();
            for (Iterator<String> it = o.keys(); it.hasNext(); ) keys.add(it.next());
            Collections.sort(keys);
            StringBuilder out = new StringBuilder("{");
            for (String key : keys) out.append(JSONObject.quote(key)).append(':').append(canonical(o.get(key))).append(',');
            return out.append('}').toString();
        }
        if (value instanceof JSONArray) {
            JSONArray a = (JSONArray) value;
            StringBuilder out = new StringBuilder("[");
            for (int i = 0; i < a.length(); i++) out.append(canonical(a.get(i))).append(',');
            return out.append(']').toString();
        }
        return value instanceof String ? JSONObject.quote((String) value) : String.valueOf(value);
    }
}
