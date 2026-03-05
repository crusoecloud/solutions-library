"""Crusoe AI Chat Models integration for LangChain.

Wrapper around Crusoe's Managed Inference API, which provides
an OpenAI-compatible chat completions endpoint at api.crusoe.ai.
"""

from typing import Any, Dict, List, Optional

import openai
from langchain_core.language_models.chat_models import LangSmithParams
from langchain_core.utils import from_env, secret_from_env
from langchain_openai.chat_models.base import BaseChatOpenAI
from pydantic import ConfigDict, Field, SecretStr, model_validator
from typing_extensions import Self


class ChatCrusoe(BaseChatOpenAI):
    r"""Crusoe AI Managed Inference chat model.

    Crusoe provides high-performance inference for leading open-source models
    via the Crusoe Intelligence Foundry, powered by MemoryAlloy technology
    for ultra-low latency and high throughput.

    Setup:
        Install ``langchain-crusoe`` and set environment variable
        ``CRUSOE_API_KEY``.

        .. code-block:: bash

            pip install -U langchain-crusoe
            export CRUSOE_API_KEY="your-api-key"

    Key init args — completion params:
        model: str
            Name of Crusoe-hosted model to use.
            e.g. "meta-llama/Llama-3.3-70B-Instruct"
        temperature: float
            Sampling temperature.
        max_tokens: Optional[int]
            Max number of tokens to generate.

    Key init args — client params:
        timeout: Union[float, Tuple[float, float], Any, None]
            Timeout for requests.
        max_retries: int
            Max number of retries.
        api_key: Optional[str]
            Crusoe API key. If not passed in will be read from env var
            CRUSOE_API_KEY.

    See full list of supported init args and their descriptions in the
    params section.

    Instantiate:
        .. code-block:: python

            from langchain_crusoe import ChatCrusoe

            llm = ChatCrusoe(
                model="meta-llama/Llama-3.3-70B-Instruct",
                temperature=0,
                max_tokens=None,
                timeout=None,
                max_retries=2,
                # api_key="...",
            )

    Invoke:
        .. code-block:: python

            messages = [
                ("system", "You are a helpful translator."),
                ("human", "Translate 'I love programming' to French."),
            ]
            llm.invoke(messages)

        .. code-block:: python

            AIMessage(
                content="J'adore la programmation.",
                response_metadata={...},
                id='run-...',
            )

    Stream:
        .. code-block:: python

            for chunk in llm.stream(messages):
                print(chunk.content, end="", flush=True)

    Async:
        .. code-block:: python

            await llm.ainvoke(messages)

    Tool calling:
        .. code-block:: python

            from pydantic import BaseModel, Field

            class GetWeather(BaseModel):
                '''Get the current weather in a given location.'''
                location: str = Field(
                    ..., description="City and state, e.g. San Francisco, CA"
                )

            llm_with_tools = llm.bind_tools([GetWeather])
            ai_msg = llm_with_tools.invoke(
                "What is the weather like in San Francisco?"
            )
            ai_msg.tool_calls

    Structured output:
        .. code-block:: python

            from pydantic import BaseModel, Field
            from typing import Optional

            class Joke(BaseModel):
                '''Joke to tell user.'''
                setup: str = Field(description="The setup of the joke")
                punchline: str = Field(description="The punchline")
                rating: Optional[int] = Field(
                    description="How funny, from 1 to 10"
                )

            structured_llm = llm.with_structured_output(Joke)
            structured_llm.invoke("Tell me a joke about AI")

    Available models (as of 2025):
        - meta-llama/Llama-3.3-70B-Instruct
        - openai/gpt-oss-120b
        - deepseek-ai/DeepSeek-V3-0324
        - deepseek-ai/DeepSeek-R1-0528
        - deepseek-ai/DeepSeek-V3.1
        - Qwen/Qwen3-235B-A22B
        - google/gemma-3-12b-it
        - moonshotai/Kimi-K2-Thinking

    See the Crusoe Intelligence Foundry for the latest model list:
    https://console.crusoecloud.com/foundry/models
    """

    model_config = ConfigDict(populate_by_name=True)

    model_name: str = Field(
        default="meta-llama/Llama-3.3-70B-Instruct",
        alias="model",
    )
    """Model name to use. See https://docs.crusoecloud.com/managed-inference/overview
    for available models."""

    crusoe_api_key: Optional[SecretStr] = Field(
        alias="api_key",
        default_factory=secret_from_env("CRUSOE_API_KEY", default=None),
    )
    """Crusoe API key.

    Automatically read from env var ``CRUSOE_API_KEY`` if not provided.
    """

    crusoe_api_base: str = Field(
        default_factory=from_env(
            "CRUSOE_API_BASE", default="https://managed-inference-api-proxy.crusoecloud.com/v1"
        ),
    )
    """Base URL for the Crusoe API.

    Defaults to ``https://managed-inference-api-proxy.crusoecloud.com/v1``.
    Can be overridden via env var ``CRUSOE_API_BASE``.
    """

    crusoe_project_id: Optional[str] = Field(
        default_factory=from_env("CRUSOE_PROJECT_ID", default=None),
    )
    """Optional Crusoe project ID for request attribution.

    Read from env var ``CRUSOE_PROJECT_ID`` if not provided.
    """

    @property
    def _llm_type(self) -> str:
        """Return type of chat model."""
        return "crusoe-chat"

    @property
    def lc_secrets(self) -> Dict[str, str]:
        return {"crusoe_api_key": "CRUSOE_API_KEY"}

    @model_validator(mode="after")
    def validate_environment(self) -> Self:
        """Validate that api key and base url are set."""
        if not self.crusoe_api_key:
            raise ValueError(
                "Crusoe API key must be provided. Set the CRUSOE_API_KEY "
                "environment variable or pass `api_key` to the constructor. "
                "Get your key at: https://console.crusoecloud.com/"
            )

        # Configure the OpenAI client to point to Crusoe's endpoint
        self.openai_api_key = self.crusoe_api_key
        self.openai_api_base = self.crusoe_api_base

        # Build default headers with optional project ID
        if self.crusoe_project_id:
            self.default_headers = {
                **(self.default_headers or {}),
                "Crusoe-Project-Id": self.crusoe_project_id,
            }

        # Initialize the clients
        client_params: dict = {
            "api_key": self.crusoe_api_key.get_secret_value(),
            "base_url": self.crusoe_api_base,
            "timeout": self.request_timeout,
            "max_retries": self.max_retries if self.max_retries is not None else 2,
            "default_headers": self.default_headers,
        }

        if not self.client:
            self.client = openai.OpenAI(**client_params).chat.completions
        if not self.async_client:
            self.async_client = (
                openai.AsyncOpenAI(**client_params).chat.completions
            )
        return self

    def _get_ls_params(
        self, stop: Optional[List[str]] = None, **kwargs: Any
    ) -> LangSmithParams:
        """Get standard params for tracing in LangSmith."""
        params = self._get_invocation_params(stop=stop, **kwargs)
        ls_params = LangSmithParams(
            ls_provider="crusoe",
            ls_model_name=self.model_name,
            ls_model_type="chat",
            ls_temperature=params.get("temperature", self.temperature),
        )
        if ls_max_tokens := params.get("max_tokens", self.max_tokens):
            ls_params["ls_max_tokens"] = ls_max_tokens
        if ls_stop := stop or params.get("stop", None) or getattr(self, "stop", None):
            ls_params["ls_stop"] = ls_stop
        return ls_params
