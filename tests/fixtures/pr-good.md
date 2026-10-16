## Summary
Adds the deploy workflow for the new Worker.

## Credentials
The token is code: see the `api_tokens.tf` entry in the setkernel-cloudflare PR (linked below), applied on merge.
After that merges, Raghav pipes the value with `scripts/infisical-put.py example-ci CLOUDFLARE_API_TOKEN`;
nobody types or pastes it.
