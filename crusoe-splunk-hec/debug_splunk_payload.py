#!/usr/bin/env python3
"""Debug what's being sent to Splunk HEC."""

import os
import json
from dotenv import load_dotenv
from config import AppConfig
from crusoe_client import CrusoeClient
from splunk_hec import SplunkHECClient
from datetime import datetime, timedelta, timezone

def debug_splunk_payload():
    """Debug the exact payload being sent to Splunk."""
    
    load_dotenv()
    
    print("=== DEBUGGING SPLUNK HEC PAYLOAD ===")
    
    try:
        # Load configuration
        config = AppConfig.from_env()
        crusoe_client = CrusoeClient(config.crusoe)
        splunk_client = SplunkHECClient(config.splunk)
        
        # Fetch a small number of logs
        print("Fetching audit logs from Crusoe...")
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(hours=1)
        
        logs = crusoe_client.get_audit_logs(
            start_time=start_time,
            end_time=end_time,
            limit=2
        )
        
        print(f"Fetched {len(logs)} audit logs")
        
        if not logs:
            print("No logs to debug")
            return
        
        # Show raw audit log
        print(f"\n=== RAW AUDIT LOG ===")
        print(json.dumps(logs[0], indent=2))
        
        # Format for Splunk and show the payload
        print(f"\n=== FORMATTED SPLUNK EVENT ===")
        formatted_event = splunk_client._format_event(logs[0])
        print(json.dumps(formatted_event, indent=2))
        
        # Show what would be sent as the HTTP body
        print(f"\n=== HTTP BODY CONTENT ===")
        events_data = []
        for log in logs:
            event = splunk_client._format_event(log)
            events_data.append(json.dumps(event))
        
        body = '\n'.join(events_data)
        print(f"Body length: {len(body)} characters")
        print("Body content:")
        print(body)
        
        # Check for any obvious issues
        print(f"\n=== VALIDATION CHECKS ===")
        
        if not body.strip():
            print("❌ Body is empty")
        else:
            print("✅ Body has content")
        
        # Try to parse each line as JSON
        lines = body.strip().split('\n')
        for i, line in enumerate(lines):
            try:
                json.loads(line)
                print(f"✅ Line {i+1} is valid JSON")
            except json.JSONDecodeError as e:
                print(f"❌ Line {i+1} invalid JSON: {e}")
        
        # Check required fields
        try:
            first_event = json.loads(lines[0])
            required_fields = ['time', 'event']
            for field in required_fields:
                if field in first_event:
                    print(f"✅ Has required field: {field}")
                else:
                    print(f"❌ Missing required field: {field}")
        except:
            print("❌ Could not parse first event")
        
        print(f"\n=== CONFIGURATION CHECK ===")
        print(f"Splunk HEC URL: {config.splunk.hec_url}")
        print(f"Splunk Token: {config.splunk.hec_token[:10]}...")
        print(f"Verify SSL: {config.splunk.verify_ssl}")
        print(f"Index: {config.splunk.index}")
        print(f"Sourcetype: {config.splunk.sourcetype}")
        print(f"Source: {config.splunk.source}")
        
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    debug_splunk_payload()
