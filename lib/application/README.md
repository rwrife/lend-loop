# Application boundary

`ExchangeWorkflow` orchestrates record, list, detail, return, reopen, and attachment-association operations through domain repository interfaces. Runtime clock and ID generation are injected; tests use deterministic alternatives. Application code does not import concrete storage or platform plugins.
