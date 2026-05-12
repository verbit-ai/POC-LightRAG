#!/usr/bin/env bash
# bootstrap.sh — get-started installer for the LightRAG PoC on macOS (arm64/x86_64).
#
# What this script does, in order:
#   1.  Verifies macOS + Homebrew, installs Homebrew if missing.
#   2.  Installs git, python@3.12, jq, podman, podman-compose.
#   3.  Detects the arm64-vs-x86_64 podman binary mismatch and fixes it.
#   4.  Initialises and starts the Podman VM.
#   5.  Clones LightRAG (pinned commit) next to this script.
#   6.  Applies patches/voyage_rerank.patch if it's present.
#   7.  Stages .env and config.ini from upstream examples, and reports whether
#       a pre-built rag_storage/ snapshot is already in place.
#   8.  Waits for you to put real API keys in LightRAG/.env (or paste a saved
#       .env from a previous run).
#   9.  Builds and starts the LightRAG container with podman-compose.
#  10.  Health-checks http://localhost:9621.
#
# Reusing artifacts from a previous run:
#   - LightRAG/.env             — paste your saved file at step 7 to skip the
#                                 API-keys prompt at step 8.
#   - LightRAG/data/rag_storage — paste a saved snapshot at step 7 to skip
#                                 ingestion. If you paste it AFTER the server
#                                 is already running, restart the container so
#                                 it re-reads from disk:
#                                   (cd LightRAG && podman-compose restart)
#
# Safe to re-run. Anything already done is skipped.

set -Eeuo pipefail

# ---------- pretty logging ----------------------------------------------------
log()  { printf "\033[1;34m▶ %s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m✓ %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m! %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

trap 'die "Aborted at line $LINENO. Re-run the script to resume from this step."' ERR

# ---------- config ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIGHTRAG_DIR="${SCRIPT_DIR}/LightRAG"
PATCH_FILE="${SCRIPT_DIR}/patches/voyage_rerank.patch"
LIGHTRAG_REPO="https://github.com/HKUDS/LightRAG.git"
LIGHTRAG_PINNED_SHA="6c85f26d21cef93936f2d97d7010227d3ba56542"
PODMAN_VM_CPUS="${PODMAN_VM_CPUS:-4}"
PODMAN_VM_MEM_MB="${PODMAN_VM_MEM_MB:-8192}"
PODMAN_VM_DISK_GB="${PODMAN_VM_DISK_GB:-60}"
LIGHTRAG_URL="http://localhost:9621"

# ---------- step 0: platform sanity -------------------------------------------
log "0/10  Checking platform"
[[ "$(uname -s)" == "Darwin" ]] || die "This bootstrap targets macOS. For Linux, install podman from your package manager and follow RUN_LIGHTRAG_PODMAN.md."
ARCH="$(uname -m)"
ok "macOS detected ($ARCH)"

# ---------- step 1: Homebrew --------------------------------------------------
log "1/10  Homebrew"
if ! command -v brew >/dev/null 2>&1; then
    log "Installing Homebrew (you may be prompted for your password)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Make sure brew is on PATH for the rest of this script and future shells.
if [[ -x /opt/homebrew/bin/brew ]]; then
    BREW_PREFIX=/opt/homebrew
elif [[ -x /usr/local/bin/brew ]]; then
    BREW_PREFIX=/usr/local
else
    die "Homebrew installed but brew binary not found in /opt/homebrew or /usr/local."
fi
eval "$("${BREW_PREFIX}/bin/brew" shellenv)"

if ! grep -q 'brew shellenv' "${HOME}/.zprofile" 2>/dev/null; then
    echo "eval \"\$(${BREW_PREFIX}/bin/brew shellenv)\"" >> "${HOME}/.zprofile"
    ok "Added brew shellenv to ~/.zprofile"
fi
ok "Homebrew ready at ${BREW_PREFIX}"

# ---------- step 2: packages --------------------------------------------------
log "2/10  Installing required Homebrew packages"
brew_install() {
    local pkg="$1"
    if brew list --formula "$pkg" >/dev/null 2>&1; then
        ok "$pkg already installed"
    else
        log "Installing ${pkg}..."
        brew install "$pkg"
    fi
}
brew_install git
brew_install python@3.12
brew_install jq
brew_install podman
brew_install podman-compose

# ---------- step 3: arm64 podman fix -----------------------------------------
log "3/10  Checking podman binary architecture"
PODMAN_BIN="$(command -v podman)"
if [[ "$ARCH" == "arm64" ]]; then
    if file "$PODMAN_BIN" | grep -q "x86_64"; then
        warn "Found x86_64 podman at $PODMAN_BIN on an arm64 Mac."
        warn "Moving it aside to expose the native arm64 binary from Homebrew."
        sudo mv "$PODMAN_BIN" "${PODMAN_BIN}.x86_64.bak"
        hash -r
        PODMAN_BIN="$(command -v podman)"
        file "$PODMAN_BIN" | grep -q "arm64" \
            || die "Native arm64 podman still not on PATH. Inspect: which -a podman"
        ok "Switched to arm64 podman at $PODMAN_BIN"
    else
        ok "podman binary is native arm64"
    fi
else
    ok "x86_64 host — no binary fix needed"
fi

# ---------- step 4: podman machine -------------------------------------------
log "4/10  Podman VM"
if ! podman machine list --format '{{.Name}}' | grep -q '.'; then
    log "Initialising podman machine (${PODMAN_VM_CPUS} CPU / ${PODMAN_VM_MEM_MB} MB / ${PODMAN_VM_DISK_GB} GB)..."
    podman machine init \
        --cpus "$PODMAN_VM_CPUS" \
        --memory "$PODMAN_VM_MEM_MB" \
        --disk-size "$PODMAN_VM_DISK_GB"
fi

if podman machine list --format '{{.Running}}' | grep -q true; then
    ok "Podman machine already running"
else
    log "Starting podman machine..."
    podman machine start
fi

log "Smoke-testing the VM with hello-world..."
podman run --rm hello-world >/dev/null
ok "Podman VM is healthy"

# ---------- step 5: clone LightRAG -------------------------------------------
log "5/10  LightRAG repo"
if [[ ! -d "${LIGHTRAG_DIR}/.git" ]]; then
    log "Cloning ${LIGHTRAG_REPO} into ${LIGHTRAG_DIR}..."
    git clone "$LIGHTRAG_REPO" "$LIGHTRAG_DIR"
fi
(
    cd "$LIGHTRAG_DIR"
    if [[ "$(git rev-parse HEAD)" != "$LIGHTRAG_PINNED_SHA" ]]; then
        log "Pinning LightRAG to ${LIGHTRAG_PINNED_SHA:0:10}..."
        git fetch --quiet origin "$LIGHTRAG_PINNED_SHA" || true
        git checkout --quiet "$LIGHTRAG_PINNED_SHA"
    fi
)
ok "LightRAG at $(git -C "$LIGHTRAG_DIR" rev-parse --short HEAD)"

# ---------- step 6: apply patch ----------------------------------------------
log "6/10  Voyage-rerank patch"
if [[ -f "$PATCH_FILE" ]]; then
    if git -C "$LIGHTRAG_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
        log "Applying ${PATCH_FILE}..."
        git -C "$LIGHTRAG_DIR" apply "$PATCH_FILE"
        ok "Patch applied"
    elif grep -q '"voyage"' "${LIGHTRAG_DIR}/lightrag/api/config.py"; then
        ok "Patch already applied (skipping)"
    else
        die "Patch does not apply cleanly and isn't already in the tree. See $PATCH_FILE."
    fi
else
    warn "No patch file at $PATCH_FILE — skipping. Voyage reranking won't be available."
    warn "If you need it, copy patches/voyage_rerank.patch from the PoC repo and re-run this script."
fi

# ---------- step 7: stage .env, config.ini, and rag_storage ------------------
log "7/10  .env, config.ini, and rag_storage"
ENV_FILE="${LIGHTRAG_DIR}/.env"
CONFIG_FILE="${LIGHTRAG_DIR}/config.ini"
RAG_STORAGE_DIR="${LIGHTRAG_DIR}/data/rag_storage"

if [[ ! -f "$ENV_FILE" ]]; then
    cp "${LIGHTRAG_DIR}/env.example" "$ENV_FILE"
    ok "Created LightRAG/.env from env.example"
    cat <<EOF

  TIP: If you have a saved LightRAG/.env from a previous run with API keys
       already filled in, paste it now at:
         ${ENV_FILE}
       (overwrite the freshly-staged file). The script will detect the keys
       and skip the API-keys prompt below.

EOF
else
    ok "LightRAG/.env already exists (left untouched)"
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
    cp "${LIGHTRAG_DIR}/config.ini.example" "$CONFIG_FILE"
    ok "Created LightRAG/config.ini from config.ini.example"
fi

mkdir -p "$RAG_STORAGE_DIR"
RAG_STORAGE_PREEXISTING=0
if compgen -G "${RAG_STORAGE_DIR}/*" > /dev/null; then
    RAG_STORAGE_PREEXISTING=1
    RAG_FILE_COUNT="$(find "$RAG_STORAGE_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')"
    ok "Existing rag_storage snapshot detected (${RAG_FILE_COUNT} files) — server will load it on startup, no re-ingestion needed"
else
    cat <<EOF

  TIP: rag_storage/ is empty. You have two options:
    A) Paste a saved snapshot now at:
         ${RAG_STORAGE_DIR}/
       The server will load it on startup and skip ingestion.
    B) Leave it empty and, after the server is up, drop PDFs into:
         ${LIGHTRAG_DIR}/data/inputs/
       The server will auto-ingest them (a few minutes per PDF).

  If you paste a snapshot AFTER the container has started, restart it so
  it re-reads from disk:
    (cd ${LIGHTRAG_DIR} && podman-compose restart)

EOF
fi

# Make sure .env is never accidentally committed if this directory becomes a git repo.
if [[ -d "${SCRIPT_DIR}/.git" ]] && ! grep -qxF 'LightRAG/.env' "${SCRIPT_DIR}/.gitignore" 2>/dev/null; then
    echo 'LightRAG/.env' >> "${SCRIPT_DIR}/.gitignore"
fi

# ---------- step 8: API keys pause -------------------------------------------
log "8/10  API keys"
KEYS_OK=0
if grep -Eq '^(LLM_BINDING_API_KEY|EMBEDDING_BINDING_API_KEY)=$' "$ENV_FILE" \
    || grep -Eq '^(LLM_BINDING_API_KEY|EMBEDDING_BINDING_API_KEY)=.*your_.*key' "$ENV_FILE"; then
    KEYS_OK=0
else
    # Heuristic: both keys present and non-empty
    if grep -Eq '^LLM_BINDING_API_KEY=.+' "$ENV_FILE" \
        && grep -Eq '^EMBEDDING_BINDING_API_KEY=.+' "$ENV_FILE"; then
        KEYS_OK=1
    fi
fi

if [[ "$KEYS_OK" -eq 0 ]]; then
    cat <<EOF

You now need real API keys in:
  ${ENV_FILE}

If you have a saved .env from a previous run, paste it at the path above
(overwriting the staged file) and press Enter to continue — no editing needed.

Otherwise edit the file in place. Minimum required values
(see RUN_LIGHTRAG_PODMAN.md step 8 for the full block):
  LLM_BINDING=gemini
  LLM_BINDING_API_KEY=<your Gemini AI Studio key>
  LLM_MODEL=gemini-flash-latest

  EMBEDDING_BINDING=openai
  EMBEDDING_BINDING_HOST=https://api.voyageai.com/v1
  EMBEDDING_BINDING_API_KEY=<your Voyage key>
  VOYAGE_API_KEY=<your Voyage key>
  EMBEDDING_MODEL=voyage-law-2
  EMBEDDING_DIM=1024

  RERANK_BINDING=voyage
  RERANK_MODEL=rerank-2.5
  RERANK_BINDING_HOST=https://api.voyageai.com/v1/rerank
  RERANK_BINDING_API_KEY=<your Voyage key>

Get keys here:
  Gemini : https://aistudio.google.com/app/apikey
  Voyage : https://dash.voyageai.com/api-keys

EOF
    read -r -p "Press Enter once you've saved the .env file... " _
fi
ok "Proceeding with current .env"

# ---------- step 9: start the stack ------------------------------------------
log "9/10  Building and starting the LightRAG container"
(
    cd "$LIGHTRAG_DIR"
    podman-compose up -d --build
)

# ---------- step 10: health check --------------------------------------------
log "10/10 Waiting for LightRAG to come up at ${LIGHTRAG_URL}"
ATTEMPTS=60
for i in $(seq 1 $ATTEMPTS); do
    if curl -fsS "${LIGHTRAG_URL}/health" >/dev/null 2>&1; then
        ok "LightRAG is healthy after ${i}s"
        break
    fi
    sleep 1
    if [[ "$i" -eq "$ATTEMPTS" ]]; then
        warn "Service didn't respond on /health within ${ATTEMPTS}s."
        warn "Tail the logs with:  podman logs -f lightrag_lightrag_1"
        exit 1
    fi
done

if [[ "$RAG_STORAGE_PREEXISTING" -eq 1 ]]; then
    NEXT_STEP_BLOCK="  Next step   : a rag_storage snapshot was already in place, so the
                server is loaded with the existing index. Run the eval:
                  python3.12 -m venv .venv && source .venv/bin/activate
                  pip install -r requirements-eval.txt
                  python run_eval.py"
else
    NEXT_STEP_BLOCK="  Next step   : either drop PDFs into LightRAG/data/inputs/ to ingest
                (or upload via the WebUI), OR paste a saved rag_storage
                snapshot into LightRAG/data/rag_storage/ and restart the
                container:
                  (cd LightRAG && podman-compose restart)"
fi

cat <<EOF

────────────────────────────────────────────────────────────
  All done.

  WebUI       : ${LIGHTRAG_URL}/webui
  API docs    : ${LIGHTRAG_URL}/docs
  Health      : ${LIGHTRAG_URL}/health

  Tail logs   : podman logs -f lightrag_lightrag_1
  Stop stack  : (cd LightRAG && podman-compose down)
  Stop VM     : podman machine stop

${NEXT_STEP_BLOCK}
────────────────────────────────────────────────────────────
EOF
