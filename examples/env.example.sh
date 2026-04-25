#!/usr/bin/env bash
# Copy this file to env.sh (gitignored) and fill in your own values.
# The example scripts source env.sh, not this template.

# URL of the deployed Worker (or http://localhost:8787 for `wrangler dev`).
export BASE_URL="http://localhost:8787"

# Bearer API key. Must match one of the entries in server/.dev.vars API_KEYS
# (or in the production secret of the same name).
export API_KEY="dev-key-1"
