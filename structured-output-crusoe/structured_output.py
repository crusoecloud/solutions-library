"""
Structured output and tool calling on Crusoe Managed Inference.
Demonstrates Pydantic-validated responses and tool use with ChatCrusoe.
Tested locally with Groq as a drop-in replacement for Crusoe.
"""
import os
from dotenv import load_dotenv
from pydantic import BaseModel, Field
from langchain_core.messages import HumanMessage, SystemMessage

load_dotenv()


def get_llm():
    if os.getenv("CRUSOE_API_KEY"):
        from langchain_crusoe import ChatCrusoe
        return ChatCrusoe(
            model="meta-llama/Llama-3.3-70B-Instruct",
            temperature=0,
            max_tokens=1024,
        )
    else:
        from langchain_groq import ChatGroq
        return ChatGroq(
            model="llama-3.3-70b-versatile",
            temperature=0,
            max_tokens=1024,
        )


# --- Pydantic schemas ---

class TechSummary(BaseModel):
    """Structured summary of a technology or concept."""
    name: str = Field(description="Name of the technology")
    category: str = Field(description="Category e.g. infrastructure, framework, database")
    one_line: str = Field(description="One sentence explanation")
    strengths: list[str] = Field(description="3 key strengths")
    use_cases: list[str] = Field(description="3 common use cases")
    maturity: str = Field(description="One of: experimental, growing, mature")


class CodeReview(BaseModel):
    """Structured code review output."""
    verdict: str = Field(description="One of: approve, request_changes, comment")
    issues: list[str] = Field(description="List of issues found, empty if none")
    suggestions: list[str] = Field(description="List of improvement suggestions")
    score: int = Field(description="Code quality score from 1 to 10", ge=1, le=10)


class EntityExtraction(BaseModel):
    """Entities extracted from text."""
    companies: list[str] = Field(description="Company names mentioned")
    technologies: list[str] = Field(description="Technologies or tools mentioned")
    people: list[str] = Field(description="People mentioned")
    locations: list[str] = Field(description="Locations mentioned")


# --- Tool definition ---

class WeatherTool(BaseModel):
    """Get current weather for a location."""
    location: str = Field(description="City and state, e.g. San Francisco, CA")
    unit: str = Field(description="Temperature unit: celsius or fahrenheit", default="fahrenheit")


# --- Demo functions ---

def demo_structured_summary():
    print("=" * 60)
    print("DEMO 1: Structured output with Pydantic schema")
    print("=" * 60)
    llm = get_llm()
    structured = llm.with_structured_output(TechSummary)
    result = structured.invoke("Summarize Qdrant as a technology.")
    print(f"Name:      {result.name}")
    print(f"Category:  {result.category}")
    print(f"Summary:   {result.one_line}")
    print(f"Maturity:  {result.maturity}")
    print(f"Strengths: {result.strengths}")
    print(f"Use cases: {result.use_cases}")


def demo_code_review():
    print("\n" + "=" * 60)
    print("DEMO 2: Structured code review")
    print("=" * 60)
    code = """
def get_user(id):
    query = "SELECT * FROM users WHERE id = " + id
    return db.execute(query)
"""
    llm = get_llm()
    reviewer = llm.with_structured_output(CodeReview)
    result = reviewer.invoke(f"Review this Python code:\n{code}")
    print(f"Verdict:     {result.verdict}")
    print(f"Score:       {result.score}/10")
    print(f"Issues:      {result.issues}")
    print(f"Suggestions: {result.suggestions}")


def demo_entity_extraction():
    print("\n" + "=" * 60)
    print("DEMO 3: Entity extraction")
    print("=" * 60)
    text = (
        "Crusoe Cloud, founded in San Francisco, uses NVIDIA GPUs and Kubernetes "
        "to power AI workloads. CEO Chase Lochmiller recently announced a partnership "
        "with Meta to run Llama models on their Wyoming data center."
    )
    llm = get_llm()
    extractor = llm.with_structured_output(EntityExtraction)
    result = extractor.invoke(f"Extract all entities from this text:\n{text}")
    print(f"Companies:    {result.companies}")
    print(f"Technologies: {result.technologies}")
    print(f"People:       {result.people}")
    print(f"Locations:    {result.locations}")


def demo_tool_calling():
    print("\n" + "=" * 60)
    print("DEMO 4: Tool calling")
    print("=" * 60)
    llm = get_llm()
    llm_with_tools = llm.bind_tools([WeatherTool])
    response = llm_with_tools.invoke([
        SystemMessage(content="You are a helpful assistant with access to weather tools."),
        HumanMessage(content="What's the weather like in Austin, TX?"),
    ])
    if response.tool_calls:
        for call in response.tool_calls:
            print(f"Tool called: {call['name']}")
            print(f"Arguments:   {call['args']}")
    else:
        print(response.content)


if __name__ == "__main__":
    demo_structured_summary()
    demo_code_review()
    demo_entity_extraction()
    demo_tool_calling()
