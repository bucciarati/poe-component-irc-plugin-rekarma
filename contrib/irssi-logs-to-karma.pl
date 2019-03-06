#!/usr/bin/env perl

use v5.14.0;
use strict;
use warnings;

unless ($ARGV[0]) {
    warn <<END_OF_USAGE;
    Usage:
        \$ cat irssi-logs/channel-name.log | $0 channel-name
END_OF_USAGE

    exit 1;
}

use FindBin qw($Bin);
use lib "$Bin/../lib";
use POE::Component::IRC::Plugin::ReKarma;

my $channel_name = $ARGV[0] . '-import-' . time;

sub yield { warn "-> $_[3]\n"; }
my $self = { channel_settings => { "$channel_name" => { debug => 1, } } };
my $irc = bless { nick => "AndreaDipre`" } ;

while ( <STDIN> ) {
  chomp;
  s/^\d\d:\d\d <[^>]+> //;
  # use Devel::Peek;
  # Dump $_ if /un grande attore/;
  POE::Component::IRC::Plugin::ReKarma::S_public(
      $self,
      $irc,
      \"mariottide!foo\@ballerina",
      \( ["$channel_name"] ),
      # \$_,
      \(Encode::decode_utf8($_)),
  );
}
