package org.semanticmesh;

/** Protocol engine depends only on framed payload delivery; future radios implement this. */
interface Transport extends AutoCloseable {
    void broadcast(byte[] frame, String exceptPeer);
    void close();
}
