use strict;
use warnings;

my $path = shift @ARGV or die "missing path to system.conf\n";

open my $in, '<', $path or die "cannot open '$path' for read: $!\n";
local $/ = undef;
my $content = <$in>;
close $in;

$content =~ s#</busconfig>#  <policy context="default">\n    <allow send_destination="*"/>\n    <allow eavesdrop="true"/>\n    <allow own="*"/>\n    <allow receive_sender="*"/>\n  </policy>\n</busconfig>#g;

open my $out, '>', $path or die "cannot open '$path' for write: $!\n";
print {$out} $content;
close $out;
