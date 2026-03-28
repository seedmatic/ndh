use strict;
use warnings;

my $path = shift @ARGV or die "missing path to system.conf\n";

open my $in, '<', $path or die "cannot open '$path' for read: $!\n";
local $/ = undef;
my $content = <$in>;
close $in;

$content =~ s#<auth>EXTERNAL</auth>#<auth>EXTERNAL</auth>\n  <auth>ANONYMOUS</auth>\n  <allow_anonymous/>#g;

open my $out, '>', $path or die "cannot open '$path' for write: $!\n";
print {$out} $content;
close $out;
