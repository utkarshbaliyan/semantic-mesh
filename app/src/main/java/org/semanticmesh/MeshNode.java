package org.semanticmesh;

import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * Chat rules shared by every transport, ported from the Apple MeshModel: approved contacts, direct chats,
 * owner-managed groups, receipts and verified attachments. Not thread-safe; the app calls it from one thread.
 * Like the Apple app, envelopes travel only over direct approved links; other people's envelopes are not relayed.
 */
final class MeshNode {
    interface Links {
        void send(byte[] frame, String peer);
        boolean connected(String peer);
        void sendFile(File file, String name, String peer);
        void cancelFiles();
    }
    interface Events {
        void changed();
        void status(String text);
    }
    interface Match { boolean test(Envelope e) throws Exception; }

    final String identity;
    final ContactBook contacts;
    final GroupBook groups;
    final MediaVault vault;
    private final Store store;
    private final Links links;
    private final Events events;

    MeshNode(String identity, Store store, ContactBook contacts, GroupBook groups, MediaVault vault, Links links, Events events) {
        this.identity = identity; this.store = store; this.contacts = contacts; this.groups = groups; this.vault = vault;
        this.links = links; this.events = events;
    }

    ChatProfile me() throws Exception { return new ChatProfile(identity, contacts.username()); }

    // Sending ------------------------------------------------------------------------------------
    void sendText(String text, String contactID, String groupID) throws Exception {
        MeshGroup group = composeGroup(groupID);
        String trimmed = text.trim();
        if (trimmed.isEmpty()) throw new Exception("Type a message first.");
        if (trimmed.length() > 2000) throw new Exception("Messages can be up to 2000 characters.");
        submit(Envelope.message(identity, trimmed, group == null ? requireContact(contactID) : null, group));
    }
    void sendMedia(File source, String extension, String kind, String contactID, String groupID) throws Exception {
        MeshGroup group = composeGroup(groupID);
        String to = group == null ? requireContact(contactID) : null;
        if (!MediaDescriptor.supported(kind, extension)) throw new Exception(MediaDescriptor.INVALID);
        prune(); // Remove expired attachments before checking the storage quota.
        MediaDescriptor media = vault.importFile(source, kind, extension);
        submit(Envelope.attachment(identity, media, to, group));
    }
    private MeshGroup composeGroup(String groupID) throws Exception {
        if (groupID == null) return null;
        MeshGroup group = groups.group(groupID);
        if (group == null || !group.contains(identity)) throw new Exception("You are no longer a member of this group.");
        return group;
    }
    private String requireContact(String contactID) throws Exception {
        if (contactID == null || contacts.profile(contactID) == null) throw new Exception("Choose a contact or group first.");
        return contactID;
    }

    /** Creates a group (editingID null) or changes members of one you own. Messages explain what to fix. */
    MeshGroup saveGroup(String editingID, String rawName, Set<String> memberIDs) throws Exception {
        String name = rawName == null ? "" : rawName.trim();
        if (name.isEmpty()) throw new Exception("Type a group name first.");
        if (name.length() > 60) throw new Exception("Group name must be 60 characters or fewer.");
        if (memberIDs.isEmpty()) throw new Exception("Choose at least one contact to add.");
        if (memberIDs.size() > 15) throw new Exception("Choose at most 15 other members.");
        MeshGroup old = editingID == null ? null : groups.group(editingID);
        if (old != null && !old.ownerID.equals(identity)) throw new Exception(GroupBook.OWNER_ONLY);
        List<ChatProfile> candidates = new ArrayList<>(contacts.contacts());
        if (old != null) for (ChatProfile m : old.members) if (contacts.profile(m.id) == null) candidates.add(m);
        List<ChatProfile> members = new ArrayList<>();
        members.add(me());
        Set<String> added = new HashSet<>();
        added.add(identity);
        for (ChatProfile p : candidates) if (memberIDs.contains(p.id) && added.add(p.id)) members.add(p);
        MeshGroup group = new MeshGroup(old != null ? old.id : UUID.randomUUID().toString(), identity, name,
            old == null ? 1 : old.revision + 1, members);
        groups.apply(group, identity);
        links.cancelFiles();
        sync();
        return group;
    }

    // Receiving ----------------------------------------------------------------------------------
    void receive(byte[] data, String peer) {
        try {
            Envelope e = Envelope.decode(data);
            if (!authorized(e, peer)) return;
            switch (e.kind()) {
                case "group": {
                    MeshGroup group = e.group();
                    MeshGroup old = groups.group(group.id);
                    groups.apply(group, peer);
                    if (!group.equals(old)) links.cancelFiles();
                    accept(e);
                    acknowledge(e);
                    events.changed();
                    break;
                }
                case "media_ready": {
                    String wanted = e.ackFor();
                    Envelope original = find(x -> x.id().equals(wanted));
                    MediaDescriptor media = original == null ? null : original.media();
                    if (media == null || !vault.available(media)) return;
                    links.sendFile(vault.file(media), original.id(), peer);
                    break;
                }
                case "media": {
                    accept(e);
                    String id = e.id();
                    Envelope saved = find(x -> x.id().equals(id));
                    if (saved == null || !saved.sameContent(e)) return;
                    if (vault.available(e.media())) acknowledge(e);
                    else links.send(Envelope.ready(identity, e).encoded(), peer);
                    break;
                }
                default: accept(e);
            }
        } catch (Exception ex) { events.status(message(ex)); }
    }
    private void accept(Envelope e) throws Exception {
        if (!store.put(e)) return;
        events.changed();
        if (e.kind().equals("text") && !e.sender().equals(identity) && (e.to() == null || e.to().equals(identity))) acknowledge(e);
    }
    boolean authorized(Envelope e, String peer) throws Exception {
        if (e.expired() || !contacts.allows(e, identity, peer)) return false;
        switch (e.kind()) {
            case "group": {
                MeshGroup group = e.group();
                if (!group.ownerID.equals(peer)) return false;
                MeshGroup old = groups.group(group.id);
                if (old != null) return old.ownerID.equals(peer) && group.revision >= old.revision;
                return group.contains(identity);
            }
            case "ack":
            case "media_ready": {
                String wanted = e.ackFor();
                Envelope original = find(x -> x.id().equals(wanted) && x.sender().equals(identity));
                if (original == null || !Objects.equals(original.groupID(), e.groupID()) || original.groupRevision() != e.groupRevision()) return false;
                if (e.kind().equals("media_ready") && !original.kind().equals("media")) return false;
                if (original.groupID() != null && !original.kind().equals("group")) {
                    MeshGroup group = groups.group(original.groupID());
                    return group != null && group.contains(identity) && group.contains(peer) && group.revision == original.groupRevision();
                }
                return peer.equals(original.to());
            }
            case "text":
            case "media": return e.groupID() == null || groups.permits(e, identity, peer);
            default: return false;
        }
    }

    // Attachments --------------------------------------------------------------------------------
    /** The descriptor a peer may send for this message ID, or null to refuse the transfer. */
    MediaDescriptor allowFile(String name, String peer) {
        try { Envelope e = attachment(name, peer); return e == null ? null : e.media(); }
        catch (Exception ex) { return null; }
    }
    void fileReceived(File file, String name, String peer) {
        try {
            Envelope e = attachment(name, peer);
            if (e == null) return;
            MediaDescriptor media = e.media();
            vault.install(file, media);
            acknowledge(e);
            events.changed();
            events.status((media.kind.equals("audio") ? "Audio" : "Video") + " received and verified.");
        } catch (Exception ex) { events.status("Attachment rejected: " + message(ex)); }
    }
    private Envelope attachment(String id, String peer) throws Exception {
        Envelope e = find(x -> x.id().equals(id) && x.kind().equals("media"));
        return e != null && authorized(e, peer) ? e : null;
    }
    File mediaFile(Envelope e) {
        try { MediaDescriptor m = e.media(); return m != null && vault.available(m) ? vault.file(m) : null; }
        catch (Exception ex) { return null; }
    }

    // Delivery -----------------------------------------------------------------------------------
    private void acknowledge(Envelope original) throws Exception {
        String id = original.id();
        if (find(x -> x.kind().equals("ack") && x.sender().equals(identity) && id.equals(x.ackFor())) != null) return;
        submit(Envelope.receipt(identity, original));
    }
    private void submit(Envelope e) throws Exception {
        if (!store.put(e)) return;
        events.changed();
        transmit(e);
    }
    private void transmit(Envelope e) throws Exception {
        if (e.expired() || e.hops() >= 8 || !e.sender().equals(identity)) return;
        Envelope out = e.forwarded();
        String groupID = out.groupID();
        if (out.kind().equals("group")) {
            MeshGroup current = groups.group(groupID);
            if (current == null || !current.equals(out.group())) return;
        }
        if ((out.kind().equals("text") || out.kind().equals("media")) && groupID != null) {
            MeshGroup group = groups.group(groupID);
            if (group == null || !group.contains(identity) || group.revision != out.groupRevision()) return;
            for (ChatProfile member : group.members)
                if (!member.id.equals(identity) && contacts.profile(member.id) != null) links.send(out.addressedTo(member.id).encoded(), member.id);
        } else if (out.to() != null && contacts.profile(out.to()) != null) links.send(out.encoded(), out.to());
    }
    /** Re-sends live envelopes to connected people. Membership updates go first, and are renewed after they expire. */
    void sync() {
        try {
            for (MeshGroup group : groups.groups()) {
                if (!group.ownerID.equals(identity)) continue;
                for (ChatProfile member : groups.audience(group.id)) {
                    if (member.id.equals(identity) || !links.connected(member.id)) continue;
                    if (find(x -> x.kind().equals("group") && group.equals(x.group()) && member.id.equals(x.to())) == null)
                        submit(Envelope.groupUpdate(group, member.id));
                }
            }
            List<Envelope> active = store.active();
            for (Envelope e : active) if (e.kind().equals("group")) transmit(e);
            for (Envelope e : active) if (!e.kind().equals("group")) transmit(e);
            prune();
        } catch (Exception ex) { events.status(message(ex)); }
        events.changed();
    }
    private void prune() throws Exception {
        Set<String> keep = new HashSet<>();
        for (Envelope e : store.active()) { MediaDescriptor m = e.media(); if (m != null) keep.add(m.id); }
        vault.prune(keep);
    }
    private Envelope find(Match match) throws Exception {
        for (Envelope e : store.active()) if (match.test(e)) return e;
        return null;
    }

    // Views --------------------------------------------------------------------------------------
    List<Envelope> conversation(String contactID, String groupID) throws Exception {
        List<Envelope> result = new ArrayList<>();
        for (Envelope e : store.active()) {
            if (!e.kind().equals("text") && !e.kind().equals("media")) continue;
            if (groupID != null) { if (groupID.equals(e.groupID())) result.add(e); continue; }
            if (e.groupID() != null || contactID == null) continue;
            if ((e.sender().equals(identity) && contactID.equals(e.to())) || (e.sender().equals(contactID) && identity.equals(e.to()))) result.add(e);
        }
        return result.size() > 100 ? new ArrayList<>(result.subList(result.size() - 100, result.size())) : result;
    }
    Map<String, Set<String>> receipts() throws Exception {
        Map<String, Set<String>> grouped = new HashMap<>();
        for (Envelope e : store.active())
            if (e.kind().equals("ack") && identity.equals(e.to())) grouped.computeIfAbsent(e.ackFor(), k -> new HashSet<>()).add(e.sender());
        return grouped;
    }
    String deliveryStatus(Envelope e, Map<String, Set<String>> receipts) throws Exception {
        Set<String> by = receipts.get(e.id());
        int count = by == null ? 0 : by.size();
        String groupID = e.groupID();
        if (groupID != null) {
            String delivered = "Delivered to " + count + " member" + (count == 1 ? "" : "s");
            MeshGroup group = groups.group(groupID);
            if (group == null || group.revision != e.groupRevision()) return delivered + "; queued delivery stopped after membership changed";
            return delivered;
        }
        return count > 0 ? "Delivered to app" : "Awaiting delivery";
    }
    String senderName(String id, MeshGroup group) {
        if (id.equals(identity)) return "You";
        ChatProfile p = contacts.profile(id);
        if (p == null && group != null) for (ChatProfile m : group.members) if (m.id.equals(id)) p = m;
        return "@" + (p != null ? p.username : id.substring(0, 8));
    }
    static String message(Exception e) { return e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage(); }
}
