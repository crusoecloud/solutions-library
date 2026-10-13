"""Splunk HTTP Event Collector client for sending audit logs."""

import json
import logging
import time
from datetime import datetime
from typing import Dict, List, Any, Optional
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from config import SplunkConfig

logger = logging.getLogger(__name__)


class SplunkHECError(Exception):
    """Custom exception for Splunk HEC errors."""
    pass


class SplunkHECClient:
    """Client for sending events to Splunk HTTP Event Collector."""
    
    def __init__(self, config: SplunkConfig):
        """Initialize the Splunk HEC client.
        
        Args:
            config: Splunk configuration object
        """
        self.config = config
        self.session = self._create_session()
        
    def _create_session(self) -> requests.Session:
        """Create a requests session with retry strategy."""
        session = requests.Session()
        
        # Configure retry strategy
        retry_strategy = Retry(
            total=3,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["HEAD", "GET", "POST", "OPTIONS"],
            backoff_factor=1
        )
        
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("http://", adapter)
        session.mount("https://", adapter)
        
        # Set default headers
        session.headers.update({
            "Authorization": f"Splunk {self.config.hec_token}",
            "Content-Type": "application/json",
            "User-Agent": "crusoe-splunk-hec/1.0"
        })
        
        # Configure SSL verification
        session.verify = self.config.verify_ssl
        
        return session
    
    def _format_event(self, log_entry: Dict[str, Any]) -> Dict[str, Any]:
        """Format a Crusoe audit log entry for Splunk HEC.
        
        Args:
            log_entry: Raw audit log entry from Crusoe API
            
        Returns:
            Formatted event for Splunk HEC
        """
        # Extract timestamp if available, otherwise use current time
        timestamp = None
        if "timestamp" in log_entry:
            try:
                # Try to parse ISO format timestamp
                dt = datetime.fromisoformat(log_entry["timestamp"].replace('Z', '+00:00'))
                timestamp = dt.timestamp()
            except (ValueError, AttributeError):
                logger.warning(f"Could not parse timestamp: {log_entry.get('timestamp')}")
        
        if timestamp is None:
            timestamp = time.time()
        
        # Build the Splunk event
        event = {
            "time": timestamp,
            "event": log_entry,
            "sourcetype": self.config.sourcetype,
            "source": self.config.source
        }
        
        # Add index if specified
        if self.config.index:
            event["index"] = self.config.index
        
        return event
    
    def send_events(self, log_entries: List[Dict[str, Any]]) -> bool:
        """Send multiple audit log entries to Splunk HEC.
        
        Args:
            log_entries: List of audit log entries from Crusoe API
            
        Returns:
            True if successful, False otherwise
            
        Raises:
            SplunkHECError: If sending events fails
        """
        if not log_entries:
            logger.info("No log entries to send")
            return True
        
        # Format events for Splunk HEC
        formatted_events = [self._format_event(entry) for entry in log_entries]
        
        # Convert to NDJSON format (newline-delimited JSON)
        payload = "\n".join(json.dumps(event) for event in formatted_events)
        
        try:
            logger.info(f"Sending {len(log_entries)} events to Splunk HEC")
            response = self.session.post(
                self.config.hec_url,
                data=payload,
                timeout=30
            )
            response.raise_for_status()
            
            # Check Splunk HEC response
            response_data = response.json()
            if response_data.get("text") == "Success":
                logger.info(f"Successfully sent {len(log_entries)} events to Splunk")
                return True
            else:
                error_msg = f"Splunk HEC returned error: {response_data}"
                logger.error(error_msg)
                raise SplunkHECError(error_msg)
                
        except requests.exceptions.RequestException as e:
            error_msg = f"Failed to send events to Splunk HEC: {str(e)}"
            if hasattr(e, 'response') and e.response is not None:
                try:
                    error_detail = e.response.json()
                    error_msg += f" - {error_detail}"
                except:
                    error_msg += f" - Status: {e.response.status_code}"
            
            logger.error(error_msg)
            raise SplunkHECError(error_msg) from e
    
    def send_events_batch(
        self,
        log_entries: List[Dict[str, Any]],
        batch_size: int = 100
    ) -> tuple[int, List[Dict[str, Any]]]:
        """Send audit log entries to Splunk HEC in batches.
        
        Args:
            log_entries: List of audit log entries from Crusoe API
            batch_size: Number of events to send in each batch
            
        Returns:
            Tuple of (number_of_successfully_sent_events, list_of_successfully_sent_events)
        """
        if not log_entries:
            return 0, []
        
        total_sent = 0
        successfully_sent_events = []
        total_batches = (len(log_entries) + batch_size - 1) // batch_size
        
        for i in range(0, len(log_entries), batch_size):
            batch = log_entries[i:i + batch_size]
            batch_num = (i // batch_size) + 1
            
            try:
                logger.info(f"Sending batch {batch_num}/{total_batches} ({len(batch)} events)")
                self.send_events(batch)
                total_sent += len(batch)
                successfully_sent_events.extend(batch)
                
                # Small delay between batches to avoid overwhelming Splunk
                if batch_num < total_batches:
                    time.sleep(0.1)
                    
            except SplunkHECError as e:
                logger.error(f"Failed to send batch {batch_num}: {str(e)}")
                # Continue with next batch rather than failing completely
                continue
        
        logger.info(f"Successfully sent {total_sent}/{len(log_entries)} events to Splunk")
        return total_sent, successfully_sent_events
    
    def health_check(self) -> bool:
        """Check if Splunk HEC is accessible.
        
        Returns:
            True if HEC is accessible, False otherwise
        """
        try:
            # Send a test event
            test_event = {
                "timestamp": datetime.now().isoformat(),
                "message": "Health check from crusoe-splunk-hec",
                "event_type": "health_check"
            }
            
            self.send_events([test_event])
            return True
            
        except Exception as e:
            logger.error(f"Splunk HEC health check failed: {str(e)}")
            return False
    
    def validate_config(self) -> bool:
        """Validate Splunk HEC configuration by testing connectivity.
        
        Returns:
            True if configuration is valid, False otherwise
        """
        try:
            # Test basic connectivity without sending events
            response = self.session.get(
                self.config.hec_url.replace('/services/collector', '/services/collector/health'),
                timeout=10
            )
            return response.status_code in [200, 404]  # 404 is OK, means HEC is running
            
        except Exception as e:
            logger.error(f"Failed to validate Splunk HEC config: {str(e)}")
            return False
