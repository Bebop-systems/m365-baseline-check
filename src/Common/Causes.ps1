# The closed vocabulary of reasons a check could not be completed. Summaries and exports only ever use these.
$script:MbcCauses = @(
    'permission missing',
    'not found',
    'throttled',
    'service error',
    'malformed response',
    'request rejected',
    'too many pages',
    'setting not found',
    'extractor failed',
    'extractor not allowed',
    'baseline expects a list',
    'baseline expects a single value',
    'invalid pattern',
    'pattern too slow',
    'endpoint not declared',
    'not collected'
)
