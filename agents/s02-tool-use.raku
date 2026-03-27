#!/usr/bin/env raku

# ── 依赖模块 ────────────────────────────────────────────────────────────────
# 安装方式: zef install Env::Dotenv
use Env::Dotenv :ALL;

# ══════════════════════════════════════════════════════════════════════════════
# 加载 .env 文件
# ══════════════════════════════════════════════════════════════════════════════

dotenv_load;

# ══════════════════════════════════════════════════════════════════════════════
# 全局配置
# ══════════════════════════════════════════════════════════════════════════════
my IO::Path $WORKDIR  = $*CWD;
my Str      $BASE-URL = %*ENV<ANTHROPIC_BASE_URL> // 'https://api.anthropic.com';
my Str      $API-KEY  = %*ENV<ANTHROPIC_API_KEY>  // die "未设置 ANTHROPIC_API_KEY";
my Str      $MODEL    = %*ENV<MODEL_ID>           // 'claude-opus-4-6';
my Str      $SYSTEM   = "You are a coding agent at $WORKDIR. Use tools to solve tasks. Act, don't explain.";

# ══════════════════════════════════════════════════════════════════════════════
# 路径安全检查（替代 Python 的 Path.resolve + is_relative_to）
# ══════════════════════════════════════════════════════════════════════════════
sub safe-path(Str $p --> IO::Path) {
    my IO::Path $path = $WORKDIR.add("/$p").resolve;
    die "Path escapes workspace: $p" unless $path.resolve.relative($WORKDIR);
    $path
}

# ══════════════════════════════════════════════════════════════════════════════
# 工具实现
# ══════════════════════════════════════════════════════════════════════════════

# ── bash 工具 ──────────────────────────────────────────────────────────────
sub run-bash(Str $command --> Str) {
    my @dangerous = ["rm -rf /", "sudo", "shutdown", "reboot", "> /dev/null"];
    if $command ~~@dangerous.any {
        return "Error: Dangerous command blocked";
    }

    my $proc = Proc::Async.new('bash', '-c', $command);

    my $output = '';
    $proc.stdout.tap({ $output ~= $_ });
    $proc.stderr.tap({ $output ~= $_ });

    my $promise = $proc.start;

    my $result = await Promise.anyof(
        $promise,
        Promise.in(120)
    );

    if $promise.status ~~ Kept {
        $output = $output.trim;
        return $output ?? $output.substr(0, 50000) !! "(no output)";
    } else {
        $proc.kill;
        return "Error: Timeout (120s)";
    }
}

# ── read_file 工具 ─────────────────────────────────────────────────────────
sub run-read(Str $path, Int $limit? --> Str) {
    CATCH { default { return "Error: {.message}" } }

    my @lines = safe-path($path).lines;            # .lines 惰性读取，自动处理换行

    if $limit.defined && $limit < @lines.elems {
        my $extra = @lines.elems - $limit;
        @lines    = @lines[^$limit];               # ^$limit 等价于 0..$limit-1
        @lines.push("... ($extra more lines)");
    }

    @lines.join("\n").substr(0, 50000)
}

# ── write_file 工具 ────────────────────────────────────────────────────────
sub run-write(Str $path, Str $content --> Str) {
    CATCH { default { return "Error: {.message}" } }

    my IO::Path $fp = safe-path($path);
    $fp.parent.mkdir(:p);                          # :p 等价于 mkdir -p（创建所有父目录）
    $fp.spurt($content);                           # spurt = 一次性写入文件
    "Wrote {$content.chars} bytes to $path"        # .chars 统计 Unicode 字符数
}

# ── edit_file 工具 ─────────────────────────────────────────────────────────
sub run-edit(Str $path, Str $old-text, Str $new-text --> Str) {
    CATCH { default { return "Error: {.message}" } }

    my IO::Path $fp = safe-path($path);
    my Str $content = $fp.slurp;

    return "Error: Text not found in $path"
        unless $content.contains($old-text);

    # .subst 默认只替换第一次出现（等价于 str.replace(old, new, 1)）
    $fp.spurt($content.subst($old-text, $new-text));
    "Edited $path"
}

# ══════════════════════════════════════════════════════════════════════════════
# 工具调度表
# ══════════════════════════════════════════════════════════════════════════════
# Raku 使用具名 Hash，值为匿名子例程（sub (...)）
my %TOOL-HANDLERS = (
    bash       => sub (%kw) { run-bash(%kw<command>) },
    read_file  => sub (%kw) { run-read(%kw<path>, %kw<limit>) },
    write_file => sub (%kw) { run-write(%kw<path>, %kw<content>) },
    edit_file  => sub (%kw) { run-edit(%kw<path>, %kw<old_text>, %kw<new_text>) },
);

# ══════════════════════════════════════════════════════════════════════════════
# 工具 Schema（JSON 结构用 Raku Hash/Array 原生表示）
# ══════════════════════════════════════════════════════════════════════════════
my @TOOLS = (
    {
        name        => 'bash',
        description => 'Run a shell command.',
        input_schema => {
            type       => 'object',
            properties => { command => { type => 'string' } },
            required   => ['command'],
        },
    },
    {
        name        => 'read_file',
        description => 'Read file contents.',
        input_schema => {
            type       => 'object',
            properties => {
                path  => { type => 'string' },
                limit => { type => 'integer' },
            },
            required   => ['path'],
        },
    },
    {
        name        => 'write_file',
        description => 'Write content to file.',
        input_schema => {
            type       => 'object',
            properties => {
                path    => { type => 'string' },
                content => { type => 'string' },
            },
            required   => ['path', 'content'],
        },
    },
    {
        name        => 'edit_file',
        description => 'Replace exact text in file.',
        input_schema => {
            type       => 'object',
            properties => {
                path     => { type => 'string' },
                old_text => { type => 'string' },
                new_text => { type => 'string' },
            },
            required   => ['path', 'old_text', 'new_text'],
        },
    },
);
