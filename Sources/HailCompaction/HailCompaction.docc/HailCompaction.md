# ``HailCompaction``

Keeping an agent's history within its model's window.

## Overview

``SlidingWindowCompactor`` is the reference context compactor. When the context passes a share of
the model's window, earlier turns are folded into a summary, journaled once, so replay never runs
the summarizer again. The turn being answered keeps its input.

Counting is estimated by ``TokenEstimator``, or exact with ``TokenCounter``, which uses a model's
own tokenizer.

## Topics

### Compacting

- ``SlidingWindowCompactor``
- ``CompactionTask``

### Counting

- ``TokenCounter``
- ``TokenEstimator``
