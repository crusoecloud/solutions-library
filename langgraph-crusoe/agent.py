"""
LangGraph multi-node research agent.
Designed for Crusoe Managed Inference (OpenAI-compatible).
Tested locally with Groq as a drop-in replacement.
"""
from typing import TypedDict, Annotated
from langgraph.graph import StateGraph, END
from langgraph.graph.message import add_messages
from langchain_core.messages import HumanMessage, SystemMessage


class AgentState(TypedDict):
    messages: Annotated[list, add_messages]
    topic: str
    analysis: str
    summary: str


def get_llm():
    """
    Returns a ChatCrusoe instance for production use.
    For local testing, we use ChatGroq as a drop-in replacement
    since both are OpenAI-compatible.
    """
    import os
    if os.getenv("CRUSOE_API_KEY"):
        from langchain_crusoe import ChatCrusoe
        return ChatCrusoe(
            model="meta-llama/Llama-3.3-70B-Instruct",
            temperature=0.3,
            max_tokens=1024,
        )
    else:
        from langchain_groq import ChatGroq
        return ChatGroq(
            model="llama-3.3-70b-versatile",
            temperature=0.3,
            max_tokens=1024,
        )


def research_node(state: AgentState) -> AgentState:
    """Node 1: gather key facts about the topic."""
    llm = get_llm()
    response = llm.invoke([
        SystemMessage(content="You are a research assistant. Gather key facts and context about the given topic. Be thorough and factual."),
        HumanMessage(content=f"Research this topic and return key facts: {state['topic']}")
    ])
    return {"messages": [response]}


def analysis_node(state: AgentState) -> AgentState:
    """Node 2: analyze the research and extract insights."""
    llm = get_llm()
    prior_research = state["messages"][-1].content
    response = llm.invoke([
        SystemMessage(content="You are an analyst. Given research notes, identify the 3 most important insights and any open questions."),
        HumanMessage(content=f"Analyze this research:\n\n{prior_research}")
    ])
    return {"messages": [response], "analysis": response.content}


def summarize_node(state: AgentState) -> AgentState:
    """Node 3: produce a clean, concise final summary."""
    llm = get_llm()
    response = llm.invoke([
        SystemMessage(content="You are a writer. Produce a clear, 3-paragraph summary from the analysis provided. Use plain language."),
        HumanMessage(content=f"Summarize this analysis:\n\n{state['analysis']}")
    ])
    return {"messages": [response], "summary": response.content}


def build_research_graph():
    """Build and compile the 3-node research graph."""
    graph = StateGraph(AgentState)

    graph.add_node("research", research_node)
    graph.add_node("analysis", analysis_node)
    graph.add_node("summarize", summarize_node)

    graph.set_entry_point("research")
    graph.add_edge("research", "analysis")
    graph.add_edge("analysis", "summarize")
    graph.add_edge("summarize", END)

    return graph.compile()


def run_research_agent(topic: str) -> dict:
    """Run the full pipeline on a topic."""
    graph = build_research_graph()
    result = graph.invoke({
        "topic": topic,
        "messages": [],
        "analysis": "",
        "summary": ""
    })
    return {
        "topic": topic,
        "analysis": result["analysis"],
        "summary": result["summary"],
    }
