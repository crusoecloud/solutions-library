#!/usr/bin/env python3
"""Test sending events with and without event ID to isolate the issue."""

import os
import json
import requests
import hashlib
from dotenv import load_dotenv
from config import AppConfig
from crusoe_client import CrusoeClient
from datetime import datetime, timedelta, timezone

def test_with_without_id():
    """Test sending the same event with and without the ID field."""
    
    load_dotenv()
    
    print("=== TESTING WITH AND WITHOUT EVENT ID ===")
    
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
        
        # Base event (the old format that worked)
        base_event = {
            "time": datetime.fromisoformat(log['start_time'].replace('Z', '+00:00')).timestamp(),
            "event": log,
            "sourcetype": config.splunk.sourcetype,
            "source": config.splunk.source,
            "index": config.splunk.index
        }
        
        # Event with ID (the new format that might be causing issues)
        unique_fields = [
            log.get('start_time', ''),
            log.get('actor_id', ''),
            log.get('action', ''),
            log.get('target_type', ''),
            log.get('organization_id', ''),
        ]
        event_id = hashlib.md5(''.join(unique_fields).encode()).hexdigest()
        
        event_with_id = base_event.copy()
        event_with_id["id"] = event_id
        
        headers = {
            "Authorization": f"Splunk {config.splunk.hec_token}",
            "Content-Type": "application/json"
        }
        
        # Test 1: WITHOUT ID (old working format)
        print(f"\n=== TEST 1: WITHOUT EVENT ID (OLD FORMAT) ===")
        body1 = json.dumps(base_event)
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
        
        # Test 2: WITH ID (new format)
        print(f"\n=== TEST 2: WITH EVENT ID (NEW FORMAT) ===")
        body2 = json.dumps(event_with_id)
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
        
        print(f"\n=== ANALYSIS ===")
        if response1.status_code == 200 and response2.status_code != 200:
            print("🎯 CONFIRMED: The event ID field is causing the issue!")
            print("   The old format works, the new format with ID fails.")
        elif response1.status_code == 200 and response2.status_code == 200:
            print("✅ Both formats work - issue might be elsewhere")
        elif response1.status_code != 200 and response2.status_code != 200:
            print("❌ Both formats fail - issue is not the ID field")
        else:
            print("🤔 Unexpected result pattern")
        
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    test_with_without_id()
