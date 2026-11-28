package org.semanticmesh;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import java.io.File;
import java.util.UUID;
import static org.junit.Assert.*;

public class ContactBookTest {
    @Rule public TemporaryFolder temp = new TemporaryFolder();

    @Test public void nicknameOverridesUsernameAndPersists() throws Exception {
        File file = new File(temp.getRoot(), "contacts.json");
        String id = UUID.randomUUID().toString();
        ContactBook book = new ContactBook(file, "owner");
        book.accept(new ChatProfile(id, "bob"));
        assertEquals("bob", book.displayName(id));
        assertNull(book.nickname(id));
        book.setNickname(id, "Roommate");
        assertEquals("Roommate", book.displayName(id));

        ContactBook reloaded = new ContactBook(file, "unused");
        assertEquals("Roommate", reloaded.displayName(id));
        reloaded.setNickname(id, "");
        assertEquals("bob", reloaded.displayName(id));
        assertNull(reloaded.nickname(id));
    }

    @Test public void nicknameRejectsUnknownContactAndOverlongName() throws Exception {
        ContactBook book = new ContactBook(new File(temp.getRoot(), "c.json"), "owner");
        try { book.setNickname(UUID.randomUUID().toString(), "x"); fail("unknown contact accepted"); } catch (Exception expected) { }
        String id = UUID.randomUUID().toString();
        book.accept(new ChatProfile(id, "carol"));
        StringBuilder tooLong = new StringBuilder();
        for (int i = 0; i < ContactBook.MAX_NICKNAME + 1; i++) tooLong.append('x');
        try { book.setNickname(id, tooLong.toString()); fail("overlong nickname accepted"); } catch (Exception expected) { }
    }
}
