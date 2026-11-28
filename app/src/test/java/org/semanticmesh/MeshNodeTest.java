package org.semanticmesh;

import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import java.io.File;
import java.nio.file.Files;
import java.util.*;
import static org.junit.Assert.*;

/** Simulates several devices with direct approved links, as the Bluetooth transport provides. */
public class MeshNodeTest {
    @Rule public TemporaryFolder temp = new TemporaryFolder();

    private static final class MemoryStore implements Store {
        final List<Envelope> entries = new ArrayList<>();
        public boolean put(Envelope e) throws Exception {
            if (e.expired()) return false;
            for (Envelope x : entries) if (x.id().equals(e.id())) return false;
            entries.add(e); return true;
        }
        public List<Envelope> active() throws Exception {
            List<Envelope> live = new ArrayList<>();
            for (Envelope e : entries) if (!e.expired()) live.add(e);
            return live;
        }
    }
    /** Every node is reachable from every other node that has it as a contact. */
    private final Map<String, MeshNode> network = new HashMap<>();
    private final List<String> statuses = new ArrayList<>();

    private MeshNode device(String username) throws Exception {
        String id = UUID.randomUUID().toString();
        File dir = temp.newFolder(username);
        String[] self = {id};
        MeshNode.Links links = new MeshNode.Links() {
            public void send(byte[] frame, String peer) { MeshNode other = network.get(peer); if (connected(peer)) other.receive(frame, self[0]); }
            public boolean connected(String peer) {
                MeshNode other = network.get(peer);
                return other != null && other.contacts.profile(self[0]) != null && network.get(self[0]).contacts.profile(peer) != null;
            }
            public void sendFile(File file, String name, String peer) {
                try {
                    File copy = File.createTempFile("transfer", ".bin", temp.getRoot());
                    Files.copy(file.toPath(), copy.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                    if (network.get(peer).allowFile(name, self[0]) != null) network.get(peer).fileReceived(copy, name, self[0]);
                } catch (Exception e) { throw new AssertionError(e); }
            }
            public void cancelFiles() { }
        };
        MeshNode.Events events = new MeshNode.Events() { public void changed() { } public void status(String t) { statuses.add(username + ": " + t); } };
        MeshNode node = new MeshNode(id, new MemoryStore(), new ContactBook(new File(dir, "contacts.json"), username),
            new GroupBook(new File(dir, "groups.json")), new MediaVault(new File(dir, "media")), links, events);
        network.put(id, node);
        return node;
    }
    private static void befriend(MeshNode a, MeshNode b) throws Exception { a.contacts.accept(b.me()); b.contacts.accept(a.me()); }

    private MeshNode alice, bob, carol;
    @Before public void setUp() throws Exception { alice = device("alice"); bob = device("bob"); carol = device("carol"); }

    @Test public void directChatIsDeliveredAndAcknowledged() throws Exception {
        befriend(alice, bob);
        alice.sendText("hello bob", bob.identity, null);
        List<Envelope> got = bob.conversation(alice.identity, null);
        assertEquals(1, got.size());
        assertEquals("hello bob", got.get(0).text());
        Envelope sent = alice.conversation(bob.identity, null).get(0);
        assertEquals("Delivered to app", alice.deliveryStatus(sent, alice.receipts()));
    }

    @Test public void strangersCannotMessage() throws Exception {
        befriend(alice, bob);
        Envelope e = Envelope.message(carol.identity, "spam", alice.identity, null);
        alice.receive(e.encoded(), carol.identity);
        assertTrue(alice.conversation(carol.identity, null).isEmpty());
    }

    @Test public void anyDeviceCanCreateAGroupThatReachesEveryMember() throws Exception {
        befriend(alice, bob); befriend(bob, carol); befriend(alice, carol);
        for (MeshNode creator : new MeshNode[]{alice, bob, carol}) {
            Set<String> others = new HashSet<>();
            for (MeshNode n : new MeshNode[]{alice, bob, carol}) if (n != creator) others.add(n.identity);
            MeshGroup group = creator.saveGroup(null, "team of " + creator.contacts.username(), others);
            for (MeshNode n : new MeshNode[]{alice, bob, carol}) assertEquals(group, n.groups.group(group.id));
            creator.sendText("hi team", null, group.id);
            for (MeshNode n : new MeshNode[]{alice, bob, carol}) assertEquals(1, n.conversation(null, group.id).size());
            Envelope sent = creator.conversation(null, group.id).get(0);
            assertEquals("Delivered to 2 members", creator.deliveryStatus(sent, creator.receipts()));
        }
    }

    @Test public void groupMembersReplyToTheWholeGroup() throws Exception {
        befriend(alice, bob); befriend(bob, carol); befriend(alice, carol);
        MeshGroup group = alice.saveGroup(null, "trip", new HashSet<>(Arrays.asList(bob.identity, carol.identity)));
        bob.sendText("from bob", null, group.id);
        assertEquals(1, alice.conversation(null, group.id).size());
        assertEquals(1, carol.conversation(null, group.id).size());
    }

    @Test public void onlyTheOwnerChangesMembership() throws Exception {
        befriend(alice, bob); befriend(bob, carol);
        MeshGroup group = alice.saveGroup(null, "owned", Collections.singleton(bob.identity));
        try { bob.saveGroup(group.id, "taken", Collections.singleton(carol.identity)); fail("non-owner edited group"); }
        catch (Exception expected) { assertEquals(GroupBook.OWNER_ONLY, expected.getMessage()); }
        MeshGroup smaller = alice.saveGroup(group.id, "owned", Collections.singleton(bob.identity));
        assertEquals(2, smaller.revision);
        assertEquals(smaller, bob.groups.group(group.id));
    }

    @Test public void saveGroupExplainsWhatIsMissing() throws Exception {
        befriend(alice, bob);
        assertMessage("Type a group name first.", () -> alice.saveGroup(null, "  ", Collections.singleton(bob.identity)));
        assertMessage("Choose at least one contact to add.", () -> alice.saveGroup(null, "x", Collections.emptySet()));
        char[] longName = new char[61]; Arrays.fill(longName, 'a');
        assertMessage("Group name must be 60 characters or fewer.", () -> alice.saveGroup(null, new String(longName), Collections.singleton(bob.identity)));
    }

    @Test public void voiceAndVideoTransferAndVerify() throws Exception {
        befriend(alice, bob);
        File clip = temp.newFile("clip.m4a");
        Files.write(clip.toPath(), new byte[]{1, 2, 3, 4, 5, 6, 7, 8});
        alice.sendMedia(clip, "m4a", "audio", bob.identity, null);
        Envelope received = bob.conversation(alice.identity, null).get(0);
        File file = bob.mediaFile(received);
        assertNotNull("bob should hold the verified file", file);
        assertArrayEquals(Files.readAllBytes(clip.toPath()), Files.readAllBytes(file.toPath()));
        Envelope sent = alice.conversation(bob.identity, null).get(0);
        assertEquals("Delivered to app", alice.deliveryStatus(sent, alice.receipts()));
    }

    @Test public void unsupportedMediaIsRejected() throws Exception {
        befriend(alice, bob);
        File doc = temp.newFile("notes.txt");
        Files.write(doc.toPath(), new byte[]{1});
        assertMessage(MediaDescriptor.INVALID, () -> alice.sendMedia(doc, "txt", "audio", bob.identity, null));
    }

    @Test public void usernamesFollowTheSameRulesAsApple() throws Exception {
        assertEquals("utkarsh_2", ChatProfile.normalize("  Utkarsh_2 "));
        for (String bad : new String[]{"ab", "2fast", "has space", "dots.here", "dash-name", "abcdefghijklmnopqrstuvwxy"})
            assertMessage(ChatProfile.USERNAME_RULE, () -> ChatProfile.normalize(bad));
        alice.contacts.setUsername("Alice_B");
        assertEquals("alice_b", alice.contacts.username());
    }

    @Test public void contactUsernameRefreshes() throws Exception {
        befriend(alice, bob);
        bob.contacts.setUsername("bobby");
        alice.contacts.accept(bob.me());
        assertEquals("bobby", alice.contacts.profile(bob.identity).username);
        assertEquals(1, alice.contacts.contacts().size());
    }

    @Test public void envelopesMatchTheAppleFieldNames() throws Exception {
        befriend(alice, bob);
        MeshGroup group = alice.saveGroup(null, "fields", Collections.singleton(bob.identity));
        Envelope update = Envelope.groupUpdate(group, bob.identity);
        for (String key : new String[]{"v", "id", "sender", "kind", "created", "expires", "hops", "to", "groupID", "groupRevision", "group"})
            assertTrue("missing " + key, update.json.has(key));
        assertTrue(update.json.getJSONObject("group").has("ownerID"));
    }

    private interface Action { void run() throws Exception; }
    private static void assertMessage(String expected, Action action) {
        try { action.run(); fail("expected: " + expected); }
        catch (Exception e) { assertEquals(expected, e.getMessage()); }
    }
}
