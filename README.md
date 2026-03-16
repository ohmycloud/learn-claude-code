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
