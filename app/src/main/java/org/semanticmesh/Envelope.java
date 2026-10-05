package org.semanticmesh;

import org.json.JSONObject;
import java.util.UUID;

/** Transport-independent v1 envelope. Hop budget and wall-clock expiry are separate. */
final class Envelope {
    static final int MAX_BYTES = 16384;
    final JSONObject json;
    Envelope(JSONObject json) throws Exception {
        this.json = json;
        if (json.getInt("v") != 1) throw new Exception("Unsupported protocol");
        UUID.fromString(json.getString("id"));
        UUID.fromString(json.getString("sender"));
        String kind = json.getString("kind");
        if (!kind.equals("text") && !kind.equals("ack")) throw new Exception("Invalid kind");
        if (json.getInt("hops") < 0 || json.getInt("hops") > 8) throw new Exception("Invalid hops");
        if (json.getLong("expires") <= json.getLong("created")) throw new Exception("Invalid expiry");
        if (json.getLong("expires") - json.getLong("created") > 3600000 || json.getLong("created") > System.currentTimeMillis() + 300000) throw new Exception("Invalid lifetime or clock skew");
        if (kind.equals("text") && (json.getString("text").trim().isEmpty() || json.getString("text").length() > 2000)) throw new Exception("Invalid text");
        if (kind.equals("ack")) UUID.fromString(json.getString("ackFor"));
        if (json.has("to")) UUID.fromString(json.getString("to"));
    }
    static Envelope create(String sender, String text, String ackFor, String to) throws Exception {
        long now = System.currentTimeMillis();
        JSONObject j = new JSONObject().put("v",1).put("id",UUID.randomUUID().toString())
            .put("sender",sender).put("created",now).put("expires",now + 3600000).put("hops",0)
            .put("kind",ackFor == null ? "text" : "ack");
        if (ackFor == null) j.put("text",text); else j.put("ackFor",ackFor).put("to",to);
        return new Envelope(j);
    }
    String id() throws Exception { return json.getString("id"); }
    boolean expired() throws Exception { return json.getLong("expires") <= System.currentTimeMillis(); }
    Envelope forwarded() throws Exception { return new Envelope(new JSONObject(json.toString()).put("hops",json.getInt("hops") + 1)); }
}
