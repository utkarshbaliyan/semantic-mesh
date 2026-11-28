package org.semanticmesh;

import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.util.ArrayList;
import java.util.List;

/** Your username plus the people whose chat requests were accepted. Thread-safe. */
final class ContactBook {
    private final File file;
    private String username;
    private List<ChatProfile> contacts = new ArrayList<>();

    ContactBook(File file, String defaultUsername) throws Exception {
        this.file = file;
        if (file.exists()) {
            JSONObject j = new JSONObject(Storage.read(file));
            username = ChatProfile.normalize(j.getString("username"));
            JSONArray a = j.getJSONArray("contacts");
            if (a.length() > 500) throw new Exception("Contact limit reached.");
            for (int i = 0; i < a.length(); i++) contacts.add(ChatProfile.fromJson(a.getJSONObject(i)));
        } else {
            username = ChatProfile.normalize(defaultUsername);
            save(username, contacts);
        }
    }
    synchronized String username() { return username; }
    synchronized List<ChatProfile> contacts() {
        List<ChatProfile> sorted = new ArrayList<>(contacts);
        sorted.sort((a, b) -> a.username.equals(b.username) ? a.id.compareTo(b.id) : a.username.compareTo(b.username));
        return sorted;
    }
    synchronized ChatProfile profile(String id) {
        for (ChatProfile c : contacts) if (c.id.equals(id)) return c;
        return null;
    }
    synchronized void setUsername(String raw) throws Exception {
        String next = ChatProfile.normalize(raw);
        save(next, contacts); username = next;
    }
    /** Adds a contact, or refreshes the username of an existing one. */
    synchronized void accept(ChatProfile profile) throws Exception {
        List<ChatProfile> next = new ArrayList<>();
        for (ChatProfile c : contacts) if (!c.id.equals(profile.id)) next.add(c);
        if (next.size() >= 500) throw new Exception("Contact limit reached.");
        next.add(profile);
        save(username, next); contacts = next;
    }
    /** Direct envelopes are accepted only from a saved contact, addressed to this device. */
    synchronized boolean allows(Envelope e, String local, String peer) throws Exception {
        return profile(peer) != null && e.sender().equals(peer) && local.equals(e.to()) && !e.sender().equals(local);
    }
    private void save(String name, List<ChatProfile> list) throws Exception {
        JSONArray a = new JSONArray();
        for (ChatProfile c : list) a.put(c.toJson());
        Storage.writeAtomic(file, new JSONObject().put("username", name).put("contacts", a).toString());
    }
}
