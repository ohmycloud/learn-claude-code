#!/usr/bin/env raku
use v6.d;
use JSON::Fast;

# -- Constants --
constant WORKDIR       = $*CWD;
constant MODEL         = %*ENV<MODEL_ID>;
constant TEAM-DIR      = WORKDIR.add('.team');
constant INBOX-DIR     = TEAM-DIR.add('inbox');

constant VALID-MSG-TYPES = set<
    message
    broadcast
    shutdown_request
    shutdown_response
    plan_approval_response
>;

# ── MessageBus ──────────────────────────────────────────────────────────────
# One JSONL file per teammate under .team/inbox/<name>.jsonl
# Appended on send, drained (read + cleared) on read.

class MessageBus {
    has IO::Path $.dir;

    submethod BUILD(:$!dir = INBOX-DIR) {
        $!dir.mkdir unless $!dir.e;
    }

    method send(
        Str :$sender,
        Str :$to,
        Str :$content,
        Str :$msg-type = 'message',
            :%extra,
        --> Str
    ) {
        unless VALID-MSG-TYPES{$msg-type} {
            return "Error: Invalid type '$msg-type'. Valid: {VALID-MSG-TYPES.keys.sort.join(', ')}";
        }

        my %msg =
            type      => $msg-type,
            from      => $sender,
            content   => $content,
            timestamp => now.Rat;   # POSIX-like epoch as Rat

        %msg.append(%extra) if %extra;

        my $inbox = $!dir.add("$to.jsonl");
        $inbox.open(:a).say(to-json(%msg, :!pretty));   # append one JSON line
        "Sent $msg-type to $to"
    }

    method read-inbox(Str $name --> List) {
        my $inbox = $!dir.add("$name.jsonl");
        return () unless $inbox.e;

        my @messages = $inbox.lines
            .grep(*.chars)
            .map({ from-json($_) });

        $inbox.spurt('');   # drain
        @messages
    }

    method broadcast(Str :$sender, Str :$content, :@teammates --> Str) {
        my $count = 0;
        for @teammates -> $name {
            next if $name eq $sender;
            self.send(:$sender, :to($name), :$content, :msg-type<broadcast>);
            $count++;
        }
        "Broadcast to $count teammates"
    }
}

# Singleton bus
my $BUS = MessageBus.new;

# ── TeammateManager ──────────────────────────────────────────────────────────
# Persistent named agents stored in .team/config.json.
# Each agent runs in its own Raku thread (via a Promise).

class TeammateManager {
    has IO::Path $.dir;
    has IO::Path $!config-path;
    has %!config;
    has %!promises;     # name => Promise

    submethod BUILD(:$!dir = TEAM-DIR) {
        $!dir.mkdir unless $!dir.e;
        $!config-path = $!dir.add('config.json');
        %!config = self!load-config;
    }

    # ── private helpers ──────────────────────────────────────────────────────

    method !load-config(--> Hash) {
        $!config-path.e
            ?? from-json($!config-path.slurp)
            !! %( team_name => 'default', members => [] )
    }

    method !save-config() {
        $!config-path.spurt(to-json(%!config, :pretty));
    }

    method !find-member(Str $name --> Hash) {
        %!config<members>.first({ $_<name> eq $name }) // Hash
    }

    # ── exec: dispatch a tool call on behalf of a teammate ───────────────────

    method !exec(Str $sender, Str $tool-name, %args --> Str) {
        given $tool-name {
            when 'bash'         { run-bash(%args<command>) }
            when 'read_file'    { run-read(%args<path>) }
            when 'write_file'   { run-write(%args<path>, %args<content>) }
            when 'edit_file'    { run-edit(%args<path>, %args<old_text>, %args<new_text>) }
            when 'send_message' {
                $BUS.send(
                    :sender($sender),
                    :to(%args<to>),
                    :content(%args<content>),
                    :msg-type(%args<msg_type> // 'message'),
                )
            }
            when 'read_inbox' { to-json($BUS.read-inbox($sender), :pretty) }
            default           { "Unknown tool: $tool-name" }
        }
    }

    # ── tool schema returned to the Anthropic API ────────────────────────────
    method !teammate-tools(--> List) {
        (
            %( name => 'bash',
               description => 'Run a shell command.',
               input_schema => %( type => 'object',
                   properties => %( command => %( type => 'string' ) ),
                   required   => ['command'] ) ),

            %( name => 'read_file',
               description => 'Read file contents.',
               input_schema => %( type => 'object',
                   properties => %( path => %( type => 'string' ) ),
                   required   => ['path'] ) ),

            %( name => 'write_file',
               description => 'Write content to file.',
               input_schema => %( type => 'object',
                   properties => %( path    => %( type => 'string' ),
                                    content => %( type => 'string' ) ),
                   required   => <path content> ) ),

            %( name => 'edit_file',
               description => 'Replace exact text in file.',
               input_schema => %( type => 'object',
                   properties => %( path     => %( type => 'string' ),
                                    old_text => %( type => 'string' ),
                                    new_text => %( type => 'string' ) ),
                   required   => <path old_text new_text> ) ),

            %( name => 'send_message',
               description => 'Send message to a teammate.',
               input_schema => %( type => 'object',
                   properties => %(
                       to       => %( type => 'string' ),
                       content  => %( type => 'string' ),
                       msg_type => %( type => 'string',
                                      enum => VALID-MSG-TYPES.keys.sort.List ),
                   ),
                   required => <to content> ) ),

            %( name => 'read_inbox',
               description => 'Read and drain your inbox.',
               input_schema => %( type => 'object', properties => %() ) ),
        )
    }

    # ── spawn: create or restart a teammate in its own thread ────────────────

    method spawn(Str $name, Str $role, Str $prompt --> Str) {
        my $member = self!find-member($name);

        if $member {
            if $member<status> ∉ <idle shutdown> {
                return "Error: '$name' is currently {$member<status>}";
            }
            $member<status> = 'working';
            $member<role>   = $role;
        }
        else {
            $member = %( name => $name, role => $role, status => 'working' );
            %!config<members>.push($member);
        }
        self!save-config;

        # Raku: start {} returns a Promise that runs the block in a thread pool
        %!promises{$name} = start {
            self!teammate-loop($name, $role, $prompt)
        };

        "Spawned '$name' (role: $role)"
    }

    method !set-status(Str $name, Str $status) {
        if my $m = self!find-member($name) {
            $m<status> = $status;
            self!save-config;
        }
    }

    # ── public query helpers ─────────────────────────────────────────────────

    method list-all(--> Str) {
        return 'No teammates.' unless %!config<members>;

        my @lines = "Team: {%!config<team_name>}";
        for %!config<members>.list -> $m {
            @lines.push("  {$m<name>} ({$m<role>}): {$m<status>}");
        }
        @lines.join("\n")
    }

    method member-names(--> List) {
        %!config<members>.map(*<name>).list
    }
}

# Singleton manager
my $TEAM = TeammateManager.new;
