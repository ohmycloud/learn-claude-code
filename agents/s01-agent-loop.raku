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

sub MAIN(:$command) {
    my $result = run-bash($command);
    say $result;
}
