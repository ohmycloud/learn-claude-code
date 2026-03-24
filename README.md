This is an awesome site: [https://learn.shareai.run](https://learn.shareai.run).

Build a nano Claude Code-like agent from 0 to 1, one mechanism at a time.

# s01 - The Agent Loop

Bash is All You Need.

The minimal agent kernel is a while loop + one tool.

## Problem

A language model can reason about code, but it can't touch the real world -- can't read files, run tests, or check errors.
Without a loop, every tool call requires you to manually copy-paste results back. You become the loop.

## Solution

```
+--------+      +-------+      +---------+
|  User  | ---> |  LLM  | ---> |  Tool   |
| prompt |      |       |      | execute |
+--------+      +---+---+      +----+----+
                    ^                |
                    |   tool_result  |
                    +----------------+
                    (loop until stop_reason != "tool_use")
```
One exit condition controls the entire flow. The loop runs until the model stops calling tools.

## How It Works

1. User prompt becomes the first message.

```python
messages.append({"role": "user", "content": query})
```

2. Send messages + tool definitions to the LLM.

```python
response = client.messages.create(
    model=MODEL, system=SYSTEM, messages=messages,
    tools=TOOLS, max_tokens=8000,
)
```

3. Append the assistant response. Check stop_reason -- if the model didn't call a tool, we're done.

```python
messages.append({"role": "assistant", "content": response.content})
if response.stop_reason != "tool_use":
    return
```

4. Execute each tool call, collect results, append as a user message. Loop back to step 2.

```python
results = []
for block in response.content:
    if block.type == "tool_use":
        output = run_bash(block.input["command"])
        results.append({
            "type": "tool_result",
            "tool_use_id": block.id,
            "content": output,
        })
messages.append({"role": "user", "content": results})
```

Assembled into one function:

```python
def agent_loop(query):
    messages = [{"role": "user", "content": query}]
    while True:
        response = client.messages.create(
            model=MODEL, system=SYSTEM, messages=messages,
            tools=TOOLS, max_tokens=8000,
        )
        messages.append({"role": "assistant", "content": response.content})

        if response.stop_reason != "tool_use":
            return

        results = []
        for block in response.content:
            if block.type == "tool_use":
                output = run_bash(block.input["command"])
                results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": output,
                })
        messages.append({"role": "user", "content": results})
```

That's the entire agent in under 30 lines. Everything else in this course layers on top -- without changing the loop.

## What Changed

| COMPONENT    | BEFORE | AFTER                       |
|--------------|--------|-----------------------------|
| Agent loop   | (none) | `while True` + stop_reason  |
| Tools        | (none) | `bash` (one tool)           |
| Messages     | (none) | Accumulating list           |
| Control flow | (none) | `stop_reason != "tool_use"` |

## Try It

```bash
cd learn-claude-code
uv run python s01-agent-loop.py
```

1. Create a file called hello.py that prints "Hello, World!"
2. List all Python files in this directory
3. What is the current git branch?
4. Create a directory called test_output and write 3 files in it

# s02 - Tools

The loop stays the same; new tools register into the dispatch map.

The Dispatch Map - A dictionary maps tool names to handler functions. The loop code never changes.

- `dispatch(name)`
  - `bash` — Execute shell commands
  - `read_file` — Read file contents
  - `write_file` — Create or overwrite a file
  - `edit_file` — Apply targeted edits

> "Adding a tool means adding one handler" -- the loop stays the same; new tools register into the dispatch map.

## Problem

With only `bash`, the agent shells out for everything. `cat` truncates unpredictably, `sed` fails on special characters, and every bash call is an unconstrained security surface. Dedicated tools like `read_file` and `write_file` let you enforce path sandboxing at the tool level.

The key insight: adding tools does not require changing the loop.

## Solution

```
+--------+      +-------+      +------------------+
|  User  | ---> |  LLM  | ---> | Tool Dispatch    |
| prompt |      |       |      | {                |
+--------+      +---+---+      |   bash: run_bash |
                    ^           |   read: run_read |
                    |           |   write: run_wr  |
                    +-----------+   edit: run_edit |
                    tool_result | }                |
                                +------------------+

The dispatch map is a dict: {tool_name: handler_function}.
One lookup replaces any if/elif chain.
```

## How It Works

1. Each tool gets a handler function. Path sandboxing prevents workspace escape.

```python
def safe_path(p: str) -> Path:
    path = (WORKDIR / p).resolve()
    if not path.is_relative_to(WORKDIR):
        raise ValueError("Path escapes the workspace: {p}")
    return path
    
def run_read(path: str, limit: int = None) -> str:
    text = safe_path(path).read_text()
    lines = text.splitlines()
    if limit and limit < len(lines):
        lines = lines[:limit]
    return "\n".join(lines)[:50000]
```

2. The dispatch map links tool names to handlers.

```python
TOOL_HANDLERS = {
    "bash":       lambda **kw: run_bash(kw["command"]),
    "read_file":  lambda **kw: run_read(kw["path"], kw.get("limit")),
    "write_file": lambda **kw: run_write(kw["path"], kw["content"]),
    "edit_file":  lambda **kw: run_edit(kw["path"], kw["old_text"], kw["new_text"]),
}
```

3. In the loop, look up the handler by name. The loop body itself is unchanged from s01.

```python
for block in response.content:
    if block.type = "tool_use":
        handler = TOOL_HANDLERS.get(block.name)
        output = handler(**block.inpput) if handler else f"Unknown tool: {block.name}"
        results.append({
            "type": "tool_result",
            "tool_use_id": block.id,
            "content": output,
        })
```

Add a tool = add a handler + add a schema entry. The loop never changes.

# What Changed From s01

| COMPONENT	  | BEFORE (S01)       	| AFTER (S02)                 |
|-------------|---------------------|-----------------------------|
| Tools	      | 1 (bash only)	      | 4 (bash, read, write, edit) |
| Dispatch	  | Hardcoded bash call	| `TOOL_HANDLERS` dict        |
| Path safety	| None	              | `safe_path()` sandbox       |
| Agent loop  |	Unchanged	          | Unchanged                   |


# Try It

```bash
cd learn-claude-code
uv run python s02-tool-use.py
```

1. Read the file pyproject.toml
2. Create a file called greet.py with a greet(name) function
3. Edit greet.py to add a docstring to the function
4. Read greet.py to verify the edit worked

# s03 - ToDoWrite

Plan Before You Act

> An agent without a plan drifts; list the steps first, then execute.

## ToDoWrite Nag System

## Problem

On multi-step tasks, the model loses track. It repeats work, skips steps, or wanders off. 
Long conversations make this worse -- the system prompt fades as tool results fill the context. A 10-step refactoring might complete steps 1-3, then the model starts improvising because it forgot steps 4-10.

## Solution

```
+--------+      +-------+      +---------+
|  User  | ---> |  LLM  | ---> | Tools   |
| prompt |      |       |      | + todo  |
+--------+      +---+---+      +----+----+
                    ^                |
                    |   tool_result  |
                    +----------------+
                          |
              +-----------+-----------+
              | TodoManager state     |
              | [ ] task A            |
              | [>] task B  <- doing  |
              | [x] task C            |
              +-----------------------+
                          |
              if rounds_since_todo >= 3:
                inject <reminder> into tool_result
```

## How It Works

1. ToDoManager stores items with status. Only one item can be `in_progress` at a time.

```python
class ToDoManager:
    def update(self, items: list) -> str:
        validated, in_progress_count = [], 0
        for item in items:
            status = item.get("status", "pending")
            if status == "in_progress":
                in_progress_count += 1
            validated.append({"id": item["id"], "text": item["text"], "status": status})
            
        if in_progress_count > 1:
            raise ValueError("Only one task can be in_progress")
        self.items = validated
        return self.render()
```

2. The `todo` tool goes into the dispatch map like any other tool.

```python
TOOL_HANDLERS = {
    # ...base tools...
    "todo": lambda **kw: TODO.update(kw["items"]),
}
```

3. A nag reminder injects a nudge if the model goes 3+ rounds without calling `todo`.

```python
if rounds_since_to_do >= 3 and messages:
    last = messages[-1]
    if last["role"] == "user" and isinstance(last.get("content"), list):
        last["content"].insert(0, {
            "type": "text",
            "text": "<reminder>Update your todos.</reminder>",
        })
```

The "one in_progress at a time" constraint forces sequential focus. The nag reminder creates accountability.

## What Changed From s02

| COMPONENT	    | BEFORE (S02)   	| AFTER (S03)                 |
|---------------|-----------------|-----------------------------|
| Tools	        | 4            	  | 5 (+todo)                   |
| Planning	    | None	          | TodoManager with statuses   | 
| Nag injection	| None	          | `<reminder>` after 3 rounds |
| Agent loop	  | Simple dispatch	| + rounds_since_todo counter |

## Try It

```bash
cd learn-claude-code
python s03-todo-write.py
```

1. Refactor the file hello.py: add type hints, docstrings, and a main guard
2. Create a Python package with `__init__.py`, `utils.py`, and `tests/test_utils.py`
3. Review all Python files and fix any style issues

# s04 Subagent

> Subagents use independent messages[], keeping the main conversation clean.

"Break big tasks down; each subtask gets a clean context" -- subagents use independent messages[], keeping the main conversation clean.

## Problem

As the agent works, its messages array grows. Every file read, every bash output stays in context permanently. "What testing framework does this project use?" might require reading 5 files, but the parent only needs the answer: "pytest."

## Solution

```
Parent agent                     Subagent
+------------------+             +------------------+
| messages=[...]   |             | messages=[]      | <-- fresh
|                  |  dispatch   |                  |
| tool: task       | ----------> | while tool_use:  |
|   prompt="..."   |             |   call tools     |
|                  |  summary    |   append results |
|   result = "..." | <---------- | return last text |
+------------------+             +------------------+

Parent context stays clean. Subagent context is discarded.
```

## How It Works

1. The parent gets a task tool. The child gets all base tools except task (no recursive spawning).

```python
PARENT_TOOLS = CHILD_TOOLS + [
    {
        "name": "task",
             "description": "Spawn a subagent with fresh context.",
             "input_schema": {
                 "type": "object",
                 "properties": {"prompt": {"type": "string"}},
                 "required": ["prompt"],
             }
    }
]
```

2. The subagent starts with messages=[] and runs its own loop. Only the final text returns to the parent.

```python
def run_subagent(prompt: str) -> str:
    sub_messages = [{"role": "user", "content": prompt}]
    for _ in range(30):
        response = client.messages.create(
            model=MODEL, system=SUBAGENT_SYSTEM,
            messages=sub_messages,
            tools=CHILD_TOOLS, max_tokens=8000,
        )
        
        sub_messages.append({"role": "assistant", "content": response.content})
        if response.stop_reason != "tool_use":
            break
        results = []
        for block in response.content:
            if block.type == "tool_use":
                handler = TOOL_HANDLERS.get(block.name)
                output = handler(**block.input)
                results.append({"type": "tool_result", "tool_use_id": block.id, "content": str(output)[:50000]})
        sub_messages.append({"role": "user", "content": results})
    return "".join(
        b.text for b in response.content if hasattr(b, "text")
    ) or "(no summary)"
```

The child's entire message history (possibly 30+ tool calls) is discarded. The parent receives a one-paragraph summary as a normal tool_result.

## What Changed From s03

| COMPONENT	  | BEFORE (S03)	| AFTER (S04)            |
|-------------|---------------|------------------------|
|Tools	      |5	            |5 (base) + task (parent)|
|Context	    |Single shared	|Parent + child isolation|
|Subagent	    |None           |run_subagent() function |
|Return value	| N/A	          |Summary text only       |

## Try It

```bash
cd learn-claude-code
python s04-subagent.py
```

1. Use a subtask to find what testing framework this project uses
2. Delegate: read all .py files and summarize what each one does
3. Use a task to create a new module, then verify it from here

# s05 - Skills

Load on Demand

Inject knowledge via tool_result when needed, not upfront in the system prompt.

## On-Demand Skill Loading

```
System Prompt always present

# Available Skills
/commit - Create git commits following repo conventions
/review-pr - Review pull requests for bugs and style
/test - Run and analyze test suites
/deploy - Deploy application to target environment
```

## Problem

You want the agent to follow domain-specific workflows: git conventions, testing patterns, code review checklists. Putting everything in the system prompt wastes tokens on unused skills. 10 skills at 2000 tokens each = 20,000 tokens, most of which are irrelevant to any given task.

## Solution

```
System prompt (Layer 1 -- always present):
+--------------------------------------+
| You are a coding agent.              |
| Skills available:                    |
|   - git: Git workflow helpers        |  ~100 tokens/skill
|   - test: Testing best practices     |
+--------------------------------------+

When model calls load_skill("git"):
+--------------------------------------+
| tool_result (Layer 2 -- on demand):  |
| <skill name="git">                   |
|   Full git workflow instructions...  |  ~2000 tokens
|   Step 1: ...                        |
| </skill>                             |
+--------------------------------------+
```

Layer 1: skill names in system prompt (cheap). Layer 2: full body via tool_result (on demand).

## How It Works

1. Each skill is a directory containing a SKILL.md with YAML frontmatter.

```
skills/
  pdf/
    SKILL.md       # ---\n name: pdf\n description: Process PDF files\n ---\n ...
  code-review/
    SKILL.md       # ---\n name: code-review\n description: Review code\n ---\n ...
```

2. SkillLoader scans for SKILL.md files, uses the directory name as the skill identifier.

```python
class SkillLoader:
    def __init__(self, skills_dir: Path):
        self.skills = {}
        for f in sorted(skills_dir.rglob("SKILL.md")):
            text = f.read_text()
            meta, body = self._parse_frontmatter(text)
            name = meta.get("name", f.parent.name)
            self.skills[name] = {"meta": meta, "body": body}
    
    def get_descriptions(self) -> str:
        lines = []
        for name, skill in self.skills.items():
            desc = skill["meta"].get("description", "")
            lines.append(f"  - {name}: {desc}")
        reurn "\n".join(lines)
        
def get_content(self, name: str) -> str:
    skill = self.skills.get(name)
    if not skill:
        return f"Error: Unknown skill '{name}'."
    return f"<skill name=\"{name}\">\n{skill['body']}\n</skill>"
```

3. Layer 1 goes into the system prompt. Layer 2 is just another tool handler.

```python
SYSTEM = f"""You are a coding agent at {WORKDIR}.
Skills available:
{SKILL_LOADER.get_descriptions()}"""

TOOL_HANDLERS = {
    # ...base tools...
    "load_skill": lambda **kw: SKILL_LOADER.get_content(kw["name"]),
}
```

The model learns what skills exist (cheap) and loads them when relevant (expensive).

## What Changed From s04

| COMPONENT   	| BEFORE (S04)	  | AFTER (S05)                 |
|---------------|-----------------|-----------------------------|
| Tools	        |5 (base + task)	| 5 (base + load_skill)       |
|System prompt	| Static string	  | + skill descriptions        |
|Knowledge	    | None	          | skills/*/SKILL.md files     |
|Injection	    | None	          | Two-layer (system + result) |

## Try It

```bash
cd learn-claude-code
python s05-skill-loading.py
```

1. What skills are available?
2. Load the agent-builder skill and follow its instructions
3. I need to do a code review -- load the relevant skill first
4. Build an MCP server using the mcp-builder skill

# s07 - Tasks

Task Graph + Dependencies

> A file-based task graph with ordering, parallelism, and dependencies -- the coordination backbone for multi-agent work

```
.tasks/tasks.json
Persisted to disk -- survives context compaction
```

> "Break big goals into small tasks, order them, persist to disk" -- a file-based task graph with dependencies, laying the foundation for multi-agent collaboration.

## Problem

s03's ToDoManager is a flat checklist in memory: no ordering, no dependencies, no status beyond done-or-not.
Real goals have structure -- task B depends on task A, task C and task D can run in parallel, task E waits for both C and D.

Without explicit realtionships, the agent can't tell what's ready, what's blocked, or what can run concurrently. And 
because the list lives only in memory, context compression (s06) wipes it clean.

## Solution

Promote the checklist into a **task graph** persisted to disk. Each task is a JSON file with status, dependencies (`blockedBy`), and dependents (`blocks`). The graph answers three questions at any moment:

What's ready? -- tasks with `pending` status and empty `blockedBy`.
What's blocked? -- tasks waiting on unfinished dependencies.
What's done? -- `completed` tasks, whose completion automatically unblocks dependents.

```
.tasks/
  task_1.json  {"id":1, "status":"completed"}
  task_2.json  {"id":2, "blockedBy":[1], "status":"pending"}
  task_3.json  {"id":3, "blockedBy":[1], "status":"pending"}
  task_4.json  {"id":4, "blockedBy":[2,3], "status":"pending"}

Task graph (DAG):
                 +----------+
            +--> | task 2   | --+
            |    | pending  |   |
+----------+     +----------+    +--> +----------+
| task 1   |                          | task 4   |
| completed| --> +----------+    +--> | blocked  |
+----------+     | task 3   | --+     +----------+
                 | pending  |
                 +----------+

Ordering:     task 1 must finish before 2 and 3
Parallelism:  tasks 2 and 3 can run at the same time
Dependencies: task 4 waits for both 2 and 3
Status:       pending -> in_progress -> completed
```

This task graph becomes the coordination backbone for everything after s07: background execution (s08), multi-agent teams (s09+), and worktree isolation (s12) all read from and write to this same structure.

## How It Works

1. **TaskManager**: one JSON file per task, CRUD with dependency graph.

```python
class TaskManager:
    def __init__(self, tasks_dir: Path):
        self.dir = tasks_dir
        self.dir_mkdir(exist_ok=True)
        self._next_id = self._max_id() + 1
        
    def create(self, subject, description=""):
        task = {"id": self._next_id, "subject": subject, "status": "pending", "blockedBy": [], "blocks": [], "owner": ""}
        self._save(task)
        self._next_id += 1
        return json.dumps(task, indent=2)
```

2. **Dependency resolution**: completing a task clears its ID from every other tasks's `blockBy` list, automatically unblocking dependents.

```python
def _clear_denpendency(self, completed_id):
    for f in self.dir.glob("task_*.json"):
        task = json.loads(f.read_text())
        if completed_id in task.get("blocledBy", []):
            task["blockedBy"].remove(completed_id)
            self._save(task)
```

3. **Status + depedency wiring**: `update` handles transitions and dependency edges.

```python
def update(self, task_id, status=None, add_blocked_by=None, add_blocks=None):
    task = self._load(task_id)
    if status:
        task["status"] = status
        if status == "completed":
            self._clear_dependency(task_id)
    self._save(task)
```

4. Four task tools go into the dispatch map.

```python
TOOL_HANDLERS = {
    # ...base tools...
    "task_create": lambda **kw: TASKS.create(kw["subject"]),
    "task_update": lambda **kw: TASKS.update(kw["task_id"], kw.get("status")),
    "task_list":   lambda **kw: TASKS.list_all(),
    "task_get":    lambda **kw: TASKS.get(kw["task_id"]),
}
```

From s07 onward, the task graph is the default for multi-step work. s03's Todo remains for quick single-session checklists.

## What Changed From s06

| COMPONENT	      | BEFORE (S06)                |	AFTER (S07)                              |
|-----------------|-----------------------------|------------------------------------------|
| Tools	          | 5	                          | 8 (`task_create/update/list/get`)        |
| Planning model	| Flat checklist (in-memory)	| Task graph with dependencies (on disk)   |
| Relationships	  | None	                      | `blockedBy` + `blocks` edges             |
| Status tracking	| Done or not	                | `pending` -> `in_progress` -> `completed`|
| Persistence	    | Lost on compression         |	Survives compression and restarts        |

## Try It

```bash
cd learn-claude-code
python s07-task-system.py
```

1. Create 3 tasks: "Setup project", "Write code", "Write tests". Make them depend on each other in order.
2. List all tasks and show the dependency graph
3. Complete task 1 and then list tasks to see task 2 unblocked
4. Create a task board for refactoring: parse -> transform -> emit -> test, where transform and emit can run in parallel after parse

# s06 - Compact(Memory Management)

Three_Layer Compression

> Context will fill up; three-layer compression strategy enables infinite sessions

## Three-Layer Context Compression

1. Stage 1: Micro -- shrink old tool_results
2. Stage 2: Auto -- summarize entire conversation
3. Stage 3: /compact -- user-triggered, deepest compression

## Problem

The context window is finite. A single `read_file` on a 1000-line file consts ~ 4000 tokens. After reading 30 files and running 20 bash commands,
you hit 100,000+ tokens. The agent cannot work on large codebases without compression.

## Solution

Three layers, increasing in aggressiveness:


```
Every turn:
+------------------+
| Tool call result |
+------------------+
        |
        v
[Layer 1: micro_compact]        (silent, every turn)
  Replace tool_result > 3 turns old
  with "[Previous: used {tool_name}]"
        |
        v
[Check: tokens > 50000?]
   |               |
   no              yes
   |               |
   v               v
continue    [Layer 2: auto_compact]
              Save transcript to .transcripts/
              LLM summarizes conversation.
              Replace all messages with [summary].
                    |
                    v
            [Layer 3: compact tool]
              Model calls compact explicitly.
              Same summarization as auto_compact.
```

## How It Works

1. **Layer 1 -- micro_compact**: Before each LLM call, replace old tool results with placeholders.

```python
def micro_compact(messages: list) -> list:
    tool_results = []
    for i, msg in enumerate(messages):
        if msg["role"] == "user" and isinstance(msg.get("content"), list):
            if isinstance(part, dict) and part.get("type") == "tool_result":
                tool_results.append((i, j, part))
                
    if len(tool_results) <= KEEP_RECENT:
        return messages
    
    for _, _ part in tool_results[:-KEEP_RECENT]:
        if len(part.get("content", "")) > 100:
            part["content"] = f"[Previous: used {tool_name}]"
    return messages
```

2. **Layer 2 -- auto_compact**: When tokens exceed threshold, save full transcript to disk, then ask the LLM to summarize.

```python
def auto_compact(messages: list) -> list:
    # Save transcript for recovery
    transcript_path = TRANSCRIPT_DIR / f"transcript_{int(time.time())}.jsonl"
    with open(transcript_path, "w") as f:
        for msg in messages:
            f.write(json.dumps(msg, default=str) + "\n")
    
    # LLM summarizes
    response = client.messages.create(
        model=MODEL,
        messages=[{"role": "user", "content": "Summarize this conversation for continuity..." + json.dumps(messages, default=str)[:80000]}],
        max_tokens=2000,
    )
    return [
        {"role": "user", "content": f"[Compressed]\n\n{response.content[0].text}"},
        {"role": "assistant", "content": "Understood. Continuing."},
    ]
```

3. **Layer 3 -- manual compact**: The `compact` tool triggers the same summarization on demand.
4. The loop integrates all three:

```python
def agent_loop(messages: list):
    while True:
        micro_compact(messages)                    # Layer 1
        if estimate_tokens(messages) > THRESHOLD:
            messages[:] = auth_comapct(messages)   # Layer 2
        response = client.messages.create(...)
        # ... tool execution ...
        if manual_compact:
            messages[:] = auto_compact(messages)   # Layer 3
```

Transcripts preserve full history on disk, Nothing is truly lost -- just moved out of active context.

## What Change From s05

| COMPONENT    	| BEFORE (S05)	| AFTER (S06)                    |
|---------------|---------------|--------------------------------|
| Tools	        | 5	            | 5 (base + compact)             |
| Context mgmt	| None	        | Three-layer compression        |
| Micro-compact	| None	        | Old results -> placeholders    |
| Auto-compact	| None	        | Token threshold trigger        |
| Transcripts	  | None	        | Saved to .transcripts/         |

## Try It

```bash
cd learn-claude-code
python s06-context-compact.py
```

1. Read every Python file in the agents/ directory one by one (watch micro-compact replace old results)
2. Keep reading files until compression triggers automatically
3. Use the compact tool to manually compress the conversation
