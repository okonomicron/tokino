#!/usr/bin/env bash
# Fails if anything credential-shaped is committed.
#
# The repository is public, so a leaked key is exploitable the moment it lands,
# and rewriting history does not un-leak it. This is a blunt pattern scan: it is
# meant to catch accidents, not a determined attempt to hide something.
set -uo pipefail

# Files that legitimately contain these words (documentation, this script, the
# example env file) are excluded by path.
EXCLUDES=(
  ':(exclude)scripts/scan-secrets.sh'
  ':(exclude)docs/*'
  ':(exclude)backend/.env.example'
  ':(exclude).github/workflows/*'
)

# pattern:description
PATTERNS=(
  'sk-ant-[A-Za-z0-9_-]{20,}:Anthropic API key'
  'sk-[A-Za-z0-9]{32,}:OpenAI-style API key'
  'AIza[A-Za-z0-9_-]{30,}:Google API key'
  'ghp_[A-Za-z0-9]{30,}:GitHub personal access token'
  'service_role.*eyJ[A-Za-z0-9_-]{20,}:Supabase service-role JWT'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----:private key'
  'AKIA[0-9A-Z]{16}:AWS access key id'
)

status=0
for entry in "${PATTERNS[@]}"; do
  pattern="${entry%%:*}"
  description="${entry#*:}"
  if matches=$(git grep -nIE "$pattern" -- . "${EXCLUDES[@]}" 2>/dev/null); then
    if [ -n "$matches" ]; then
      echo "Possible $description committed:" >&2
      echo "$matches" >&2
      status=1
    fi
  fi
done

# Signing material and env files must never be tracked at all.
if tracked=$(git ls-files -- '*.p8' '*.p12' '*.mobileprovision' '*.cer' '.env' '**/.env' 2>/dev/null); then
  if [ -n "$tracked" ]; then
    echo "Credential or signing files are tracked by git:" >&2
    echo "$tracked" >&2
    status=1
  fi
fi

if [ "$status" -eq 0 ]; then
  echo "Secret scan clean."
fi
exit "$status"
