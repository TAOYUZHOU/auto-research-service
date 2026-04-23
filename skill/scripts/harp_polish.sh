#!/usr/bin/env bash
# harp_polish.sh — translate + summarise log.md / memory.md / plan.md
# into Chinese Markdown via a fresh cursor-agent chat.
#
# Output goes to <WORK_DIR>/.state/zh/{log,memory,plan}.zh.md so the
# original files are untouched and the engine's scan_state ignores them.
#
# Each call uses NO --resume → brand-new context window per polish,
# isolated from the main HARP iteration chat.  Token cost is recorded
# alongside iteration cost in .state/usage.jsonl with mode=polish_zh.
#
# Usage:
#   bash harp_polish.sh --once               # all 3 files, only if changed
#   bash harp_polish.sh --once --file log    # only log.md
#   bash harp_polish.sh --once --force       # ignore mtime cache, re-polish
#   bash harp_polish.sh --once --dry-run     # show prompt, don't call agent
#   bash harp_polish.sh --once --digest      # also build REPORT.zh.md (multi-file digest)
#
# Output styling: every polished file is structured Markdown with explicit
# section headers, tables (timeline / comparison) and — when an experiment
# touches architecture — a Mermaid flowchart describing the change.  The
# digest mode produces one cross-file research report patterned after
# REPORT_2026-04-23_data_refresh.md.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
ENGINE_DIR="$(dirname "$SKILL_DIR")"

export PATH="$HOME/.local/bin:$PATH"

mode_once=0
which_file=""        # empty => default below depending on --digest
force=0
dry_run=0
digest=0
while [ $# -gt 0 ]; do
  case "$1" in
    --once)    mode_once=1; shift ;;
    --file)    which_file="$2"; shift 2 ;;
    --force)   force=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --digest)  digest=1; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ "$mode_once" -eq 1 ] || { echo "ERROR: pass --once (the daemon is harp_polish_daemon.sh)" >&2; exit 2; }

# Default which_file: with --digest alone, only build the digest;
# otherwise polish all three per-file Markdown outputs.
if [ -z "$which_file" ]; then
  if [ "$digest" -eq 1 ]; then
    which_file="none"
  else
    which_file="all"
  fi
fi

# Resolve workspace via meta_info
WORK_DIR=$(python3 - "$ENGINE_DIR/meta_info/project.yaml" <<'PY'
import sys, yaml, pathlib
print(yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())["harness"]["workspace"]["dir"])
PY
)
[ -d "$WORK_DIR" ] || { echo "ERROR: workspace not found: $WORK_DIR" >&2; exit 1; }

ZH_DIR="$WORK_DIR/.state/zh"
mkdir -p "$ZH_DIR"

# ── Build a per-file polish prompt ────────────────────────────────
build_prompt() {
  local file_kind="$1" content="$2"
  case "$file_kind" in
    log)
      cat <<EOF
你是 HARP 项目的中文润色助手。下面是 HARP 引擎的 log.md 原文，
每行格式: TS=...;PLAN=...;ANCHOR=...;AXIS=...;TEST_MAE=...;BEST_VAL_MAE=...;STATUS=...;GIT=...;HP=...

请把它翻译并润色成结构化的中文 Markdown，严格按下列骨架：

# HARP 实验日志（中文）

## 一、概览
一段 3-5 行的话总结：本段日志覆盖时间区间、共多少次 tick、其中
新结果/IN-FLIGHT/弃训/STOP 各多少次，以及当前 best_val_mae。

## 二、时间线（最新在上）
一个 Markdown 表格，列：\`时间 (UTC)\` | \`PLAN_ID\` | \`ANCHOR\` | \`AXIS\` | \`关键指标\` | \`STATUS\` | \`一句话点评\`。
每一行原文产出一行表格，按时间倒序。指标列用 \`best_val_mae=0.07\` 这种保留原文 key 的写法，不要翻译。

## 三、要点摘录
3-6 条 bullet，挑出本批日志最值得注意的事件：
- 阈值是否达成？
- 是否有 PROGRAM SYNC / DATASET DRIFT / OVER BUDGET？
- in-flight 训练是否进入 plateau？
- 任何弃训（discard）原因？

约束：
1. 保留 ANCHOR / PLAN / BEST_VAL_MAE / STATUS / GIT 字段原文（它们是 grep key，不要翻译）。
2. 不要凭空增加原文没有的信息；找不到的字段写"未知"。
3. 直接输出中文 Markdown，不要任何前置或后置说明。

=== log.md 原文 ===
$content
=== 结束 ===
EOF
      ;;
    memory)
      cat <<EOF
你是 HARP 中文润色助手。下面是 memory.md 原文，每个 ## EXP_ID 是一个已收尾实验的回顾块。

请翻译润色成结构化的中文 Markdown，严格按下列骨架：

# HARP 实验记忆（中文）

## 一、当前 best 锚点速览
一个 Markdown 表格：\`字段\` | \`值\`，列出最近一个 \`VERDICT: keep\` 的
\`EXP_ID / ANCHOR / PARENT_PLAN / METRIC\` 四行。

## 二、所有实验回顾
对每一个 ## EXP_ID 块产出一个 \`### EXP_ID: <原文>\` 子节，子节内：
- \`- 摘要\`：一句话说清做了什么 + 结果好坏（"较 baseline -3.2% mae" 这种数值化表达）。
- \`- 关键字段\`：表格 \`字段\` | \`值\`，列出 \`TS\` / \`ANCHOR\` / \`VERDICT\` / \`METRIC\`（保留原文）。
- \`- 改动\`：把 \`### What changed\` 三行（editable_files / add_by_HARP / yaml）翻译为中文 bullet。
- \`- 学到了什么\`：把 \`### Lesson / Next\` 翻译为 2-3 条中文 bullet。
- 如果该实验属于"架构/数据流"改动（而不仅是 HP/schedule 微调），追加一段
  \`\`\`mermaid
  flowchart LR
    输入 --> 旧模块 --> 输出
    输入 --> 新模块 --> 输出
    旧模块 -. 替换 .-> 新模块
  \`\`\`
  用 mermaid 简洁画出"旧 -> 新"的结构差异（节点用中文标签 + 英文 symbol 名混排即可）。
  纯 HP 微调不要画 mermaid（避免噪声）。

约束：
1. 保留 EXP_ID / ANCHOR / PLAN / BEST_VAL_MAE / VERDICT 等关键字段原文。
2. 不要凭空增加原文没有的信息。
3. 直接出中文 Markdown，不要前置说明。

=== memory.md 原文 ===
$content
=== 结束 ===
EOF
      ;;
    plan)
      cat <<EOF
你是 HARP 中文润色助手。下面是 plan.md 原文，每个 ### PLAN_ID 是一个实验计划块。

请翻译润色成结构化的中文 Markdown，严格按下列骨架：

# HARP 实验计划（中文）

## 一、待办状态汇总
一个 Markdown 表格：\`PLAN_ID\` | \`anchor\` | \`axis\` | \`status\` | \`期望\`。
按状态分组（pending → in_progress → done → discard），每组按时间倒序。

## 二、详细 plan 解读
对每个 ### PLAN_ID 产出 \`### PLAN_ID: <原文>\` 子节，子节内：
- \`- 动机\`：把 motivation 翻译成 2-3 句中文，明确引用了哪些 EXP_ID / userprompt 规则。
- \`- 改动\`：bullet 列出本 plan 计划做的代码 / config 改动。
- \`- 期望\`：bullet 写明假设和判停条件。
- \`- 当前状态\`：保留 status 原文 + 一句中文说明现在卡在哪。

约束：
1. 保留 PLAN_ID / anchor / axis / status / metric / threshold 等字段原文。
2. 不要凭空增加内容。
3. 直接出中文 Markdown，不要前置说明。

=== plan.md 原文 ===
$content
=== 结束 ===
EOF
      ;;
  esac
}

# ── Build the multi-file digest prompt ────────────────────────────
# Combines log.md + memory.md + plan.md into one cross-cutting research
# report patterned after REPORT_2026-04-23_data_refresh.md (timeline
# table + per-section narrative + mermaid for any architecture move).
build_digest_prompt() {
  local log_text="$1" memory_text="$2" plan_text="$3"
  cat <<EOF
你是 HARP 中文研究报告撰写者。下面同时给出 \`log.md\`、\`memory.md\`、\`plan.md\` 三个原文。
请合成一份"研究报告"风格的中文 Markdown，目标读者是项目负责人，希望快速了解
"现在到哪一步了 / 学到了什么 / 下一步打算做什么"。

请严格按下列骨架输出：

# HARP 研究简报 — 自动生成
> 生成时间：UTC，由 \`harp_polish.sh --digest\` 输出。

## 一、TL;DR（5 行以内）
- 当前 best_val_mae（数值 + 锚点 ANCHOR）
- 距离 stop_threshold 还差多少
- 最近一次有意义事件（新 keep / DATASET DRIFT / PROGRAM SYNC 等）
- 现在 in-flight 在跑什么（如有）
- 下一步明面上的 plan_id

## 二、时间线（最新在上）
Markdown 表格：\`时间 (UTC)\` | \`类型\` | \`PLAN_ID\` | \`ANCHOR\` | \`关键指标\` | \`一句话\`。
\`类型\` 可用 \`新结果\` / \`弃训\` / \`IN-FLIGHT\` / \`PROGRAM SYNC\` / \`DRIFT\` / \`阈值达成\`。
信息融合自 log.md（时间线）+ memory.md（结论）+ plan.md（动机）。
最多列 30 行，更早的写"…（更早内容请见 log.md / memory.md）"。

## 三、有效经验（已 keep 的实验）
针对每个 \`VERDICT: keep\` 的 EXP_ID，给一个二级 bullet：
\`- EXP_ID（保留原文） — 一句话结论 — 关键 HP / 改动\`。
按 best_val_mae 升序排列（最好的在最上）。

## 四、被剪枝的方向（discard 集合）
按 axis（如 \`weight_decay\` / \`regression_loss\` / \`lr_schedule\` / \`architecture\`）
归并 discard 实验，每条 axis 输出：
\`- axis=<X> — 已尝试 N 次 — 现有结论：<一句话>\`。

## 五、当前 plan & 下一步
- 列出 plan.md 里所有 status=in_progress 的 plan，附中文动机。
- 列出 status=pending 的 plan 排队顺序。
- 如果 \`agent.userprompt\` 里有"架构创造力激励 / 大 batch_size"等元规则相关的待执行项，单独列出。

## 六、架构演化（仅当有新结构时才出现）
仅当 memory.md 里出现"editable_files diff"涉及 \`c_v3_c_v4_model.py\` 的实质改动
（不仅是改 HP / schedule），输出一段 mermaid 流程图，画出"旧前向 -> 新前向"的差异。
否则本节写一句"本周期暂无架构层面改动"即可。

## 七、风险与建议
3-5 条 bullet：当前主要风险（plateau / 数据漂移 / 长尾 HP 试错）+ 写作者的建议。
建议要具体可执行（"加 LR warmup 5 epoch"、"换成 architecture 类 plan"），不要空话。

约束：
1. 保留 ANCHOR / PLAN_ID / EXP_ID / best_val_mae 等原文 key。
2. 不要凭空增加原文没有的信息；找不到就写"原文未提及"。
3. 直接出中文 Markdown，不要任何前置或后置说明。

=== log.md 原文 ===
$log_text
=== 结束 ===

=== memory.md 原文 ===
$memory_text
=== 结束 ===

=== plan.md 原文 ===
$plan_text
=== 结束 ===
EOF
}

# ── Polish one file (single fresh cursor-agent chat) ──────────────
polish_file() {
  local kind="$1"   # log | memory | plan
  local src="$WORK_DIR/${kind}.md"
  local dst="$ZH_DIR/${kind}.md.zh.md"
  local cache="$ZH_DIR/.${kind}.src_sha256"

  [ -f "$src" ] || { echo "  skip $kind: $src not found"; return 0; }

  local sha
  sha=$(sha256sum "$src" | awk '{print $1}')
  if [ "$force" -eq 0 ] && [ -f "$cache" ] && [ "$(cat "$cache")" = "$sha" ]; then
    echo "  skip $kind: unchanged since last polish (sha matches)"
    return 0
  fi

  local content
  content=$(cat "$src")
  # Truncate excessively large files (cursor-agent has a context limit)
  local max_chars=120000
  if [ "${#content}" -gt $max_chars ]; then
    echo "  WARN $kind: source ${#content} chars > $max_chars, polishing tail only"
    content=$(tail -c $max_chars "$src")
  fi

  local prompt
  prompt=$(build_prompt "$kind" "$content")

  if [ "$dry_run" -eq 1 ]; then
    echo "==[ DRY-RUN $kind ]=================================="
    printf '%s\n' "$prompt" | head -50
    echo "==[ ... ${#prompt} chars total ]====================="
    return 0
  fi

  echo "  polishing $kind ($(printf '%s' "$content" | wc -l) lines, ${#content} chars) ..."

  # Fresh chat: NO --resume.  Output to stream-json so we can record
  # token usage in the same .state/usage.jsonl (mode=polish_zh_$kind).
  local raw="$ZH_DIR/.${kind}.last_stream.jsonl"
  local rc=0
  cursor-agent -p --force \
    --output-format stream-json --stream-partial-output \
    "$prompt" > "$raw" 2>&1 || rc=$?

  # Extract the assistant's final text + usage from the stream.
  python3 - "$raw" "$dst" "$kind" "$WORK_DIR/.state/usage.jsonl" "$WORK_DIR/.state/usage_summary.txt" <<'PY'
import sys, json, pathlib, os
from datetime import datetime, timezone
raw_path, dst_path, kind, usage_jsonl, usage_summary = sys.argv[1:6]
_now = lambda: datetime.now(timezone.utc)
text_chunks, usage, final_text = [], {}, ""
for line in pathlib.Path(raw_path).read_text(errors="ignore").splitlines():
    line = line.strip()
    if not line.startswith("{"): continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if ev.get("type") == "assistant":
        for c in ev.get("message", {}).get("content", []) or []:
            if c.get("type") == "text" and c.get("text"):
                text_chunks.append(c["text"])
    elif ev.get("type") == "result":
        usage = ev.get("usage", {}) or {}
        if isinstance(ev.get("result"), str):
            final_text = ev["result"]

text = final_text or (max(text_chunks, key=len) if text_chunks else "")
if not text:
    print(f"  ERROR: empty polish output for {kind}; check {raw_path}", file=sys.stderr)
    sys.exit(3)

pathlib.Path(dst_path).write_text(
    f"<!-- auto-generated by harp_polish.sh — do not edit -->\n"
    f"<!-- source: {kind}.md  polished: {_now().strftime('%Y-%m-%dT%H:%M:%SZ')} -->\n\n"
    + text + "\n"
)

if usage:
    rec = {
        "ts": _now().strftime("%Y%m%dT%H%M%SZ"),
        "cycle": 0, "mode": f"polish_zh_{kind}", "timed_out": False,
        "input_tokens": usage.get("inputTokens", 0),
        "output_tokens": usage.get("outputTokens", 0),
        "cache_read_tokens": usage.get("cacheReadTokens", 0),
        "cache_write_tokens": usage.get("cacheWriteTokens", 0),
    }
    with open(usage_jsonl, "a") as f:
        f.write(json.dumps(rec) + "\n")
    print(f"  ✓ {kind}: in={rec['input_tokens']} out={rec['output_tokens']} "
          f"cache_r={rec['cache_read_tokens']}")
else:
    print(f"  ✓ {kind}: written (no usage info from agent)")
PY
  local py_rc=$?
  if [ $py_rc -eq 0 ]; then
    echo "$sha" > "$cache"
  fi
  return $py_rc
}

echo "==[ harp_polish ]=================================="
echo "  workspace : $WORK_DIR"
echo "  output    : $ZH_DIR/"
echo

# ── Build the cross-file research digest (REPORT.zh.md) ───────────
polish_digest() {
  local dst="$ZH_DIR/REPORT.zh.md"
  local cache="$ZH_DIR/.REPORT.src_sha256"

  local log_src="$WORK_DIR/log.md"
  local mem_src="$WORK_DIR/memory.md"
  local plan_src="$WORK_DIR/plan.md"

  for s in "$log_src" "$mem_src" "$plan_src"; do
    [ -f "$s" ] || { echo "  skip digest: $s missing"; return 0; }
  done

  # Combined sha across all three sources — re-polish if any changed.
  local sha
  sha=$(sha256sum "$log_src" "$mem_src" "$plan_src" | sha256sum | awk '{print $1}')
  if [ "$force" -eq 0 ] && [ -f "$cache" ] && [ "$(cat "$cache")" = "$sha" ]; then
    echo "  skip digest: unchanged since last polish"
    return 0
  fi

  # Per-file char budgets — digest needs all three so be conservative.
  local max_each=40000
  local log_text mem_text plan_text
  log_text=$(tail -c $max_each "$log_src")
  mem_text=$(tail -c $max_each "$mem_src")
  plan_text=$(tail -c $max_each "$plan_src")

  local prompt
  prompt=$(build_digest_prompt "$log_text" "$mem_text" "$plan_text")

  if [ "$dry_run" -eq 1 ]; then
    echo "==[ DRY-RUN digest ]================================="
    printf '%s\n' "$prompt" | head -80
    echo "==[ ... ${#prompt} chars total ]====================="
    return 0
  fi

  echo "  polishing digest (log+memory+plan combined, ${#prompt} chars prompt) ..."

  local raw="$ZH_DIR/.REPORT.last_stream.jsonl"
  local rc=0
  cursor-agent -p --force \
    --output-format stream-json --stream-partial-output \
    "$prompt" > "$raw" 2>&1 || rc=$?

  python3 - "$raw" "$dst" "digest" "$WORK_DIR/.state/usage.jsonl" "$WORK_DIR/.state/usage_summary.txt" <<'PY'
import sys, json, pathlib
from datetime import datetime, timezone
raw_path, dst_path, kind, usage_jsonl, _ = sys.argv[1:6]
_now = lambda: datetime.now(timezone.utc)
text_chunks, usage, final_text = [], {}, ""
for line in pathlib.Path(raw_path).read_text(errors="ignore").splitlines():
    line = line.strip()
    if not line.startswith("{"): continue
    try:
        ev = json.loads(line)
    except json.JSONDecodeError:
        continue
    if ev.get("type") == "assistant":
        for c in ev.get("message", {}).get("content", []) or []:
            if c.get("type") == "text" and c.get("text"):
                text_chunks.append(c["text"])
    elif ev.get("type") == "result":
        usage = ev.get("usage", {}) or {}
        if isinstance(ev.get("result"), str):
            final_text = ev["result"]
text = final_text or (max(text_chunks, key=len) if text_chunks else "")
if not text:
    print(f"  ERROR: empty digest output; check {raw_path}", file=sys.stderr)
    sys.exit(3)
pathlib.Path(dst_path).write_text(
    f"<!-- auto-generated by harp_polish.sh --digest — do not edit -->\n"
    f"<!-- sources: log.md + memory.md + plan.md  built: "
    f"{_now().strftime('%Y-%m-%dT%H:%M:%SZ')} -->\n\n"
    + text + "\n"
)
if usage:
    rec = {
        "ts": _now().strftime("%Y%m%dT%H%M%SZ"),
        "cycle": 0, "mode": "polish_zh_digest", "timed_out": False,
        "input_tokens": usage.get("inputTokens", 0),
        "output_tokens": usage.get("outputTokens", 0),
        "cache_read_tokens": usage.get("cacheReadTokens", 0),
        "cache_write_tokens": usage.get("cacheWriteTokens", 0),
    }
    with open(usage_jsonl, "a") as f:
        f.write(json.dumps(rec) + "\n")
    print(f"  ✓ digest: in={rec['input_tokens']} out={rec['output_tokens']} "
          f"cache_r={rec['cache_read_tokens']}")
else:
    print("  ✓ digest: written (no usage info from agent)")
PY
  local py_rc=$?
  if [ $py_rc -eq 0 ]; then
    echo "$sha" > "$cache"
  fi
  return $py_rc
}

case "$which_file" in
  all)
    polish_file log
    polish_file memory
    polish_file plan
    ;;
  log|memory|plan) polish_file "$which_file" ;;
  digest) digest=1 ;;     # `--file digest` is an alias for --digest
  none) : ;;              # digest-only mode (set above when --digest alone)
  *) echo "ERROR: --file must be log|memory|plan|digest|all" >&2; exit 2 ;;
esac

if [ "$digest" -eq 1 ]; then
  polish_digest
fi

echo
echo "✓ done. View: ls -la $ZH_DIR/"
