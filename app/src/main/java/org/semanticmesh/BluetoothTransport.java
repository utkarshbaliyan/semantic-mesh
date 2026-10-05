package org.semanticmesh;

import android.bluetooth.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;

// Bluetooth calls are gated by Activity runtime permissions.
@android.annotation.SuppressLint("MissingPermission")
final class BluetoothTransport implements Transport {
    interface Listener { void received(byte[] frame, String peer); void status(String text); void connected(String peer); }
    private static final UUID SERVICE = UUID.fromString("fc6cbad0-8e78-4b17-992f-a646c7ac97f1");
    private final BluetoothAdapter adapter;
    private final Listener listener;
    private final Map<String, Link> links = new ConcurrentHashMap<>();
    private final Set<BluetoothSocket> pending = ConcurrentHashMap.newKeySet();
    private final ExecutorService workers = Executors.newCachedThreadPool();
    private BluetoothServerSocket server;
    private volatile boolean closed;
    BluetoothTransport(BluetoothAdapter a, Listener l) { adapter=a; listener=l; }
    synchronized void start() throws IOException {
        if(server != null) return;
        server=adapter.listenUsingRfcommWithServiceRecord("Semantic Mesh",SERVICE);
        workers.execute(() -> { while(!closed) { try { attach(server.accept()); } catch(Exception e) { if(!closed) listener.status("Listener: " + e.getMessage()); break; } } });
    }
    void connect(BluetoothDevice device) {
        workers.execute(() -> {
            BluetoothSocket s = null;
            try {
                adapter.cancelDiscovery();
                s=device.createRfcommSocketToServiceRecord(SERVICE); pending.add(s);
                s.connect(); attach(s);
            } catch(Exception e) { listener.status("Connection failed: " + e.getMessage()); if(s!=null) try{s.close();}catch(IOException ignored){} }
            finally { if(s!=null) pending.remove(s); }
        });
    }
    private void attach(BluetoothSocket socket) throws IOException {
        String address=socket.getRemoteDevice().getAddress();
        Link link=new Link(socket);
        if(closed || links.putIfAbsent(address,link)!=null) { socket.close(); return; }
        workers.execute(() -> {
            try {
                listener.status("Connected " + address); listener.connected(address);
                while(!closed) {
                    int length=link.in.readInt();
                    if(length<1 || length>Envelope.MAX_BYTES) throw new IOException("Invalid frame size");
                    byte[] bytes=new byte[length]; link.in.readFully(bytes); listener.received(bytes,address);
                }
            } catch(Exception e) { if(!closed) listener.status("Disconnected " + address + ": " + e.getMessage()); }
            finally { links.remove(address,link); try{socket.close();}catch(IOException ignored){} }
        });
    }
    public void broadcast(byte[] bytes, String except) {
        for(Map.Entry<String,Link> entry:links.entrySet()) if(!entry.getKey().equals(except)) {
            try { entry.getValue().send(bytes); } catch(IOException e) { try{entry.getValue().socket.close();}catch(IOException ignored){} }
        }
    }
    public synchronized void close() {
        closed=true;
        if(server!=null) try{server.close();}catch(IOException ignored){}
        for(Link l:links.values()) try{l.socket.close();}catch(IOException ignored){}
        for(BluetoothSocket s:pending) try{s.close();}catch(IOException ignored){}
        workers.shutdownNow();
    }
    private static final class Link {
        final BluetoothSocket socket; final DataInputStream in; final DataOutputStream out;
        Link(BluetoothSocket s) throws IOException { socket=s; in=new DataInputStream(s.getInputStream()); out=new DataOutputStream(s.getOutputStream()); }
        synchronized void send(byte[] frame) throws IOException { out.writeInt(frame.length); out.write(frame); out.flush(); }
    }
}
