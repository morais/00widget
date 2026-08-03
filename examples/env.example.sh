#!/usr/bin/env bash
# Copy this file to env.sh (gitignored) and fill in your own values.
# The example scripts source env.sh, not this template.

# URL of the deployed Worker (or http://localhost:8787 for `wrangler dev`).
export BASE_URL="http://localhost:8787"

# Bearer token for /v1/* calls. Create one in the admin dashboard
# (/admin → pick a tenant → "Create API token") and copy the raw value; it is
# shown once and stored only as a SHA-256 hash. Real tokens look like
# "zw_<43 chars>".
#
# This is NOT an API_KEYS value. API_KEYS holds bootstrap tokens for the admin
# fallback login only, and the /v1/* endpoints reject them. See
# server/README.md → "Admin dashboard".
#
# The placeholder below is deliberately one the Worker refuses, so an
# unedited copy fails fast instead of half-working.
export API_KEY="dev-key-1"
