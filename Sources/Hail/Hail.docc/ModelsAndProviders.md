# Models and providers

Where an agent's model runs, how the host configures it, and what happens when a provider fails.

## Overview

Models come through AnyLanguageModel: hosted APIs (OpenAI and OpenAI-compatible servers,
Anthropic, Gemini), local and self-hosted models (Ollama, MLX, llama.cpp, Core ML), and Apple's
Foundation Models. A host can add its own provider by implementing ``ModelEndpoint``, returned from
the runtime's `modelEndpointProvider`.

An ``AgentModel`` names a model where it runs, such as `ollama/qwen3:8b`; its
``AgentModelProvider`` is the where.

### Configuration

Hail reads no provider settings from the environment. Keys, base URLs and context windows are the
host's, given in ``ModelRouterConfiguration``:

```swift
let router = try ModelRouterConfiguration(
    temperature: 0.7,
    baseURLs: [.ollama: URL(string: "http://localhost:11434")!],
    modelContextWindows: [try AgentModel("ollama/qwen3:8b"): 32_768]
)
```

Reasoning is configured per model: ``ModelReasoningCapabilities`` says what a model can do, and
``ReasoningEffort`` what a request asks for.

### When a provider fails

Each provider says in its own way why a request failed. Hail reads it where the endpoint is made,
and acts on what it means:

- **Too long for the model's context:** the history is compacted and the request asked again.
- **Busy or rate-limited:** the request waits as the provider's `Retry-After` asks, within a limit,
  and is asked again.
- **Never reached the model:** it's sent again as it was.

Only a request that produced nothing is asked again. Once the model has called tools, those tools
have run, and asking again would run them twice.

### Usage

Each request's ``ModelUsage`` is recorded with it, and ``ContextUsage`` says how much of the model's
window a request filled.
