# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

**Isabellm** is an LLM-guided Isabelle/HOL theorem prover. It integrates LLM backends (Ollama, Gemini, Hugging Face) with Isabelle's proof engine to prove theorems using beam-search tactic generation, optional reranking, premise selection, and automated reasoning fallbacks (Sledgehammer, Quickcheck, Nitpick).

Two proving strategies:
- **Stepwise Prover** (`prover/`): Beam-search over LLM-generated tactics, applied incrementally.
- **Isar Planner** (`planner/`): LLM sketches a proof outline with `sorry` holes; stepwise prover fills each hole; CEGIS repair on failure.

A FastAPI server (`isabelle_ui/`) exposes both to jEdit via BeanShell macros.

## Setup

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -U pip && pip install -r requirements.txt
```

Requires Isabelle2025 on `PATH`. Python 3.10–3.12 only (3.13 breaks some PyTorch packages).

LLM backends — use prefix to select:
- `qwen3-coder:30b` → Ollama (default, must run `ollama serve`)
- `gemini:gemini-3-flash-preview` → Gemini CLI (`gemini setup` first)
- `hf:meta-llama/Llama-3.1-8B-Instruct` → Hugging Face (`HF_API_TOKEN` env var)

## Common Commands

### Run the stepwise prover
```bash
python -m prover.cli --goal "rev (rev xs) = xs"
python -m prover.cli --goal 'map f (xs @ ys) = map f xs @ map f ys' \
  --beam 5 --max-depth 10 --timeout 200 --sledge --quickcheck
```

### Run the planner
```bash
python -m planner.cli --timeout 120 --mode auto "rev (rev xs) = xs"
python -m planner.cli --timeout 120 --diverse-outlines --k 3 --mode auto \
  "map f (xs @ ys) = map f xs @ map f ys"
```

### Benchmark a dataset suite
```bash
python -m prover.experiments bench --suite lists --beam 3 --timeout 60
python -m planner.experiments bench --file datasets/lists.txt --mode auto --timeout 120
```

### Regression test against a saved baseline
```bash
python -m prover.experiments regress --suite lists --baseline datasets/baselines/lists.json
```

### Train reranker (ML)
```bash
python -m prover.train_reranker --algo xgb-classifier --target bandit
python -m prover.train_reranker --algo awr --epochs 8 --batch 1024
```

### Train premise selection models
```bash
python -m prover.train_premises --logs-glob 'logs/magnus_shards/shard_*' --out models \
  --train-bi --epochs 2 --batch-size 256
```

### Run the jEdit UI server
```bash
python -m isabelle_ui.server  # http://localhost:8000
```

## Architecture

### Stepwise Prover (`prover/`)

`prover/cli.py` → `prover/prover.py` (core loop):
1. Start Isabelle server and create session (`isabelle_api.py`)
2. Beam search (width=3, depth=8 by default):
   - Extract current subgoals and mine relevant lemmas/facts (`tactics.py`)
   - Optionally retrieve premises via two-stage selection: TF-IDF SELECT → cross-encoder RE-RANK (`premises.py`)
   - LLM generates candidate tactics (`llm.py`)
   - Reranker scores candidates (`ranker.py`)
   - Apply tactics to Isabelle, backtrack on failure
   - Fallbacks: Sledgehammer, Quickcheck, Nitpick
3. Optionally minimize proof (iterative fact subset search via `minimize.py`)
4. Log to `logs/attempts.log.jsonl` and `logs/runs.log.jsonl`

### Isar Planner (`planner/`)

`planner/cli.py` → `planner/driver.py` (`plan_and_fill`):
1. LLM generates Isar outline with `sorry` holes (`skeleton.py`, `prompts.py`)
2. Quick Isabelle sketch validation; pick best outline
3. For each hole: extract effective subgoal, call stepwise prover
4. CEGIS repair on failure: LLM rewrites around the failure, retry (`repair.py`)
5. Log to `logs/planner.log.jsonl`

### Configuration (`prover/config.py`)

All config is read from environment variables at module import. Key vars:
- `MODEL` — LLM model string with backend prefix
- `OLLAMA_HOST`, `OLLAMA_TEMP`, `OLLAMA_TIMEOUT_S`
- `BEAM_WIDTH`, `MAX_DEPTH`, `NUM_CANDIDATES`
- `RERANKER_DIR`, `RERANKER_OFF`
- `PREMISES_ENABLE`, `PREMISES_K_SELECT`, `PREMISES_K_RERANK`
- `PROVER_CONTEXT_ENABLE`, `PROVER_CONTEXT_FILES`
- `ISABELLE_SESSION` (default: `HOL`), `EXTRA_IMPORTS`
- `LOG_DIR`, `ATTEMPTS_LOG`, `RUNS_LOG`

Call `prover.config.refresh_from_env()` to reload at runtime.

### LLM Dispatch (`prover/llm.py`)

Single `propose_steps()` API dispatches based on model prefix. All backends return a list of tactic strings. Set `LLM_DEBUG=1` for verbose backend routing and errors.

### Logging / Training Data

JSONL logs in `logs/` feed back into reranker and premise model training:
- `attempts.log.jsonl` — per-tactic (state, tactic, outcome) records
- `runs.log.jsonl` — per-run success/failure + snapshot metadata
- `planner.log.jsonl` — planner outline-to-proof traces

Use `logs/split_json.py` to shard large logs for parallel training.

## Datasets

- **Quick sanity checks**: `datasets/lists.txt`, `nat.txt`, `sets.txt`, `logic.txt`
- **Synthetic training/test**: `datasets/hol_main_{easy,mid,hard}_goals.txt` / `*_test.txt`
- **Mini-F2F**: `datasets/mini_f2f/` (244 valid + 244 test)
- **PutnamBench**: `datasets/putnambench/`
- Benchmark results go to `datasets/results/` and `datasets/planner_results/`
