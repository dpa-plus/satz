# Loads now-playing.dylib (the path is the first argument) into this Perl,
# Apple's own program, and prints what is playing as JSON. See now-playing.m.
use DynaLoader;
my $library = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
my $symbol = DynaLoader::dl_find_symbol($library, "satz_now_playing") or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub("main::now_playing", $symbol);
now_playing();
