# Event Deduplication Strategies

This document outlines approaches to eliminate duplicate audit logs that may occur due to the 30-second overlap window in daemon mode.

## 🚫 **Attempted Solution: Splunk HEC Event ID** 

**Status: ❌ INCOMPATIBLE**

**Issue discovered:** The Splunk HEC `"id"` field format attempted is not compatible with Splunk Cloud.
- Causes "No data" error (code 5) from Splunk HEC
- Events are rejected even with valid JSON formatting
- Splunk HEC event ID deduplication works differently than expected

**Currently using:** 30-second overlap with alternative deduplication strategies below.

## 🔍 **Alternative Solutions**

### **1. Code-Level Deduplication**

**Option A: Local State Tracking**
```python
# Track sent event IDs in memory/file
sent_events = set()
if event_id not in sent_events:
    send_to_splunk(event)
    sent_events.add(event_id)
```

**Pros:** Complete elimination of duplicates  
**Cons:** Memory usage, state persistence challenges, complexity

**Option B: Database Tracking**
Store sent event IDs in SQLite/PostgreSQL database.

**Pros:** Persistent deduplication across restarts  
**Cons:** Additional dependency, storage overhead

### **2. Splunk Search-Time Deduplication**

**Option A: Dedup Command**
```splunk
index=your_index sourcetype=crusoe:audit 
| dedup start_time actor_id action target_type
```

**Option B: Event Hash Field**
```splunk
index=your_index sourcetype=crusoe:audit 
| eval event_hash=md5(start_time.actor_id.action.target_type) 
| dedup event_hash
```

**Pros:** No application changes needed  
**Cons:** Duplicates still stored, uses more storage

### **3. Splunk Data Models**

Create a data model that automatically deduplicates based on event characteristics.

**Pros:** Automatic, built into Splunk  
**Cons:** Requires Splunk configuration

## 📊 **Performance Comparison**

| Method | Duplicates Stored | App Complexity | Storage Impact | Real-time |
|--------|------------------|----------------|----------------|-----------|
| **30s Overlap** ⚠️ | Few duplicates | Low | Minimal | Yes |
| Local State | None | High | None | Yes |
| Database State | None | High | Low | Yes |
| Search-time Dedup | All duplicates | None | High | No |

## ✅ **Current Recommendation**

**Use 30-second overlap with search-time deduplication** because:

1. **Reliable data ingestion** - Compatible with Splunk Cloud HEC
2. **Simple implementation** - No complex event ID handling
3. **Guaranteed completeness** - 30s overlap ensures no missed logs
4. **Minimal duplicates** - Only 30s worth of potential overlap
5. **Easy cleanup** - Use Splunk search-time dedup for analysis

## 🧪 **Testing Deduplication**

To verify deduplication is working:

1. **Send the same event twice:**
   ```bash
   python3 main.py forward-recent --hours=1
   python3 main.py forward-recent --hours=1  # Same time range
   ```

2. **Check in Splunk:**
   ```splunk
   index=your_index sourcetype=crusoe:audit 
   | stats count by start_time actor_id action 
   | where count > 1
   ```
   
   Should return no results if deduplication is working.

3. **Verify event IDs:**
   ```splunk
   index=your_index sourcetype=crusoe:audit 
   | table _time start_time action actor_id _event_id
   ```

## 🔧 **Configuration**

No additional configuration required. Event ID generation is automatic and based on audit log content.

The 30-second overlap in daemon mode ensures no logs are missed while Splunk's native deduplication prevents any duplicates from being stored.
