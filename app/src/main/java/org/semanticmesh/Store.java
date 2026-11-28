package org.semanticmesh;

import java.util.List;

/** Message persistence used by MeshNode; MessageStore is the SQLite implementation. */
interface Store {
    /** Stores a live envelope; false if it is a duplicate or already expired. */
    boolean put(Envelope e) throws Exception;
    List<Envelope> active() throws Exception;
}
