"""Google ADK agent powered by Crusoe Managed Inference via LiteLLM.

Run interactively from the parent directory:
    adk run google-adk-crusoe
or launch the dev UI:
    adk web
"""

import datetime
from zoneinfo import ZoneInfo

from google.adk.agents import Agent
from google.adk.models.lite_llm import LiteLlm


def get_current_time(city: str) -> dict:
    """Return the current time in a specified city.

    Args:
        city: The name of the city (e.g. "New York").

    Returns:
        A dict with the status and the current time report.
    """
    timezones = {
        "new york": "America/New_York",
        "london": "Europe/London",
        "tokyo": "Asia/Tokyo",
        "san francisco": "America/Los_Angeles",
    }
    tz_name = timezones.get(city.lower())
    if tz_name is None:
        return {
            "status": "error",
            "error_message": f"No timezone info available for '{city}'.",
        }
    now = datetime.datetime.now(ZoneInfo(tz_name))
    return {
        "status": "success",
        "report": f"The current time in {city} is {now.strftime('%Y-%m-%d %H:%M:%S %Z')}.",
    }


root_agent = Agent(
    name="crusoe_time_agent",
    model=LiteLlm(
        model="crusoe/zai/GLM-5.2",
        temperature=0.2,
        max_tokens=1024,
    ),
    description="Agent that answers time questions using Crusoe Managed Inference.",
    instruction=(
        "You are a helpful assistant. Use the get_current_time tool whenever "
        "the user asks about the current time in a city."
    ),
    tools=[get_current_time],
)
