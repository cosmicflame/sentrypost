#!/usr/bin/env bash
# ------------------------------------------------------------------
# sentrypost.sh
# Updates every running Docker‑Compose cluster on the host.
# ------------------------------------------------------------------
set -euo pipefail

# ---------- Command‑line options ----------
check_mode=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      check_mode=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--check]"
      echo "  --check    Show what would be updated, but do not pull or restart"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# ---------- Discover clusters ----------
IFS=$'\n'
readarray -t DIRS < <(
  docker compose ls --format json |
    jq -r '
      [
        .[] | .ConfigFiles | if type=="array" then .[] else . end |
        select(test(".*\\.ya?ml$")) |
        sub("/[^/]+$"; "")
      ] | .[]'
)

if [[ ${#DIRS[@]} -eq 0 ]]; then
  echo "No running Docker Compose clusters found."
  exit 0
fi

# ---------- Log discovered clusters ----------
echo "Found ${#DIRS[@]} Docker Compose clusters:"
for d in "${DIRS[@]}"; do echo "  • $d"; done

# ---------- Process each cluster ----------
for dir in "${DIRS[@]}"; do
  echo "=================================================="
  echo "Processing cluster in $dir"

  if [[ ! -d "$dir" ]]; then
    echo "⚠️  Directory $dir does not exist – skipping"
    continue
  fi

  pushd "$dir" >/dev/null || continue

  # Check for SENTRYPOST=SKIP in the compose file
  if grep -q '^SENTRYPOST=SKIP$' docker-compose.yaml; then
    echo "  Skipping this cluster because SENTRYPOST=SKIP is present in docker-compose.yaml."
    popd >/dev/null
    continue
  fi

  if $check_mode; then
    echo "  [CHECK] Would pull and update this cluster (SENTRYPOST=SKIP not found)."
    popd >/dev/null
    continue
  fi

  echo "• Pulling latest images..."

  # Get list of images from the compose config
  mapfile -t images < <(docker compose config | awk '/image:/ {print $2}')
  if [[ ${#images[@]} -eq 0 ]]; then
    echo "  No image definitions found in compose file – skipping pull."
    popd >/dev/null
    continue
  fi

  # Capture image digests before pull
  declare -A before after
  for img in "${images[@]}"; do
    before["$img"]=$(docker inspect --format '{{.Id}}' "$img" 2>/dev/null)
  done

  # Pull with timeout; progress bar goes directly to terminal
  if ! timeout 5m docker compose pull; then
    echo "  Pull did not complete before timeout – aborting."
    popd >/dev/null
    exit 1
  fi

  # Capture image digests after pull
  for img in "${images[@]}"; do
    after["$img"]=$(docker inspect --format '{{.Id}}' "$img" 2>/dev/null)
  done

  changed=false
  for img in "${images[@]}"; do
    if [[ "${before[$img]}" != "${after[$img]}" ]]; then
      changed=true
      break
    fi
  done

  if $changed; then
    echo "  New images pulled – restarting services..."
    docker compose up -d
  else
    echo "  All images already up to date."
  fi

  popd >/dev/null

done

echo "✅  All clusters processed."
