#!/usr/bin/env python3
"""Test sending to Splunk without specifying an index."""

import os
import json
import requests
from dotenv import load_dotenv
from config import AppConfig
from crusoe_client import CrusoeClient
from datetime import datetime, timedelta, timezone

def test_splunk_no_index():
    """Test sending events to Splunk without specifying an index."""
    
    load_dotenv()
    
    print("=== TESTING SPLUNK WITHOUT INDEX ===")
    
    try:
        # Load configuration
        config = AppConfig.from_env()
        crusoe_client = CrusoeClient(config.crusoe)
        
        # Fetch one audit log
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(hours=1)
        
        logs = crusoe_client.get_audit_logs(
            start_time=start_time,
            end_time=end_time,
            limit=1
        )
        
        if not logs:
            print("No logs to test with")
            return
        
        log = logs[0]
        print(f"Testing with log: {log.get('action')} by {log.get('actor_email')}")
        
        # Format event WITHOUT index
        import hashlib
        unique_fields = [
            log.get('start_time', ''),
            log.get('actor_id', ''),
            log.get('action', ''),
            log.get('target_type', ''),
            log.get('organization_id', ''),
        ]
        event_id = hashlib.md5(''.join(unique_fields).encode()).hexdigest()
        
        event_no_index = {
            "time": datetime.fromisoformat(log['start_time'].replace('Z', '+00:00')).timestamp(),
            "event": log,
            "sourcetype": config.splunk.sourcetype,
            "source": config.splunk.source,
            "id": event_id
            # NO INDEX FIELD
        }
        
        # Format event WITH index
        event_with_index = event_no_index.copy()
        event_with_index["index"] = "main"
        
        headers = {
            "Authorization": f"Splunk {config.splunk.hec_token}",
            "Content-Type": "application/json"
        }
        
        # Test 1: Without index
        print(f"\n=== TEST 1: WITHOUT INDEX ===")
        body1 = json.dumps(event_no_index)
        print(f"Payload: {body1}")
        
        response1 = requests.post(
            config.splunk.hec_url,
            headers=headers,
            data=body1,
            verify=config.splunk.verify_ssl,
            timeout=30
        )
        
        print(f"Status: {response1.status_code}")
        print(f"Response: {response1.text}")
        
        # Test 2: With index
        print(f"\n=== TEST 2: WITH INDEX 'main' ===")
        body2 = json.dumps(event_with_index)
        print(f"Payload: {body2}")
        
        response2 = requests.post(
            config.splunk.hec_url,
            headers=headers,
            data=body2,
            verify=config.splunk.verify_ssl,
            timeout=30
        )
        
        print(f"Status: {response2.status_code}")
        print(f"Response: {response2.text}")
        
        # Test 3: Try different index
        print(f"\n=== TEST 3: WITH INDEX 'default' ===")
        event_with_default = event_no_index.copy()
        event_with_default["index"] = "default"
        body3 = json.dumps(event_with_default)
        
        response3 = requests.post(
            config.splunk.hec_url,
            headers=headers,
            data=body3,
            verify=config.splunk.verify_ssl,
            timeout=30
        )
        
        print(f"Status: {response3.status_code}")
        print(f"Response: {response3.text}")
        
        print(f"\n=== SUMMARY ===")
        if response1.status_code == 200:
            print("✅ SUCCESS: No index specified - use this approach!")
        elif response2.status_code == 200:
            print("✅ SUCCESS: Index 'main' works")
        elif response3.status_code == 200:
            print("✅ SUCCESS: Index 'default' works")
        else:
            print("❌ All tests failed - check HEC token permissions")
        
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    test_splunk_no_index()
