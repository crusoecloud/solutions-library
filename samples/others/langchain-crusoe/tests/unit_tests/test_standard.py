"""Standard LangChain unit tests for ChatCrusoe.

These tests use the langchain-tests suite to ensure compliance
with the LangChain ChatModel interface without requiring API access.
"""

from langchain_tests.unit_tests import ChatModelUnitTests

from langchain_crusoe import ChatCrusoe


class TestChatCrusoeStandard(ChatModelUnitTests):
    """Run the standard LangChain ChatModel unit tests."""

    @property
    def chat_model_class(self) -> type[ChatCrusoe]:
        return ChatCrusoe

    @property
    def chat_model_params(self) -> dict:
        return {
            "api_key": "test-api-key",
            "model": "meta-llama/Llama-3.3-70B-Instruct",
        }
