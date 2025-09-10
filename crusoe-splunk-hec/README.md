# Crusoe to Splunk HEC Log Forwarder

A Python tool for fetching audit logs from the [Crusoe Cloud API](https://docs.crusoecloud.com/api/#tag/Audit-Logs/operation/getAuditLogs) and forwarding them to a Splunk HTTP Event Collector (HEC).

## Features

- ✅ Fetch audit logs from Crusoe Cloud API with pagination support
- ✅ Send logs to Splunk HEC in configurable batches
- ✅ Multiple operation modes: one-time, recent logs, time range, and daemon mode
- ✅ **Advanced Deduplication**: Time-window hash tracking with disk persistence
- ✅ **Two-Phase Deduplication**: Only marks events as sent after successful Splunk delivery
- ✅ **Restart-Safe**: Maintains deduplication state across daemon restarts
- ✅ Comprehensive error handling and retry logic
- ✅ Health checks for both Crusoe API and Splunk HEC
- ✅ Dry-run mode for testing
- ✅ Configurable via environment variables
- ✅ Detailed logging and monitoring

## Installation

1. **Clone or download the repository**
   ```bash
   git clone https://github.com/crusoecloud/solutions-library.git
   cd solutions-library/crusoe-splunk-hec
   ```

2. **Install dependencies**
   ```bash
   pip install -r requirements.txt
   ```

3. **Configure environment variables**
   ```bash
   cp env.example .env
   # Edit .env with your actual configuration
   ```

## Configuration

### Required Environment Variables

#### Crusoe Cloud API

**Authentication Options** (choose one):

**Option 1: Access Key Authentication (Recommended)**
- `CRUSOE_ACCESS_KEY_ID`: Your Crusoe Cloud access key ID
- `CRUSOE_SECRET_ACCESS_KEY`: Your Crusoe Cloud secret access key

**Option 2: Token Authentication (Legacy)**
- `CRUSOE_API_TOKEN`: Your Crusoe Cloud API token

**Common Configuration**
- `CRUSOE_ORG_ID`: Your organization ID for audit logs
- `CRUSOE_BASE_URL`: API base URL (default: `https://api.crusoecloud.com/v1alpha5`)

#### Splunk HTTP Event Collector
- `SPLUNK_HEC_TOKEN`: Your Splunk HEC token
- `SPLUNK_HEC_URL`: Splunk HEC endpoint URL (e.g., `https://your-splunk.com:8088/services/collector`)

#### Optional Configuration
- `SPLUNK_INDEX`: Splunk index name (optional)
- `SPLUNK_SOURCETYPE`: Sourcetype for events (default: `crusoe:audit`)
- `SPLUNK_SOURCE`: Source for events (default: `crusoe_api`)
- `SPLUNK_VERIFY_SSL`: Verify SSL certificates (default: `true`)
- `BATCH_SIZE`: Number of events per batch (default: `100`)
- `REQUEST_TIMEOUT`: Request timeout in seconds (default: `30`)
- `MAX_RETRIES`: Maximum retries for failed requests (default: `3`)

### Getting Crusoe API Credentials

#### Access Key and Secret Key (Recommended)

1. **Access Keys**: 
   - Log into [Crusoe Cloud Console](https://console.crusoecloud.com)
   - Navigate to Settings > Access Keys or API Keys
   - Create a new access key pair
   - Copy both the Access Key ID and Secret Access Key

2. **Environment Setup**:
   ```bash
   # Add to your .env file
   CRUSOE_ACCESS_KEY_ID=your_access_key_id_here
   CRUSOE_SECRET_ACCESS_KEY=your_secret_access_key_here
   CRUSOE_ORG_ID=your_organization_id_here
   ```

#### API Token (Legacy Alternative)

1. **API Token**: 
   - Log into [Crusoe Cloud Console](https://console.crusoecloud.com)
   - Navigate to Settings > API Tokens
   - Create a new token with appropriate permissions

#### Organization ID

2. **Organization ID**:
   - Available in the Crusoe Cloud Console under account settings
   - Required for accessing audit logs via the API
   - Format: UUID (e.g., `c594a031-5041-45ff-a72c-ba127c9884d1`)

### Setting up Splunk HEC

1. **Enable HEC in Splunk**:
   - Navigate to Settings > Data Inputs > HTTP Event Collector
   - Click "Global Settings" and enable "All Tokens"
   - Set the HTTP Port Number (default: 8088)

2. **Create HEC Token**:
   - Click "New Token"
   - Provide a name (e.g., "CrusoeAuditLogs")
   - Select or create an index for the logs
   - Configure sourcetype and other settings as needed
   - Save and copy the token value

## Usage

### Command Line Interface

The tool provides several commands for different use cases:

#### Check Configuration and Health
```bash
# Validate configuration
python main.py config-check

# Check connectivity to both services
python main.py health
```

#### Forward Recent Logs
```bash
# Forward logs from the last hour (default)
python main.py forward-recent

# Forward logs from the last 6 hours
python main.py forward-recent --hours 6

# Dry run (fetch but don't send to Splunk)
python main.py forward-recent --hours 1 --dry-run
```

#### Forward Logs for Specific Time Range
```bash
# Forward logs for a specific time range
python main.py forward-range --start-time "2024-01-01T00:00:00Z" --end-time "2024-01-01T23:59:59Z"

# Dry run for time range
python main.py forward-range --start-time "2024-01-01T00:00:00Z" --dry-run
```

#### Daemon Mode (Continuous Operation)
```bash
# Run continuously, forwarding logs every 5 minutes (300 seconds)
# Initial lookback of 10 minutes, then only new logs since last run
# Deduplication enabled by default
python main.py daemon

# Custom interval and initial lookback period
python main.py daemon --interval 600 --lookback 1800

# Custom deduplication buffer (extends time window for hash tracking)
python main.py daemon --interval 300 --dedup-buffer-seconds 120

# Disable deduplication entirely
python main.py daemon --disable-dedup --interval 300
```

#### Deduplication Management
```bash
# Check deduplication statistics
python main.py dedup-stats

# Clear deduplication state (fresh start)
python main.py dedup-stats --clear
```

### Example Workflow

1. **Initial Setup and Testing**:
   ```bash
   # Check configuration
   python main.py config-check
   
   # Test connectivity
   python main.py health
   
   # Test with a dry run
   python main.py forward-recent --hours 1 --dry-run
   ```

2. **One-time Log Forward**:
   ```bash
   # Forward logs from the last 24 hours
   python main.py forward-recent --hours 24
   ```

3. **Continuous Operation**:
   ```bash
   # Run as a daemon, checking every 10 minutes with 30 minute initial lookback
   # Deduplication enabled with default 60s buffer
   python main.py daemon --interval 600 --lookback 1800
   
   # For high-frequency environments, increase deduplication buffer
   python main.py daemon --interval 300 --lookback 900 --dedup-buffer-seconds 180
   ```

## Deduplication System

The tool includes an advanced deduplication system to prevent duplicate logs from being sent to Splunk, even across daemon restarts and partial failures.

### How It Works

1. **Two-Phase Process**:
   - **Phase 1**: Filter duplicates based on existing hash state (read-only)
   - **Phase 2**: Mark events as "sent" only after successful Splunk delivery

2. **Time-Window Hash Tracking**:
   - Generates SHA256 hashes based on key event fields (`start_time`, `actor_id`, `action`, etc.)
   - Maintains hashes for a calculated time window: `interval + 30s_overlap + buffer`
   - Automatically cleans up old hashes beyond the time window

3. **Disk Persistence**:
   - State saved to `~/.crusoe_dedup_state.json`
   - **Critical**: Hashes only written to disk after successful Splunk submission
   - Atomic file operations prevent corruption
   - Restart-safe: daemon loads previous state on startup

### Configuration Options

```bash
# Enable/disable deduplication (enabled by default)
--enable-dedup / --disable-dedup

# Set buffer time for hash tracking window (default: 60 seconds)
--dedup-buffer-seconds SECONDS
```

### Time Window Calculation

**Total Hash Tracking Window = `daemon_interval` + `30` (overlap) + `dedup_buffer_seconds`**

**Examples**:
- Interval 300s + Buffer 60s = **390 second** tracking window
- Interval 600s + Buffer 120s = **750 second** tracking window

### Deduplication Guarantees

✅ **Zero Duplicates**: No duplicate events sent to Splunk within tracking window  
✅ **Failure Safety**: Failed events will be retried (not marked as sent)  
✅ **Restart Safety**: State persists across daemon restarts  
✅ **Partial Failure Handling**: Only successful events marked as sent  

### Monitoring Deduplication

```bash
# View current deduplication statistics
python main.py dedup-stats

# Sample output:
# Deduplication Statistics:
#   Status: Enabled
#   Tracking Window: 390 seconds
#   Tracked Events: 1247
#   State File: /home/user/.crusoe_dedup_state.json
#   Oldest Event: 2024-01-15 10:23:45+00:00
#   Newest Event: 2024-01-15 10:29:15+00:00

# Clear all deduplication state (fresh start)
python main.py dedup-stats --clear
```

### When to Disable Deduplication

Consider disabling deduplication if:
- You have external deduplication mechanisms in Splunk
- Memory/storage constraints are critical
- You need maximum throughput without safety guarantees

## Log Format

Logs are sent to Splunk in the following format:

```json
{
  "time": 1693737063.941,
  "event": {
    "action": "Create",
    "action_detail": "",
    "actor_id": "be34759e-fa6b-41e0-bbe6-9159516c9613",
    "actor_email": "user@crusoeenergy.com",
    "actor_type": "User",
    "client_ip": "10.193.200.150:36338",
    "end_time": "2025-09-03T15:11:03.941Z",
    "error_message": "",
    "locations": [],
    "organization_id": "c594a031-5041-45ff-a72c-ba127c9884d1",
    "organization_name": "crusoe-dx-lab",
    "project_id": "",
    "project_name": "",
    "target_ids": [],
    "target_names": ["API access"],
    "target_type": "UserAccessToken",
    "result": "OK",
    "start_time": "2025-09-03T15:11:03.904Z",
    "surface": "Console"
  },
  "sourcetype": "crusoe:audit",
  "source": "crusoe_api",
  "index": "your_index"
}
```

## Error Handling

The tool includes comprehensive error handling:

- **Retry Logic**: Automatic retries for transient failures
- **Batch Processing**: If one batch fails, others continue processing
- **Graceful Degradation**: Continues operation even if some logs fail to send
- **Detailed Logging**: All operations are logged for debugging

## Monitoring and Logs

- Application logs are written to both console and `crusoe-splunk-hec.log`
- Health check commands can be used for monitoring
- Daemon mode includes regular status logging

## Production Deployment

For production use, consider:

1. **Process Management**: Use systemd, supervisor, or similar to manage the daemon process
2. **Environment Security**: Store credentials securely (e.g., AWS Secrets Manager, HashiCorp Vault)
3. **Monitoring**: Set up alerts based on log output and health checks
4. **Resource Limits**: Configure appropriate batch sizes and intervals based on your log volume
5. **Network**: Ensure firewall rules allow access to both Crusoe API and Splunk HEC

### Example systemd Service

```ini
[Unit]
Description=Crusoe to Splunk HEC Log Forwarder
After=network.target

[Service]
Type=simple
User=your-user
WorkingDirectory=/path/to/cursor-splunk-hec
Environment=PATH=/path/to/venv/bin
ExecStart=/path/to/venv/bin/python main.py daemon --interval 300 --lookback 900 --dedup-buffer-seconds 120
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

## Troubleshooting

### Common Issues

1. **Authentication Errors**:
   - Verify access key ID and secret access key are correct
   - Check that organization ID is correct (must be UUID format)
   - Ensure API keys have audit log access permissions

2. **Network Connectivity**:
   - Ensure firewall rules allow outbound HTTPS traffic
   - Verify Splunk HEC endpoint is accessible
   - Check SSL certificate validation settings

3. **Splunk HEC Issues**:
   - Verify HEC is enabled in Splunk
   - Check that the index exists and is accessible
   - Confirm HEC token has write permissions

4. **No Logs Found**:
   - Verify the time range includes periods with activity
   - Check that audit logging is enabled in Crusoe Cloud
   - Ensure organization ID is correct

5. **Duplicate Logs in Splunk**:
   - Check if deduplication is enabled: `python main.py dedup-stats`
   - Verify time window is appropriate for your daemon interval
   - Consider increasing `--dedup-buffer-seconds` for high-frequency events
   - Clear deduplication state if needed: `python main.py dedup-stats --clear`

### Debug Mode

Enable debug logging by modifying the logging level in `main.py`:

```python
logging.basicConfig(level=logging.DEBUG, ...)
```

## API Reference

### Crusoe Cloud Audit Logs API

Based on the [official documentation](https://docs.crusoecloud.com/reference/api/):

- **Endpoint**: `GET /organizations/{organization_id}/audit-logs`
- **Authentication**: Custom HMAC-SHA256 signature method with access key/secret
- **Parameters**: Various filters for time range, pagination, etc.
- **Query Parameters**: Must be URL-encoded in signature generation

### Splunk HTTP Event Collector

- **Endpoint**: `POST /services/collector`
- **Authentication**: `Splunk {token}` in Authorization header
- **Format**: NDJSON (newline-delimited JSON) events

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## License

MIT License - see LICENSE file for details.

## Support

For issues related to:
- **Crusoe Cloud API**: Check [Crusoe Cloud documentation](https://docs.crusoecloud.com)
- **Splunk HEC**: Check [Splunk documentation](https://docs.splunk.com)
- **This tool**: Create an issue in this repository
