"""Configuration module for Crusoe to Splunk HEC log forwarder."""

import os
from typing import Optional
from pydantic import BaseModel, Field
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()


class CrusoeConfig(BaseModel):
    """Configuration for Crusoe Cloud API."""
    
    # Support both token-based and key-based authentication
    api_token: Optional[str] = Field(default=None, description="Crusoe Cloud API token")
    access_key_id: Optional[str] = Field(default=None, description="Crusoe Cloud access key ID (for AWS SigV4)")
    secret_access_key: Optional[str] = Field(default=None, description="Crusoe Cloud secret access key (for AWS SigV4)")
    
    base_url: str = Field(
        default="https://api.crusoecloud.com/v1alpha5",
        description="Crusoe Cloud API base URL"
    )
    organization_id: str = Field(..., description="Organization ID for audit logs")
    region: str = Field(default="us-east-1", description="AWS region for signing requests")
    
    @classmethod
    def from_env(cls) -> "CrusoeConfig":
        """Create configuration from environment variables."""
        return cls(
            api_token=os.getenv("CRUSOE_API_TOKEN"),
            access_key_id=os.getenv("CRUSOE_ACCESS_KEY_ID"),
            secret_access_key=os.getenv("CRUSOE_SECRET_ACCESS_KEY"),
            base_url=os.getenv("CRUSOE_BASE_URL", "https://api.crusoecloud.com/v1alpha5"),
            organization_id=os.getenv("CRUSOE_ORG_ID", ""),
            region=os.getenv("CRUSOE_REGION", "us-east-1")
        )


class SplunkConfig(BaseModel):
    """Configuration for Splunk HTTP Event Collector."""
    
    hec_token: str = Field(..., description="Splunk HEC token")
    hec_url: str = Field(..., description="Splunk HEC endpoint URL")
    index: Optional[str] = Field(default=None, description="Splunk index name")
    sourcetype: str = Field(default="crusoe:audit", description="Splunk sourcetype")
    source: str = Field(default="crusoe_api", description="Splunk source")
    verify_ssl: bool = Field(default=True, description="Verify SSL certificates")
    
    @classmethod
    def from_env(cls) -> "SplunkConfig":
        """Create configuration from environment variables."""
        return cls(
            hec_token=os.getenv("SPLUNK_HEC_TOKEN", ""),
            hec_url=os.getenv("SPLUNK_HEC_URL", ""),
            index=os.getenv("SPLUNK_INDEX"),
            sourcetype=os.getenv("SPLUNK_SOURCETYPE", "crusoe:audit"),
            source=os.getenv("SPLUNK_SOURCE", "crusoe_api"),
            verify_ssl=os.getenv("SPLUNK_VERIFY_SSL", "true").lower() == "true"
        )


class AppConfig(BaseModel):
    """Main application configuration."""
    
    crusoe: CrusoeConfig
    splunk: SplunkConfig
    batch_size: int = Field(default=100, description="Number of logs to send in each batch")
    timeout: int = Field(default=30, description="Request timeout in seconds")
    max_retries: int = Field(default=3, description="Maximum number of retries for failed requests")
    
    @classmethod
    def from_env(cls) -> "AppConfig":
        """Create configuration from environment variables."""
        return cls(
            crusoe=CrusoeConfig.from_env(),
            splunk=SplunkConfig.from_env(),
            batch_size=int(os.getenv("BATCH_SIZE", "100")),
            timeout=int(os.getenv("REQUEST_TIMEOUT", "30")),
            max_retries=int(os.getenv("MAX_RETRIES", "3"))
        )
    
    def validate_config(self) -> None:
        """Validate that all required configuration is present."""
        # Check Crusoe authentication - prefer token, fallback to access key + secret
        has_token = bool(self.crusoe.api_token)
        has_keys = bool(self.crusoe.access_key_id and self.crusoe.secret_access_key)
        
        if not has_token and not has_keys:
            raise ValueError(
                "Crusoe authentication required: either CRUSOE_API_TOKEN or "
                "(CRUSOE_ACCESS_KEY_ID + CRUSOE_SECRET_ACCESS_KEY) must be provided"
            )
        
        if not self.crusoe.organization_id:
            raise ValueError("CRUSOE_ORG_ID environment variable is required")
        if not self.splunk.hec_token:
            raise ValueError("SPLUNK_HEC_TOKEN environment variable is required")
        if not self.splunk.hec_url:
            raise ValueError("SPLUNK_HEC_URL environment variable is required")
