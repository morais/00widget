#!/usr/bin/env bash
set -euo pipefail

failed=0

require_literal() {
  local file="$1"
  local literal="$2"

  if ! grep -Fq -- "$literal" "$file"; then
    echo "::error file=$file::Missing required public placeholder: $literal"
    failed=1
  fi
}

require_ignored() {
  local file="$1"

  if ! git check-ignore -q -- "$file"; then
    echo "::error file=.gitignore::$file must remain ignored"
    failed=1
  fi

  if git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
    echo "::error file=$file::$file contains per-developer values and must not be tracked"
    failed=1
  fi
}

require_literal server/wrangler.toml.sample 'database_id = "REPLACE_WITH_D1_DATABASE_ID"'
require_literal ios/project.yml.sample 'com.example.zerozerowidget'
require_literal ios/project.yml.sample 'group.com.example.zerozerowidget'
require_literal server/.dev.vars.example 'API_KEYS=""'
require_literal examples/env.example.sh 'API_KEY="dev-key-1"'

require_ignored server/wrangler.toml
require_ignored ios/project.yml
require_ignored server/.dev.vars
require_ignored examples/env.sh

exit "$failed"
