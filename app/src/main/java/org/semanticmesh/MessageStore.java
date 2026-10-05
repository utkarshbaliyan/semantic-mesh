package org.semanticmesh;

import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.content.ContentValues;
import org.json.JSONObject;
import java.util.ArrayList;
import java.util.List;

final class MessageStore extends SQLiteOpenHelper {
    MessageStore(Context c) { super(c,"mesh.db",null,1); }
    public void onCreate(SQLiteDatabase db) { db.execSQL("CREATE TABLE messages(id TEXT PRIMARY KEY, payload TEXT NOT NULL, expires INTEGER NOT NULL)"); }
    public void onUpgrade(SQLiteDatabase db,int old,int next) { throw new IllegalStateException("Migration required"); }
    synchronized boolean put(Envelope e) throws Exception {
        SQLiteDatabase db = getWritableDatabase();
        db.delete("messages","expires <= ?",new String[]{String.valueOf(System.currentTimeMillis())});
        try (Cursor existing = db.rawQuery("SELECT 1 FROM messages WHERE id = ?",new String[]{e.id()})) { if(existing.moveToFirst()) return false; }
        ContentValues v = new ContentValues(); v.put("id",e.id()); v.put("payload",e.json.toString()); v.put("expires",e.json.getLong("expires"));
        // Bound storage rather than allowing an untrusted peer to exhaust disk.
        try (Cursor c = db.rawQuery("SELECT COUNT(*) FROM messages",null)) { c.moveToFirst(); if(c.getInt(0) >= 5000) throw new Exception("Store full"); }
        return db.insertWithOnConflict("messages",null,v,SQLiteDatabase.CONFLICT_IGNORE) != -1;
    }
    synchronized List<Envelope> active() throws Exception {
        List<Envelope> result = new ArrayList<>();
        try (Cursor c = getReadableDatabase().rawQuery("SELECT payload FROM messages WHERE expires > ? ORDER BY rowid",new String[]{String.valueOf(System.currentTimeMillis())})) {
            while(c.moveToNext()) result.add(new Envelope(new JSONObject(c.getString(0))));
        }
        return result;
    }
}
