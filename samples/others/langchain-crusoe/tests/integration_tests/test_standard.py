"""Standard LangChain integration tests for ChatCrusoe.

These tests use the langchain-tests suite to ensure compliance
with the LangChain ChatModel interface.
"""

from langchain_tests.integration_tests import ChatModelIntegrationTests

from langchain_crusoe import ChatCrusoe


class TestChatCrusoeStandard(ChatModelIntegrationTests):
    """Run the standard LangChain ChatModel integration tests."""

    @property
    def chat_model_class(self) -> type[ChatCrusoe]:
        return ChatCrusoe

    @property
    def chat_model_params(self) -> dict:
        return {
            "model": "meta-llama/Llama-3.3-70B-Instruct",
            "temperature": 0,
            "max_tokens": 256,
        }
