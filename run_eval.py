#!/usr/bin/env python3
"""
Standalone RAGAS evaluation for ACC vs Fire PoC.
Runs fully synchronously — avoids asyncio deadlock with Gemini endpoint.
"""
import csv, json, os, time, urllib.request
from datetime import datetime
from pathlib import Path
from typing import List

import warnings
warnings.filterwarnings("ignore", category=DeprecationWarning)

from dotenv import dotenv_values

# ── Config ────────────────────────────────────────────────────────────────────
BASE_DIR  = Path(__file__).parent
DATASET   = BASE_DIR / "inputs" / "gt_depo_oriented_multi_formatted_merged.ragas.json"
RESULTS   = BASE_DIR / "inputs" / "ragas_results"
VDB_CHUNKS = BASE_DIR / "LightRAG" / "data" / "rag_storage" / "vdb_chunks.json"
RESULTS.mkdir(exist_ok=True)

RAG_URL   = "http://localhost:9621"
TOP_K     = 10         # retrieve broad candidate set before reranking
ENABLE_RERANK = os.getenv("ENABLE_RERANK", "true").lower() not in {"0", "false", "no"}
SERVER_RERANK = os.getenv("SERVER_RERANK", "true").lower() not in {"0", "false", "no"}
RERANK_MODEL = "rerank-2.5"
RERANK_TOP_N = 5       # keep enough evidence while still filtering noisy chunks
MAX_CASES = None       # None = all 23; set to integer for a partial run

cfg       = dotenv_values(BASE_DIR / "LightRAG" / ".env")
LLM_KEY   = str(cfg.get("LLM_BINDING_API_KEY", ""))
EMB_KEY   = str(cfg.get("EMBEDDING_BINDING_API_KEY", ""))
EMB_HOST  = str(cfg.get("EMBEDDING_BINDING_HOST", "https://api.voyageai.com/v1"))
EMB_MODEL = str(cfg.get("EMBEDDING_MODEL", "voyage-law-2"))
LLM_HOST  = "https://generativelanguage.googleapis.com/v1beta/openai"
LLM_MODEL = "gemini-2.5-flash"    # faster than Pro; ContextPrecision stays under timeout

# ── RAGAS imports ─────────────────────────────────────────────────────────────
from datasets import Dataset
from ragas import evaluate
from ragas.metrics import Faithfulness, AnswerRelevancy, ContextRecall, ContextPrecision
from ragas.llms import LangchainLLMWrapper
from langchain_core.embeddings import Embeddings
from langchain_openai import ChatOpenAI
from openai import OpenAI as _OpenAI


# ── Custom Voyage embedding wrapper ───────────────────────────────────────────
class VoyageEmbeddings(Embeddings):
    """
    Uses the openai Python client to call Voyage AI's embeddings endpoint with
    raw text strings. Avoids langchain_openai's tiktoken/transformers path which
    fails for voyage-law-2 (no HuggingFace tokenizer config for that model name).
    """
    def __init__(self, api_key: str, model: str, base_url: str):
        self._client = _OpenAI(api_key=api_key, base_url=base_url)
        self._model  = model

    def _batch(self, texts: List[str]) -> List[List[float]]:
        resp = self._client.embeddings.create(input=texts, model=self._model)
        return [item.embedding for item in resp.data]

    def embed_documents(self, texts: List[str]) -> List[List[float]]:
        out = []
        for i in range(0, len(texts), 64):   # Voyage max 128 inputs/call
            out.extend(self._batch(texts[i : i + 64]))
        return out

    def embed_query(self, text: str) -> List[float]:
        return self._batch([text])[0]


# ── Build eval LLM + embeddings ───────────────────────────────────────────────
base_llm  = ChatOpenAI(
    model=LLM_MODEL, api_key=LLM_KEY, base_url=LLM_HOST,
    request_timeout=240, max_retries=3,
)
ragas_llm = LangchainLLMWrapper(langchain_llm=base_llm, bypass_n=True)
ragas_emb = VoyageEmbeddings(api_key=EMB_KEY, model=EMB_MODEL, base_url=EMB_HOST)
METRICS   = [Faithfulness(), AnswerRelevancy(), ContextRecall(), ContextPrecision()]

_CHUNK_INDEX = None


def _normalize_chunk_text(text: str) -> str:
    return " ".join((text or "").split())


def load_chunk_index() -> dict:
    """Map normalized chunk text to stored LightRAG chunk metadata."""
    global _CHUNK_INDEX
    if _CHUNK_INDEX is not None:
        return _CHUNK_INDEX

    index = {}
    if VDB_CHUNKS.exists():
        data = json.loads(VDB_CHUNKS.read_text(encoding="utf-8"))
        for item in data.get("data", []):
            content = item.get("content", "")
            key = _normalize_chunk_text(content)
            if key and key not in index:
                index[key] = {
                    "chunk_id": item.get("__id__"),
                    "full_doc_id": item.get("full_doc_id"),
                    "file_path": item.get("file_path"),
                }
    _CHUNK_INDEX = index
    return _CHUNK_INDEX


def voyage_rerank(question: str, chunk_refs: List[dict]) -> List[dict]:
    """Rerank retrieved chunks with Voyage and keep the highest-scoring chunks."""
    if not ENABLE_RERANK or not chunk_refs:
        return chunk_refs

    documents = [ref["content"] for ref in chunk_refs]
    payload = json.dumps({
        "model": RERANK_MODEL,
        "query": question,
        "documents": documents,
        "top_k": min(RERANK_TOP_N, len(documents)),
    }).encode()
    req = urllib.request.Request(
        f"{EMB_HOST.rstrip('/')}/rerank",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {EMB_KEY}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.loads(r.read().decode("utf-8"))

    reranked = []
    for rank, item in enumerate(data.get("data", []), 1):
        ref = dict(chunk_refs[item["index"]])
        ref["rerank_model"] = RERANK_MODEL
        ref["rerank_rank"] = rank
        ref["rerank_score"] = item.get("relevance_score")
        reranked.append(ref)
    return reranked


# ── Helpers ───────────────────────────────────────────────────────────────────
def query_rag(question: str) -> dict:
    """Call LightRAG /query and return {answer, contexts}."""
    payload = json.dumps({
        "query": question, "mode": "mix",
        "include_references": True, "include_chunk_content": True,
        "response_type": "Multiple Paragraphs", "top_k": TOP_K,
        "enable_rerank": SERVER_RERANK,
    }).encode()
    req = urllib.request.Request(
        f"{RAG_URL}/query", data=payload,
        headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        data = json.loads(r.read().decode("utf-8"))

    answer   = data.get("response", "")
    contexts = []
    chunk_refs = []
    chunk_index = load_chunk_index()
    for ref in data.get("references", []):
        c = ref.get("content", [])
        chunks = []
        if isinstance(c, list):
            chunks = c
        elif isinstance(c, str):
            chunks = [c]

        for idx, chunk_text in enumerate(chunks, 1):
            contexts.append(chunk_text)
            stored = chunk_index.get(_normalize_chunk_text(chunk_text), {})
            chunk_refs.append({
                "reference_id": ref.get("reference_id"),
                "source_file_path": ref.get("file_path"),
                "chunk_index_within_reference": idx,
                "chunk_id": stored.get("chunk_id"),
                "full_doc_id": stored.get("full_doc_id"),
                "stored_file_path": stored.get("file_path"),
                "content": chunk_text,
            })

    if chunk_refs:
        chunk_refs = voyage_rerank(question, chunk_refs)
        contexts = [ref["content"] for ref in chunk_refs]

    if not contexts:
        contexts = ["No context retrieved"]
        chunk_refs = []
    return {"answer": answer, "contexts": contexts, "chunk_refs": chunk_refs}


def eval_case(question: str, ground_truth: str) -> dict:
    rag = query_rag(question)
    ds  = Dataset.from_dict({
        "question":    [question],
        "answer":      [rag["answer"]],
        "contexts":    [rag["contexts"]],
        "ground_truth":[ground_truth],
    })
    out  = evaluate(dataset=ds, metrics=METRICS, llm=ragas_llm, embeddings=ragas_emb)
    row  = out.to_pandas().iloc[0]

    def g(col):
        v = row.get(col, float("nan"))
        return float(v) if v == v else float("nan")   # keep NaN as nan

    faith, ar, cr, cp = g("faithfulness"), g("answer_relevancy"), g("context_recall"), g("context_precision")
    valid  = [v for v in [faith, ar, cr, cp] if v == v]
    ragas  = sum(valid) / len(valid) if valid else float("nan")
    return {
        "faithfulness":      round(faith, 4),
        "answer_relevancy":  round(ar,    4),
        "context_recall":    round(cr,    4),
        "context_precision": round(cp,    4),
        "ragas_score":       round(ragas, 4),
        "answer_snippet":    rag["answer"][:300],
        "retrieved_chunks":   rag["chunk_refs"],
    }


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    data  = json.loads(DATASET.read_text(encoding="utf-8"))
    cases = data["test_cases"]
    if MAX_CASES:
        cases = cases[:MAX_CASES]

    total = len(cases)
    print(
        f"Running RAGAS on {total} cases  LLM={LLM_MODEL}  EMB={EMB_MODEL}  "
        f"SERVER_RERANK={SERVER_RERANK}  "
        f"EVAL_RERANK={ENABLE_RERANK}({RERANK_MODEL}, top_n={RERANK_TOP_N})\n"
    )

    results = []
    for i, tc in enumerate(cases, 1):
        q, gt = tc["question"], tc["ground_truth"]
        print(f"[{i:02d}/{total}] {q[:88]}...")
        t0 = time.time()
        try:
            s       = eval_case(q, gt)
            elapsed = round(time.time() - t0, 1)
            retrieved_chunks = s.pop("retrieved_chunks", [])
            row     = {
                "id": i,
                "question": q,
                "ground_truth": gt,
                **s,
                "retrieved_chunks": retrieved_chunks,
                "retrieved_chunks_json": json.dumps(retrieved_chunks, ensure_ascii=False),
                "elapsed_s": elapsed,
            }
            print(f"        faith={s['faithfulness']}  ar={s['answer_relevancy']}"
                  f"  cr={s['context_recall']}  cp={s['context_precision']}"
                  f"  ragas={s['ragas_score']}  ({elapsed}s)\n")
        except Exception as e:
            elapsed = round(time.time() - t0, 1)
            row     = {"id": i, "question": q, "ground_truth": gt, "error": str(e), "elapsed_s": elapsed}
            print(f"        ERROR: {e}\n")
        results.append(row)

    # ── Save ──────────────────────────────────────────────────────────────────
    stamp     = datetime.now().strftime("%Y%m%d_%H%M%S")
    json_path = RESULTS / f"ragas_{stamp}.json"
    csv_path  = RESULTS / f"ragas_{stamp}.csv"

    json_path.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")

    fields = ["id","question","ground_truth","faithfulness","answer_relevancy",
              "context_recall","context_precision","ragas_score","elapsed_s","error",
              "answer_snippet","retrieved_chunks_json"]
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader(); w.writerows(results)

    # ── Summary ───────────────────────────────────────────────────────────────
    ok  = [r for r in results if "error" not in r]
    def avg(k):
        vals = [r[k] for r in ok if isinstance(r.get(k), float) and r[k] == r[k]]
        return round(sum(vals) / len(vals), 4) if vals else "n/a"

    print("=" * 60)
    print(f"SUMMARY  ({len(ok)}/{total} succeeded)")
    print(f"  Faithfulness:      {avg('faithfulness')}")
    print(f"  Answer Relevancy:  {avg('answer_relevancy')}")
    print(f"  Context Recall:    {avg('context_recall')}")
    print(f"  Context Precision: {avg('context_precision')}")
    print(f"  RAGAS Score (avg): {avg('ragas_score')}")
    print(f"\nResults saved to:\n  {json_path}\n  {csv_path}")


if __name__ == "__main__":
    main()
