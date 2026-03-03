"""Unit tests for ChatCrusoe chat model."""

import os
from unittest.mock import patch

import pytest
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage

from langchain_crusoe import ChatCrusoe


class TestChatCrusoeInit:
    """Test ChatCrusoe initialization."""

    def test_default_model(self) -> None:
        """Test default model is set correctly."""
        with patch.dict(os.environ, {"CRUSOE_API_KEY": "test-key"}):
            llm = ChatCrusoe()
        assert llm.model_name == "meta-llama/Llama-3.3-70B-Instruct"

    def test_custom_model(self) -> None:
        """Test custom model name."""
        with patch.dict(os.environ, {"CRUSOE_API_KEY": "test-key"}):
            llm = ChatCrusoe(model="deepseek-ai/DeepSeek-V3-0324")
        assert llm.model_name == "deepseek-ai/DeepSeek-V3-0324"

    def test_api_key_from_env(self) -> None:
        """Test API key is read from environment variable."""
        with patch.dict(os.environ, {"CRUSOE_API_KEY": "test-key-123"}):
            llm = ChatCrusoe()
        assert llm.crusoe_api_key.get_secret_value() == "test-key-123"

    def test_api_key_from_param(self) -> None:
        """Test API key passed as parameter."""
        llm = ChatCrusoe(api_key="direct-key-456")
        assert llm.crusoe_api_key.get_secret_value() == "direct-key-456"

    def test_missing_api_key_raises(self) -> None:
        """Test that missing API key raises ValueError."""
        with patch.dict(os.environ, {}, clear=True):
            with pytest.raises(ValueError, match="Crusoe API key must be provided"):
                ChatCrusoe()

    def test_default_api_base(self) -> None:
        """Test default API base URL."""
        with patch.dict(os.environ, {"CRUSOE_API_KEY": "test-key"}):
            llm = ChatCrusoe()
        assert llm.crusoe_api_base == "https://api.crusoe.ai/v1"

    def test_custom_api_base(self) -> None:
        """Test custom API base URL from env."""
        with patch.dict(
            os.environ,
            {
                "CRUSOE_API_KEY": "test-key",
                "CRUSOE_API_BASE": "https://custom.crusoe.ai/v1",
            },
        ):
            llm = ChatCrusoe()
        assert llm.crusoe_api_base == "https://custom.crusoe.ai/v1"

    def test_project_id_header(self) -> None:
        """Test that project ID is set as a default header."""
        with patch.dict(
            os.environ,
            {
                "CRUSOE_API_KEY": "test-key",
                "CRUSOE_PROJECT_ID": "proj-123",
            },
        ):
            llm = ChatCrusoe()
        assert llm.default_headers.get("Crusoe-Project-Id") == "proj-123"

    def test_llm_type(self) -> None:
        """Test _llm_type property."""
        with patch.dict(os.environ, {"CRUSOE_API_KEY": "test-key"}):
            llm = ChatCrusoe()
        assert llm._llm_type == "crusoe-chat"

    def test_lc_secrets(self) -> None:
        """Test lc_secrets property."""
        with patch.dict(os.environ, {"CRUSOE_API_KEY": "test-key"}):
            llm = ChatCrusoe()
        assert llm.lc_secrets == {"crusoe_api_key": "CRUSOE_API_KEY"}


class TestChatCrusoeLangSmithParams:
    """Test LangSmith tracing parameters."""

    def test_ls_params_basic(self) -> None:
        """Test basic LangSmith params."""
        with patch.dict(os.environ, {"CRUSOE_API_KEY": "test-key"}):
            llm = ChatCrusoe(
                model="deepseek-ai/DeepSeek-V3-0324",
                temperature=0.7,
            )
        ls_params = llm._get_ls_params()
        assert ls_params["ls_provider"] == "crusoe"
        assert ls_params["ls_model_name"] == "deepseek-ai/DeepSeek-V3-0324"
        assert ls_params["ls_model_type"] == "chat"

    def test_ls_params_with_max_tokens(self) -> None:
        """Test LangSmith params include max_tokens when set."""
        with patch.dict(os.environ, {"CRUSOE_API_KEY": "test-key"}):
            llm = ChatCrusoe(max_tokens=1024)
        ls_params = llm._get_ls_params()
        assert ls_params["ls_max_tokens"] == 1024


class TestChatCrusoeImport:
    """Test that the package imports correctly."""

    def test_import_chat_crusoe(self) -> None:
        """Test that ChatCrusoe can be imported from the package."""
        from langchain_crusoe import ChatCrusoe

        assert ChatCrusoe is not None

    def test_is_base_chat_openai(self) -> None:
        """Test that ChatCrusoe inherits from BaseChatOpenAI."""
        from langchain_openai.chat_models.base import BaseChatOpenAI

        assert issubclass(ChatCrusoe, BaseChatOpenAI)
