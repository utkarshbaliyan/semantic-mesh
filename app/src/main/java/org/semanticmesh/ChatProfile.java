package org.semanticmesh;

import org.json.JSONObject;
import java.util.Locale;
import java.util.Objects;
import java.util.regex.Pattern;

/** A nearby alias. Usernames are local labels, not globally registered or authenticated accounts. */
final class ChatProfile {
    static final String USERNAME_RULE = "Use 3–24 letters, numbers or underscores, starting with a letter.";
    private static final Pattern USERNAME = Pattern.compile("^[a-z][a-z0-9_]{2,23}$");
    final String id;
    final String username;

    ChatProfile(String id, String username) throws Exception {
        this.id = Envelope.uuid(id).toLowerCase(Locale.ROOT);
        this.username = normalize(username);
    }
    static String normalize(String input) throws Exception {
        String value = input == null ? "" : input.trim().toLowerCase(Locale.ROOT);
        if (!USERNAME.matcher(value).matches()) throw new Exception(USERNAME_RULE);
        return value;
    }
    static ChatProfile fromJson(JSONObject j) throws Exception { return new ChatProfile(j.getString("id"), j.getString("username")); }
    JSONObject toJson() throws Exception { return new JSONObject().put("id", id).put("username", username); }
    String label() { return "@" + username + " · " + id.substring(0, 8); }
    @Override public boolean equals(Object o) {
        return o instanceof ChatProfile && ((ChatProfile) o).id.equals(id) && ((ChatProfile) o).username.equals(username);
    }
    @Override public int hashCode() { return Objects.hash(id, username); }
}
