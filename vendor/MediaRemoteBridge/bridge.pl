#!/usr/bin/perl
# Loads the MediaRemote bridge into /usr/bin/perl and streams every Now Playing session.
#   bridge.pl <path/to/libMediaRemoteBridge.dylib> [bridge_stream|bridge_snapshot]
use strict;
use warnings;
use DynaLoader;

my $lib = $ARGV[0] or die "usage: bridge.pl <dylib> [function]\n";
my $fn  = $ARGV[1] // "bridge_stream";

my $handle = DynaLoader::dl_load_file($lib, 0) or die "failed to load $lib\n";
my $symbol = DynaLoader::dl_find_symbol($handle, $fn) or die "symbol '$fn' not found\n";
DynaLoader::dl_install_xsub("main::run_bridge", $symbol);
main::run_bridge();
