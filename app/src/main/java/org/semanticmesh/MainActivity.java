package org.semanticmesh;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.os.*;
import android.widget.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import org.json.JSONObject;

// Bluetooth calls are gated by Activity runtime permissions.
@android.annotation.SuppressLint("MissingPermission")
public final class MainActivity extends Activity implements BluetoothTransport.Listener {
    private BluetoothAdapter adapter;
    private volatile BluetoothTransport transport;
    private MessageStore store;
    private String identity;
    private LinearLayout peers;
    private TextView log;
    private final Set<String> discovered = new HashSet<>();
    private final ScheduledExecutorService engine = Executors.newSingleThreadScheduledExecutor();
    private boolean registered;
    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        public void onReceive(Context c, Intent i) {
            if(BluetoothDevice.ACTION_FOUND.equals(i.getAction())) {
                BluetoothDevice d=i.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
                if(d!=null) addPeer(d);
            }
        }
    };
    public void onCreate(Bundle state) {
        super.onCreate(state);
        store=new MessageStore(this);
        android.content.SharedPreferences prefs=getSharedPreferences("node",MODE_PRIVATE);
        identity=prefs.getString("id",null);
        if(identity==null) { identity=UUID.randomUUID().toString(); prefs.edit().putString("id",identity).apply(); }
        adapter=((BluetoothManager)getSystemService(BLUETOOTH_SERVICE)).getAdapter();
        LinearLayout root=new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setPadding(24,24,24,24);
        ScrollView scroll=new ScrollView(this); scroll.addView(root); setContentView(scroll);
        TextView title=new TextView(this); title.setText(getString(R.string.node_title,identity)); root.addView(title);
        button(root,"Start / permissions",this::start);
        button(root,"Make discoverable (120 seconds)",() -> { if(ready()) { Intent i=new Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE); i.putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION,120); startActivity(i); } });
        button(root,"Scan nearby",() -> { if(ready()) { discovered.clear(); peers.removeAllViews(); for(BluetoothDevice d:adapter.getBondedDevices()) addPeer(d); if(!adapter.startDiscovery()) status("Discovery could not start"); } });
        peers=new LinearLayout(this); peers.setOrientation(LinearLayout.VERTICAL); root.addView(peers);
        EditText input=new EditText(this); input.setHint("Message (max 2000 characters)"); root.addView(input);
        button(root,"Send to mesh",() -> {
            String text=input.getText().toString().trim(); if(text.isEmpty()) return;
            if(transport==null) { status("Start Bluetooth first"); return; }
            engine.execute(() -> { try { Envelope e=Envelope.create(identity,text,null,null); store.put(e); show(e); transmit(e,null); } catch(Exception ex) { status(ex.getMessage()); } }); input.setText("");
        });
        log=new TextView(this); root.addView(log);
        engine.execute(() -> { try { for(Envelope e:store.active()) show(e); } catch(Exception e) { status(e.getMessage()); } });
        engine.scheduleWithFixedDelay(this::sync,15,15,TimeUnit.SECONDS);
    }
    private void button(LinearLayout parent,String text,Runnable action) { Button b=new Button(this); b.setText(text); b.setOnClickListener(v -> { try{action.run();}catch(Exception e){status(e.getMessage());} }); parent.addView(b); }
    private String[] permissions() { return Build.VERSION.SDK_INT>=31 ? new String[]{Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT,Manifest.permission.BLUETOOTH_ADVERTISE} : new String[]{Manifest.permission.ACCESS_FINE_LOCATION}; }
    private boolean ready() {
        for(String p:permissions()) if(checkSelfPermission(p)!=PackageManager.PERMISSION_GRANTED) { status("Grant permissions with Start"); return false; }
        if(adapter==null) { status("Bluetooth unavailable"); return false; }
        if(!adapter.isEnabled()) { startActivity(new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)); return false; }
        return true;
    }
    private void start() {
        for(String p:permissions()) if(checkSelfPermission(p)!=PackageManager.PERMISSION_GRANTED) { requestPermissions(permissions(),1); return; }
        if(!ready()) return;
        if(transport!=null) return;
        try {
            transport=new BluetoothTransport(adapter,this); transport.start();
            if(Build.VERSION.SDK_INT>=33) registerReceiver(receiver,new IntentFilter(BluetoothDevice.ACTION_FOUND),Context.RECEIVER_EXPORTED);
            else registerReceiver(receiver,new IntentFilter(BluetoothDevice.ACTION_FOUND));
            registered=true; status("Listening. Make one phone discoverable; scan from the other.");
            for(BluetoothDevice d:adapter.getBondedDevices()) addPeer(d);
        } catch(Exception e) { if(transport!=null) transport.close(); transport=null; status(e.getMessage()); }
    }
    public void onRequestPermissionsResult(int request,String[] p,int[] results) { super.onRequestPermissionsResult(request,p,results); if(request==1 && results.length>0 && Arrays.stream(results).allMatch(r -> r==PackageManager.PERMISSION_GRANTED)) start(); else status("Permissions denied"); }
    private void addPeer(BluetoothDevice d) {
        if(!discovered.add(d.getAddress())) return;
        button(peers,"Connect: " + (d.getName()==null ? "Unknown" : d.getName()) + " " + d.getAddress(),() -> { if(transport==null) status("Press Start first"); else transport.connect(d); });
    }
    public void received(byte[] bytes,String peer) {
        engine.execute(() -> {
            try {
                Envelope e=new Envelope(new JSONObject(new String(bytes,StandardCharsets.UTF_8)));
                if(e.expired() || !store.put(e)) return;
                show(e);
                if(e.json.getString("kind").equals("text") && !identity.equals(e.json.getString("sender"))) {
                    Envelope ack=Envelope.create(identity,null,e.id(),e.json.getString("sender"));
                    store.put(ack); transmit(ack,null);
                }
                transmit(e,peer);
            } catch(Exception ex) { status("Rejected frame: " + ex.getMessage()); }
        });
    }
    private void transmit(Envelope e,String except) throws Exception {
        if(transport!=null && !e.expired() && e.json.getInt("hops")<8) transport.broadcast(e.forwarded().json.toString().getBytes(StandardCharsets.UTF_8),except);
    }
    public void connected(String peer) { engine.execute(this::sync); }
    private void sync() { try { for(Envelope e:store.active()) transmit(e,null); } catch(Exception e) { status(e.getMessage()); } }
    private void show(Envelope e) throws Exception {
        if(e.json.getString("kind").equals("text")) status("[" + e.id().substring(0,8) + "] " + e.json.getString("sender").substring(0,8) + " · hops " + e.json.getInt("hops") + "\n" + e.json.getString("text"));
        else if(identity.equals(e.json.getString("to"))) status("Receipt from " + e.json.getString("sender").substring(0,8) + " for " + e.json.getString("ackFor").substring(0,8));
    }
    public void status(String text) { runOnUiThread(() -> { if(log!=null) { log.append(text + "\n\n"); if(log.length()>30000) log.setText(log.getText().subSequence(log.length()-20000,log.length())); } }); }
    public void onDestroy() { if(registered) unregisterReceiver(receiver); if(transport!=null) transport.close(); engine.shutdownNow(); super.onDestroy(); }
}
