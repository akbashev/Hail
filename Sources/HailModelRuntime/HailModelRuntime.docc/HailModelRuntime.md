# ``HailModelRuntime``

Model routing: reaching a model where it runs, with the host's keys and settings, and reading what
its provider says when a request fails.

## Overview

``ModelRouter`` turns an agent's model into a ``ModelEndpoint`` the runtime can ask, configured by
the host's ``ModelRouterConfiguration``: keys, base URLs, generation settings, context windows and
reasoning capabilities. Hail reads no provider settings from the environment.

``AnyLanguageModelEndpoint`` reaches models through AnyLanguageModel: hosted APIs, local and
self-hosted servers, and Apple's Foundation Models. ``ModelAccess`` asks a provider about its
models: which there are, and whether one is available with a key.

When a provider refuses or fails a request, ``ProviderFailures`` reads what it means: too long for
the context, busy or rate-limited with when to ask again, or never reached. Only a request that
produced nothing is asked again.

## Topics

### Routing

- ``ModelRouter``
- ``ModelRouterConfiguration``
- ``AnyLanguageModelEndpoint``
- ``ModelTransports``
- ``RequestPool``

### A provider's models

- ``ModelAccess``
- ``ModelAccount``
- ``ModelAvailability``
- ``ModelUnavailability``
- ``ModelDetails``
- ``ModelContextWindowResolver``
- ``OllamaContext``

### Failures

- ``ProviderFailures``
- ``ModelRouterError``
- ``ModelRouterConfigurationError``
- ``TimeoutError``
