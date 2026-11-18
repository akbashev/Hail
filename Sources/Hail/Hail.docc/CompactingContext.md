# Compacting context

How an agent's history is kept within its model's window.

## Overview

Models keep no memory between requests, so the runtime offers compaction before every model
request, through a `ContextCompactor` the host gives the runtime.

The reference implementation is `SlidingWindowCompactor`, in the `HailCompaction` product. When the
context passes a share of the model's window, earlier turns are folded into a summary. The summary
is journaled once, so replay never runs the summarizer again. The turn being answered keeps its
input.

For exact local counts, `TokenCounter` in `HailCompaction` gives the compactor a model's own
tokenizer.

A request a provider refuses as too long for its context is compacted and asked again: see
<doc:ModelsAndProviders>.
