#!/usr/bin/perl
use strict;
use warnings;
use lib 'commands';
use Helper qw/:DEFAULT :skills :races/;

help("Looks up aptitudes for specified race/skill combination.");

my %apts;

# helper functions
sub parse_apt_file { # {{{
    my %apts;
    my $aptfile = shift;
    open(my $fh, '<', $aptfile) or error "Couldn't open $aptfile for reading";
    my $race;
    while (<$fh>) {
        # kinda ugly, but we have to skip the commented out stats at the
        # end of the array
        if (/spec_skills\[/ .. /\*\*\*\*\*\*\*\*\*\*\*/) {
            if (/{\s*\/\/\s*(\w+)/) {
                $race = normalize_race $1;
                die unless defined $race;
            }
            elsif (/^\s*(.*?),\s*\/\/\s*(\w+)/) {
                next if $2 eq 'undefined' || $2 eq 'SK_UNUSED_1';
                my $apt = eval "use integer; $1";
                my $skill = normalize_skill $2;
                $apts{$race}{$skill} = $apt;
            }
        }
    }
    close $fh;
    return %apts;
} # }}}
sub add_exp_apts { # {{{
    my $aptref = shift;
    my %apts = %{ $aptref };
    my $aptfile = shift;
    open(my $fh, '<', $aptfile) or error "Couldn't open $aptfile for reading";
    my (@races, $genus);
    while (<$fh>) {
        if (/int _species_exp_mod\(/ .. /^}/) {
            if (/(GENPC_\w+)/) {
                @races = genus_to_races($1);
            }
            elsif (/(SP_\w+)/) {
                push @races, normalize_race($1);
            }
            elsif (/return (\d+);/) {
                for my $race (@races) {
                    $apts{$race}{experience} = $1 * 10;
                }
                @races = ();
            }
        }
    }
    close $fh;
    return %apts;
} # }}}
sub is_best_apt { # {{{
    my ($race, $skill) = @_;
    for (@races) {
        return 0 if $apts{$_}{$skill} < $apts{$race}{$skill};
    }
    return 1;
} # }}}
sub is_worst_apt { # {{{
    my ($race, $skill) = @_;
    for (@races) {
        return 0 if $apts{$_}{$skill} > $apts{$race}{$skill};
    }
    return 1;
} # }}}
sub apt { # {{{
    my ($race, $skill) = @_;
    return $apts{$race}{$skill} . (is_best_apt($race, $skill) ? "!" :
                                   is_worst_apt($race, $skill) ? "*" : "");
} # }}}
sub check_long_option { # {{{
    my $word = shift;
    $word =~ /-?(.*?)=(.*)/;
    my ($option, $val) = ($1, $2);
    return unless defined $option && defined $val;
    $val = lc $val;

    if ((substr $option, 0, 2) eq 'so') {
        return ('sort', $val);
    }
    elsif ((substr $option, 0, 1) eq 's') {
        return ('skill', normalize_skill($val));
    }
    elsif ((substr $option, 0, 1) eq 'r') {
        return ('race', normalize_race($val));
    }
    elsif ((substr $option, 0, 1) eq 'c') {
        return ('color', $val) if is_valid_drac_color $val;
        error "Invalid color: $val";
    }
    else {
        return;
    }
} # }}}
sub print_single_apt { # {{{
    my ($race, $skill) = @_;
    print short_race($race),
          " (", code_skill($skill), ")=",
          apt($race, $skill), "\n";
} # }}}
sub print_race_apt { # {{{
    my ($race, $sort) = @_;
    my @list = @skills;
    @list = sort @list if defined $sort && $sort eq 'alpha';
    my @out;
    for (@list) {
        push @out, (short_skill $_) . '=' . (apt $race, $_);
    }
    print short_race($race), ": ", join(', ', @out), "\n";
} # }}}
sub print_skill_apt { # {{{
    my ($skill, $sort) = @_;
    my @list = @races;
    @list = sort @list if defined $sort && $sort eq 'alpha';
    my @out;
    for (@list) {
        push @out, (short_race $_) . '=' . (apt $_, $skill);
    }
    print short_skill($skill), ": ", join(', ', @out), "\n";
} # }}}

# get the aptitudes out of the source file
%apts = parse_apt_file "$source_dir/source/skills2.cc";
%apts = add_exp_apts \%apts, "$source_dir/source/player.cc";
# get the request
my @words = split ' ', strip_cmdline $ARGV[2];
my @rest;

# loop over the words, checking for things we understand
my %opts = (sort => 'alpha');
while (@words) {
    my ($test, $option);

    ($option, $test) = check_long_option $words[0];
    if (defined $test) {
        error "$option already defined with $opts{$option}, but I got $test"
            if exists $opts{$option};
        $opts{$option} = $test;
        shift @words;
        next;
    }

    $test = normalize_race join ' ', @words;
    if (defined $test) {
        error "race already defined with $opts{race}, but I got $test"
            if exists $opts{race};
        $opts{race} = $test;
        @words = @rest;
        @rest = ();
        next;
    }

    $test = normalize_skill join ' ', @words;
    if (defined $test) {
        error "skill already defined with $opts{skill}, but I got $test"
            if exists $opts{skill};
        $opts{skill} = $test;
        @words = @rest;
        @rest = ();
        next;
    }

    unshift @rest, pop @words;
    if (@words == 0) {
        error "Could not understand \"$rest[0]\"";
    }
}

# check for validity of the color option
if (exists $opts{color}) {
    if (!defined $opts{race} || $opts{race} ne 'base draconian') {
        error "The color option is only valid for draconians";
    }
    $opts{race} = "$opts{color} draconian";
}

# print the result
if (exists $opts{race} && exists $opts{skill}) {
    print_single_apt $opts{race}, $opts{skill}, $opts{sort};
}
elsif (exists $opts{race}) {
    print_race_apt $opts{race}, $opts{sort};
}
elsif (exists $opts{skill}) {
    print_skill_apt $opts{skill}, $opts{sort};
}
else {
    error "You must provide at least a race or a skill";
}
