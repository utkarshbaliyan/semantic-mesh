package org.semanticmesh;
import org.junit.Test;
import org.json.JSONObject;
import java.util.UUID;
import static org.junit.Assert.*;

public class EnvelopeTest {
    private final String sender=UUID.randomUUID().toString();
    @Test public void relayPreservesIdentityAndExpiry() throws Exception {
        Envelope original=Envelope.create(sender,"hello",null,null);
        Envelope relay=original.forwarded();
        assertEquals(original.id(),relay.id());
        assertEquals(original.json.getLong("expires"),relay.json.getLong("expires"));
        assertEquals(0,original.json.getInt("hops"));
        assertEquals(1,relay.json.getInt("hops"));
    }
    @Test public void hopLimitCannotBeExceeded() throws Exception {
        Envelope e=Envelope.create(sender,"hello",null,null);
        for(int i=0;i<8;i++) e=e.forwarded();
        try { e.forwarded(); fail("must reject hop 9"); } catch(Exception expected) { assertEquals("Invalid hops",expected.getMessage()); }
    }
    @Test public void receiptReferencesOriginalAndRecipient() throws Exception {
        Envelope original=Envelope.create(sender,"hello",null,null);
        Envelope receipt=Envelope.create(UUID.randomUUID().toString(),null,original.id(),sender);
        assertEquals(original.id(),receipt.json.getString("ackFor"));
        assertEquals(sender,receipt.json.getString("to"));
    }
    @Test public void rejectMalformedProtocolFields() throws Exception {
        JSONObject valid=Envelope.create(sender,"hello",null,null).json;
        for(String field:new String[]{"v","id","sender","kind","hops","expires","text"}) {
            JSONObject broken=new JSONObject(valid.toString()); broken.remove(field);
            try { new Envelope(broken); fail("accepted missing " + field); } catch(org.json.JSONException expected) { }
        }
    }
    @Test public void expiryIsIndependentOfHopCount() throws Exception {
        JSONObject j=Envelope.create(sender,"hello",null,null).json;
        j.put("created",1).put("expires",2);
        assertTrue(new Envelope(j).expired());
    }
}
