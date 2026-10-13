"""
Event deduplication with time-window hash tracking and disk persistence.
"""

import json
import hashlib
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Dict, Set, List, Optional
import logging

logger = logging.getLogger(__name__)


class EventDeduplicator:
    """
    Hash-based event deduplicator with time-window management and persistence.
    
    Tracks event hashes for a configurable time window to prevent duplicates
    while maintaining reasonable memory usage and restart safety.
    """
    
    def __init__(
        self, 
        tracking_window_seconds: int,
        state_file_path: Optional[str] = None,
        enabled: bool = True
    ):
        """
        Initialize the deduplicator.
        
        Args:
            tracking_window_seconds: How long to keep event hashes (interval + overlap + buffer)
            state_file_path: Path to persist state file (default: ~/.crusoe_dedup_state.json)
            enabled: Whether deduplication is active
        """
        self.tracking_window_seconds = tracking_window_seconds
        self.enabled = enabled
        
        # State file for persistence
        if state_file_path:
            self.state_file = Path(state_file_path)
        else:
            self.state_file = Path.home() / ".crusoe_dedup_state.json"
            
        # In-memory storage: {event_hash: timestamp_when_seen}
        self.seen_events: Dict[str, float] = {}
        
        # Load existing state
        self._load_state()
        
        logger.info(f"EventDeduplicator initialized: enabled={enabled}, window={tracking_window_seconds}s, state_file={self.state_file}")
    
    def _generate_event_hash(self, event: Dict) -> str:
        """
        Generate a consistent hash for an event based on key identifying fields.
        
        Args:
            event: Audit log event dictionary
            
        Returns:
            SHA256 hash string
        """
        # Use key fields that uniquely identify an event
        key_fields = [
            event.get('start_time', ''),
            event.get('actor_id', ''),
            event.get('action', ''),
            event.get('target_type', ''),
            event.get('target_id', ''),
            event.get('organization_id', ''),
            # Add more fields as needed for uniqueness
        ]
        
        # Create a consistent string representation
        key_string = '|'.join(str(field) for field in key_fields)
        
        # Generate hash
        return hashlib.sha256(key_string.encode('utf-8')).hexdigest()
    
    def _cleanup_old_entries(self):
        """Remove entries older than the tracking window."""
        if not self.enabled:
            return
            
        current_time = time.time()
        cutoff_time = current_time - self.tracking_window_seconds
        
        # Count before cleanup
        before_count = len(self.seen_events)
        
        # Remove old entries
        self.seen_events = {
            event_hash: timestamp 
            for event_hash, timestamp in self.seen_events.items()
            if timestamp > cutoff_time
        }
        
        after_count = len(self.seen_events)
        
        if before_count != after_count:
            logger.debug(f"Cleaned up {before_count - after_count} old hash entries ({after_count} remaining)")
    
    def _load_state(self):
        """Load persisted state from disk."""
        if not self.enabled or not self.state_file.exists():
            return
            
        try:
            with open(self.state_file, 'r') as f:
                data = json.load(f)
                
            # Load seen events
            self.seen_events = data.get('seen_events', {})
            
            # Convert string timestamps back to float
            self.seen_events = {
                event_hash: float(timestamp)
                for event_hash, timestamp in self.seen_events.items()
            }
            
            # Clean up old entries after loading
            self._cleanup_old_entries()
            
            logger.info(f"Loaded {len(self.seen_events)} event hashes from state file")
            
        except (json.JSONDecodeError, ValueError, KeyError) as e:
            logger.warning(f"Failed to load state file {self.state_file}: {e}. Starting fresh.")
            self.seen_events = {}
        except Exception as e:
            logger.error(f"Unexpected error loading state file: {e}. Starting fresh.")
            self.seen_events = {}
    
    def _save_state(self):
        """Persist current state to disk."""
        if not self.enabled:
            return
            
        try:
            # Ensure directory exists
            self.state_file.parent.mkdir(parents=True, exist_ok=True)
            
            # Prepare data for JSON serialization
            data = {
                'seen_events': self.seen_events,
                'last_updated': datetime.now(timezone.utc).isoformat(),
                'tracking_window_seconds': self.tracking_window_seconds
            }
            
            # Write to file atomically
            temp_file = self.state_file.with_suffix('.tmp')
            with open(temp_file, 'w') as f:
                json.dump(data, f, indent=2)
            
            # Atomic move
            temp_file.replace(self.state_file)
            
            logger.debug(f"Saved {len(self.seen_events)} event hashes to state file")
            
        except Exception as e:
            logger.error(f"Failed to save state file: {e}")
    
    def is_duplicate(self, event: Dict) -> bool:
        """
        Check if an event is a duplicate (read-only check).
        
        Args:
            event: Audit log event dictionary
            
        Returns:
            True if this event was seen before within the tracking window
        """
        if not self.enabled:
            return False
            
        # Clean up old entries first
        self._cleanup_old_entries()
        
        # Generate hash for this event
        event_hash = self._generate_event_hash(event)
        
        # Check if we've seen this hash before
        if event_hash in self.seen_events:
            logger.debug(f"Duplicate event detected: {event_hash[:12]}...")
            return True
        
        logger.debug(f"New event (not yet recorded): {event_hash[:12]}...")
        return False
    
    def filter_duplicates(self, events: List[Dict]) -> List[Dict]:
        """
        Filter out duplicate events from a list (read-only operation).
        
        Does NOT mark events as seen - use mark_events_as_sent() after successful Splunk submission.
        
        Args:
            events: List of audit log events
            
        Returns:
            List of unique events (non-duplicates)
        """
        if not self.enabled:
            return events
            
        unique_events = []
        duplicate_count = 0
        
        for event in events:
            if not self.is_duplicate(event):
                unique_events.append(event)
            else:
                duplicate_count += 1
        
        if duplicate_count > 0:
            logger.info(f"Filtered out {duplicate_count} duplicate events ({len(unique_events)} unique)")
        
        return unique_events
    
    def mark_events_as_sent(self, events: List[Dict]):
        """
        Mark events as successfully sent (after successful Splunk submission).
        
        This method should only be called AFTER events are successfully forwarded to Splunk.
        
        Args:
            events: List of events that were successfully sent
        """
        if not self.enabled or not events:
            return
            
        current_time = time.time()
        marked_count = 0
        
        for event in events:
            event_hash = self._generate_event_hash(event)
            
            # Only mark if not already seen (shouldn't happen, but safety check)
            if event_hash not in self.seen_events:
                self.seen_events[event_hash] = current_time
                marked_count += 1
        
        if marked_count > 0:
            logger.debug(f"Marked {marked_count} events as successfully sent")
            
        # Save state after marking events as sent
        self._save_state()
    
    def get_stats(self) -> Dict:
        """Get deduplicator statistics."""
        self._cleanup_old_entries()
        
        return {
            'enabled': self.enabled,
            'tracking_window_seconds': self.tracking_window_seconds,
            'tracked_events_count': len(self.seen_events),
            'state_file': str(self.state_file),
            'oldest_tracked_event': min(self.seen_events.values()) if self.seen_events else None,
            'newest_tracked_event': max(self.seen_events.values()) if self.seen_events else None
        }
    
    def clear_state(self):
        """Clear all tracked events and delete state file."""
        self.seen_events = {}
        
        if self.state_file.exists():
            try:
                self.state_file.unlink()
                logger.info("Cleared deduplication state file")
            except Exception as e:
                logger.error(f"Failed to delete state file: {e}")
