#!/usr/bin/env perl
# Log line parser. Run with: perl main.pl

use strict;
use warnings;
use feature qw(say);

my @logs = (
    "2026-05-15 09:12:03 INFO  user=alice action=login",
    "2026-05-15 09:13:11 WARN  user=bob   action=retry attempt=3",
    "2026-05-15 09:14:55 ERROR user=carol action=upload reason=quota",
    "2026-05-15 09:15:22 INFO  user=alice action=logout",
);

my %by_level;
my %by_user;

for my $line (@logs) {
    if ($line =~ /^\S+ \S+ (\w+)\s+user=(\S+)\s+action=(\S+)/) {
        my ($level, $user, $action) = ($1, $2, $3);
        $by_level{$level}++;
        push @{ $by_user{$user} }, $action;
    }
}

say "By level:";
for my $level (sort keys %by_level) {
    printf "  %-6s %d\n", $level, $by_level{$level};
}

say "\nBy user:";
for my $user (sort keys %by_user) {
    my $actions = join(", ", @{ $by_user{$user} });
    say "  $user => $actions";
}
