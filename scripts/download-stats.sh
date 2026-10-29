#!/usr/bin/env bash
# Prints download counts per release from GitHub's public API (no token needed).
#
#   scripts/download-stats.sh
#
# Columns:
#   Downloads  Tinycap-<version>.dmg: new installs from the website, README or Homebrew.
#   Updates    Tinycap-<version>-update.dmg: in-app updates through Sparkle. Releases made
#              before this file existed (0.1.0–0.3.0) count updates under Downloads.
#   Checks     appcast.xml: update checks while this was the latest release. Sparkle
#              checks about once a day per install, so checks per day for the latest
#              release roughly equals active installs with automatic checks on.
#
# Counts include your own downloads and test installs.
set -euo pipefail

REPO="${REPO:-soleo/tinycap}"
json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/releases?per_page=100")" \
  || { echo "error: couldn't reach api.github.com" >&2; exit 1; }

printf '%s' "$json" | perl -MJSON::PP -e '
  my $releases = JSON::PP->new->decode(do { local $/; <STDIN> });
  my %total = (dl => 0, up => 0, checks => 0);
  printf "%-9s %-11s %10s %8s %8s\n", "Release", "Published", "Downloads", "Updates", "Checks";
  for my $r (@$releases) {
    next if $r->{draft};
    my ($dl, $up, $checks) = (0, undef, 0);
    for my $a (@{ $r->{assets} }) {
      my ($name, $n) = ($a->{name}, $a->{download_count});
      if    ($name =~ /-update\.(dmg|zip)$/) { $up = ($up // 0) + $n }
      elsif ($name =~ /\.(dmg|zip)$/)        { $dl += $n }
      elsif ($name eq "appcast.xml")         { $checks += $n }
    }
    $total{dl} += $dl; $total{up} += $up // 0; $total{checks} += $checks;
    printf "%-9s %-11s %10d %8s %8d\n", $r->{tag_name}, substr($r->{published_at} // "", 0, 10),
      $dl, defined $up ? $up : "-", $checks;
  }
  printf "%-9s %-11s %10d %8d %8d\n", "Total", "", $total{dl}, $total{up}, $total{checks};
'
