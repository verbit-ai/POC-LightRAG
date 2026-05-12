# LightRAG Legal-RAG PoC

A reproducible proof-of-concept that runs **LightRAG** as a local RAG service
(via Podman), ingests a small legal corpus (ACC vs Fire depositions), and
benchmarks it with **RAGAS** using Voyage embeddings + Voyage reranking +
Gemini as the LLM/judge.

## Quickstart on a new machine

```bash
chmod +x bootstrap.sh
./bootstrap.sh                                          # installs everything, prompts for API keys
```

When `bootstrap.sh` reaches **step 8** it will pause and ask you to (1) put real
API keys in `LightRAG/.env` and (2) optionally seed `LightRAG/data/rag_storage/`
with a prebuilt index. Pick one of the two ingestion paths below before
pressing Enter.

**Path A — reuse the prebuilt snapshot shipped in this repo (fast, no
ingestion).** The `rag_storage/` directory at the repo root is a ~81 MB
prebuilt index of the ACC vs Fire corpus. Copy it into place during the step-8
pause:

```bash
cp -R rag_storage/. LightRAG/data/rag_storage/
```

**Path B — ingest from scratch.** Skip the copy, press Enter, then after the
container is up:

```bash
cp inputs/ACCvsFire/*.pdf LightRAG/data/inputs/         # auto-ingested by the server
curl -s http://localhost:9621/documents/pipeline_status | jq .   # wait until all "processed"
```

Then in either path, run the evaluation:

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements-eval.txt
python run_eval.py                                      # writes inputs/ragas_results/ragas_<ts>.{json,csv}
```

Expected metrics on the 23-case test set (Voyage rerank on, Gemini judge):
Faithfulness ≈ `0.83`, Answer Relevancy ≈ `0.88`, Context Recall ≈ `0.93`,
Context Precision ≈ `0.56`, RAGAS avg ≈ `0.80`.

---

## What's in this repo

### Required to run the PoC

| File / dir | Why we need it |
| --- | --- |
| `bootstrap.sh` | One-shot installer. Sets up Homebrew, Podman + VM, clones LightRAG at a pinned commit, applies our patch, stages `.env`/`config.ini`, builds and starts the container, health-checks `localhost:9621`. Idempotent — safe to re-run. |
| `patches/voyage_rerank.patch` | A 133-line `git diff` that teaches upstream LightRAG to talk to Voyage's reranker (Voyage's API uses `top_k`/`data` instead of Cohere's `top_n`/`results`). Without it, only Cohere/Jina/Aliyun rerank are available. Applied automatically by `bootstrap.sh` step 6. |
| `run_eval.py` | Standalone RAGAS harness. Queries the running LightRAG server over HTTP, applies a second Voyage rerank pass client-side, attaches `chunk_id` / `full_doc_id` metadata from `vdb_chunks.json`, then scores each Q&A with Faithfulness / Answer Relevancy / Context Recall / Context Precision. Writes timestamped JSON + CSV per run. |
| `requirements-eval.txt` | Pinned Python deps for `run_eval.py` (`ragas`, `langchain*`, `openai`, `python-dotenv`, `tiktoken`). Kept separate from LightRAG's own deps because the eval runs in its own venv at the project root. |
| `inputs/ACCvsFire/*.pdf` | The source corpus — 5 deposition PDFs (~5.8 MB). Copied into `LightRAG/data/inputs/` after bootstrap, where the server auto-ingests them into the vector DB + knowledge graph. Replace with your own docs to evaluate on a different corpus. |
| `inputs/gt_depo_oriented_multi_formatted_merged.ragas.json` | The 23-case ground-truth test set. `run_eval.py` reads this directly. Schema: `{"test_cases": [{"question": "...", "ground_truth": "...", "project": "..."}, …]}`. Replace with your own questions to evaluate a different task. |
| `rag_storage/` | Optional prebuilt LightRAG index of the ACC vs Fire corpus (~81 MB across 12 files: `vdb_*.json`, `graph_chunk_entity_relation.graphml`, `kv_store_*.json`). Copy into `LightRAG/data/rag_storage/` during the step-8 pause to skip ingestion entirely. Generated against `voyage-law-2` (dim 1024) — only valid for that exact embedding model. |
| `.gitignore` | Keeps `LightRAG/`, `.env`, `.venv/`, `__pycache__/`, `.DS_Store`, and IDE configs out of the repo. |

### Reference docs

| File | Why |
| --- | --- |
| `README.md` | This file — the one-page summary. |

> The earlier drafts of this PoC also shipped `RUN_LIGHTRAG_PODMAN.md` (14-step
> Podman walkthrough), `SETUP.md` (end-to-end setup guide), and `PLAN.md`
> (decisions / history). They live in the original `rag-poc/` workspace and
> have **not been migrated to this repository yet**. If you need them, ask
> the repo owner.

### Auto-generated (don't commit, don't bring to a new machine)

| Path | Created by |
| --- | --- |
| `LightRAG/` | `bootstrap.sh` clones HKUDS/LightRAG here and applies the patch. ~80 MB after first ingest. |
| `LightRAG/.env`, `LightRAG/config.ini` | `bootstrap.sh` copies from `env.example` / `config.ini.example`. **Holds API keys — never commit.** |
| `LightRAG/data/rag_storage/` | Where the server actually reads/writes its index. Either populated by ingestion, or seeded from the top-level `rag_storage/` snapshot — see Quickstart Path A. Don't confuse with the committed `rag_storage/` at the repo root. |
| `inputs/ragas_results/` | `run_eval.py` writes `ragas_<timestamp>.{json,csv}` here on every run. |
| `.venv/` | Your local Python venv for the eval. |

---

## API keys you need before running

Both are free-tier-friendly for a PoC:

- **Google AI Studio (Gemini)** — https://aistudio.google.com/app/apikey
  Used by LightRAG for generation and by RAGAS as the judge LLM.
- **Voyage AI** — https://dash.voyageai.com/api-keys
  Same key powers both embeddings (`voyage-law-2`) and the reranker (`rerank-2.5`).

`bootstrap.sh` pauses on step 8 with exact instructions on which variables
to set in `LightRAG/.env`. Do not commit `.env`.

---

## Project layout (after first successful run)

```
.
├── README.md                            ← you are here
├── .gitignore                           ← keeps LightRAG/, .env, .venv out of git
├── bootstrap.sh                         ← one-shot installer
├── patches/
│   └── voyage_rerank.patch              ← adds Voyage rerank to LightRAG
├── run_eval.py                          ← RAGAS harness
├── requirements-eval.txt                ← eval Python deps
├── rag_storage/                         ← committed prebuilt LightRAG index
│   ├── vdb_*.json                          (~81 MB total; copy into
│   ├── graph_chunk_entity_relation.graphml  LightRAG/data/rag_storage/
│   └── kv_store_*.json                      during the step-8 pause)
├── inputs/
│   ├── ACCvsFire/*.pdf                  ← source corpus (~7.8 MB, 5 PDFs)
│   ├── gt_depo_oriented_multi_formatted_merged.ragas.json   ← test set
│   └── ragas_results/                   ← (generated) eval outputs
├── LightRAG/                            ← (generated) cloned + patched upstream
│   ├── .env                             ← (generated) holds API keys, gitignored
│   ├── config.ini                       ← (generated) staged from upstream example
│   └── data/
│       ├── inputs/                      ← drop docs here to ingest (Path B)
│       └── rag_storage/                 ← (generated) vector DB + graph the
│                                          server actually reads from; either
│                                          ingested fresh, or seeded from the
│                                          top-level rag_storage/ snapshot
└── .venv/                               ← (generated) eval venv
```

---

## Day-2 commands

```bash
# stop everything
(cd LightRAG && podman-compose down)
podman machine stop

# start everything again later
podman machine start
(cd LightRAG && podman-compose up -d)

# tail server logs
podman logs -f lightrag_lightrag_1

# wipe the index and re-ingest from scratch
(cd LightRAG && podman-compose down)
rm -rf LightRAG/data/rag_storage/*
(cd LightRAG && podman-compose up -d)
cp inputs/ACCvsFire/*.pdf LightRAG/data/inputs/
```

---

## Notes

- **Embedding model is locked once you ingest.** Don't change `EMBEDDING_MODEL`
  or `EMBEDDING_DIM` in `.env` after the first document is processed —
  doing so will corrupt the vector store. Wipe `LightRAG/data/rag_storage/`
  and re-ingest if you need to switch. The shipped `rag_storage/` snapshot
  was built with `voyage-law-2` (dim 1024); pair it with matching `.env`
  values or it won't read.
- **Restart after seeding `rag_storage/`.** If you copy the snapshot into
  `LightRAG/data/rag_storage/` *after* the container is already up, the
  server is still holding its empty boot-time state in memory. Restart it:
  `(cd LightRAG && podman-compose restart)`.
- **Pinned LightRAG SHA.** `bootstrap.sh` checks out commit `6c85f26d2`
  because that's what `patches/voyage_rerank.patch` was generated against.
  If you bump the SHA, regenerate the patch (`git -C LightRAG diff HEAD >
  patches/voyage_rerank.patch`).
- **Security.** The default config exposes `localhost:9621` without auth.
  Set `LIGHTRAG_API_KEY` in `.env` and put the service behind TLS / a
  reverse proxy before exposing it beyond the loopback interface. Rotate
  the Voyage and Gemini keys after the PoC.
