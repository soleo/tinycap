#!/usr/bin/perl
# Converts the small Markdown subset used in ReleaseNotes/*.md (paragraphs, "#"
# headings, "-"/"*" bullets, **bold**, *italic*, `code`, [links](url)) to HTML for
# Sparkle's update window. Reads the file named on the command line; writes stdout.
use strict;
use warnings;
use utf8;
binmode STDIN, ':encoding(UTF-8)';
binmode STDOUT, ':encoding(UTF-8)';

sub inline {
    my ($t) = @_;
    $t =~ s/&/&amp;/g; $t =~ s/</&lt;/g; $t =~ s/>/&gt;/g;
    $t =~ s/`([^`]+)`/<code>$1<\/code>/g;
    $t =~ s/\*\*(.+?)\*\*/<strong>$1<\/strong>/g;
    $t =~ s/(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])/<em>$1<\/em>/g;
    $t =~ s/\[([^\]]+)\]\((https?:\/\/[^)\s"]+)\)/<a href="$2">$1<\/a>/g;
    return $t;
}

my (@out, @para, @items);
sub flush_para { push @out, '<p>' . inline(join(' ', @para)) . '</p>' if @para; @para = (); }
sub flush_list { push @out, '<ul>' . join('', map { '<li>' . inline($_) . '</li>' } @items) . '</ul>' if @items; @items = (); }

open(my $fh, '<:encoding(UTF-8)', $ARGV[0]) or die "can't read $ARGV[0]: $!";
while (my $raw = <$fh>) {
    chomp $raw;
    (my $line = $raw) =~ s/^\s+|\s+$//g;
    if ($line eq '') { flush_para(); flush_list(); }
    elsif ($line =~ /^[-*+]\s+(.*)/) { flush_para(); push @items, $1; }
    elsif ($line =~ /^#+\s*(.*)/) { flush_para(); flush_list(); push @out, '<h3>' . inline($1) . '</h3>'; }
    elsif ($raw =~ /^\s{2,}/ && @items && !@para) { $items[-1] .= " $line"; }
    else { flush_list(); push @para, $line; }
}
flush_para(); flush_list();

print <<'HTML';
<meta name="color-scheme" content="light dark">
<style>
body { font: 13px -apple-system, system-ui, sans-serif; line-height: 1.45; margin: 4px 2px; }
h3 { font-size: 13px; margin: 12px 0 4px; }
p { margin: 0 0 8px; }
ul { margin: 0 0 8px; padding-left: 18px; }
li { margin: 0 0 4px; }
code { font: 12px ui-monospace, Menlo, monospace; }
</style>
HTML
print join("\n", @out), "\n";
