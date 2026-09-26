# The closed vocabulary of reasons a check could not be completed (spec 7.4). Summaries and exports only
# ever use these.
$script:MbcCauses = @(
    'permission missing',
    'not found',
    'throttled',
    'service error',
    'malformed response',
    'request rejected',
    'too many pages',
    'setting not found',
    'baseline expects a list',
    'baseline expects a single value',
    'invalid pattern',
    'pattern too slow',
    'request not declared',
    'not connected',
    'cmdlet not available',
    'cmdlet failed',
    'not collected'
)
