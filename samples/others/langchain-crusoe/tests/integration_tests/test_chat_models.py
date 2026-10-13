"""Integration tests for ChatCrusoe.

These tests require a valid CRUSOE_API_KEY environment variable.
Run with: make integration_tests
"""

import pytest
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage

from langchain_crusoe import ChatCrusoe

# Default model for integration tests
TEST_MODEL = "meta-llama/Llama-3.3-70B-Instruct"


@pytest.fixture
def llm() -> ChatCrusoe:
    """Create a ChatCrusoe instance for testing."""
    return ChatCrusoe(model=TEST_MODEL, temperature=0, max_tokens=256)


class TestChatCrusoeInvoke:
    """Test synchronous invocation."""

    def test_invoke_simple(self, llm: ChatCrusoe) -> None:
        """Test simple message invocation."""
        msg = llm.invoke("Say hello in exactly 3 words.")
        assert isinstance(msg, AIMessage)
        assert isinstance(msg.content, str)
        assert len(msg.content) > 0

    def test_invoke_with_system_message(self, llm: ChatCrusoe) -> None:
        """Test invocation with system message."""
        messages = [
            SystemMessage(content="You are a helpful translator."),
            HumanMessage(content="Translate 'hello' to French."),
        ]
        msg = llm.invoke(messages)
        assert isinstance(msg, AIMessage)
        assert len(msg.content) > 0

    def test_invoke_returns_usage_metadata(self, llm: ChatCrusoe) -> None:
        """Test that response includes token usage metadata."""
        msg = llm.invoke("Say hi.")
        assert msg.usage_metadata is not None
        assert msg.usage_metadata["input_tokens"] > 0
        assert msg.usage_metadata["output_tokens"] > 0
        assert msg.usage_metadata["total_tokens"] > 0


class TestChatCrusoeStream:
    """Test streaming."""

    def test_stream(self, llm: ChatCrusoe) -> None:
        """Test that streaming produces chunks."""
        chunks = list(llm.stream("Count from 1 to 5."))
        assert len(chunks) > 1
        # Combine all chunks to verify content
        full_content = "".join(
            chunk.content for chunk in chunks if chunk.content
        )
        assert len(full_content) > 0


class TestChatCrusoeAsync:
    """Test async invocation."""

    async def test_ainvoke(self, llm: ChatCrusoe) -> None:
        """Test async invocation."""
        msg = await llm.ainvoke("Say hello.")
        assert isinstance(msg, AIMessage)
        assert len(msg.content) > 0

    async def test_astream(self, llm: ChatCrusoe) -> None:
        """Test async streaming."""
        chunks = []
        async for chunk in llm.astream("Count from 1 to 3."):
            chunks.append(chunk)
        assert len(chunks) > 1


class TestChatCrusoeStructuredOutput:
    """Test structured output capabilities."""

    def test_with_structured_output(self, llm: ChatCrusoe) -> None:
        """Test structured output with a JSON schema."""
        from pydantic import BaseModel, Field

        class Capital(BaseModel):
            """The capital city of a country."""

            country: str = Field(description="The country name")
            capital: str = Field(description="The capital city")

        structured_llm = llm.with_structured_output(Capital)
        result = structured_llm.invoke("What is the capital of France?")
        assert isinstance(result, Capital)
        assert result.capital.lower() == "paris"


class TestChatCrusoeModels:
    """Test different available models."""

    @pytest.mark.parametrize(
        "model",
        [
            "meta-llama/Llama-3.3-70B-Instruct",
            "google/gemma-3-12b-it",
        ],
    )
    def test_model_invoke(self, model: str) -> None:
        """Test invocation with different models."""
        llm = ChatCrusoe(model=model, temperature=0, max_tokens=64)
        msg = llm.invoke("What is 2+2? Answer with just the number.")
        assert isinstance(msg, AIMessage)
        assert "4" in msg.content
