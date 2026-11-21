# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file

# THE ADVANCED PAGE (the module keeps its old name, SettingsExports, and its header). It holds what the
# user almost never changes: the rating bands with Restore Defaults, SQLite Timeout, Pause before Next
# Fetch, and MIP Custom Tags. One Save. The bands are validated AS A SET - each must start higher than
# the one before - and a set that fails refuses the WHOLE page: a half-saved page is worse than a
# refused one. The export controls are on the Basic page (Settings.pm).

package Plugins::MIPster::SettingsExports;

use strict;
use warnings;
use base qw(Plugins::MIPster::SettingsBase);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings;

my $prefs = preferences('plugin.mipster');
my $log = logger('plugin.mipster');

# The stock scale. Restore Defaults writes exactly these, and they are the same numbers the export
# falls back to, so there is one set of defaults rather than two that could drift.
my %BANDDEFAULTS = (
	exportUnrated => 0,
	exportBand1   => 10,
	exportBand2   => 30,
	exportBand3   => 50,
	exportBand4   => 70,
	exportBand5   => 90,
);

my @ADVPREFS = qw(sqlitetimeout mipDelay);

sub name {
	 return Slim::Web::HTTP::CSRF->protectName('PLUGIN_MIPSTER_SUBPAGE_ADVANCED');
}

sub page {
	 return Slim::Web::HTTP::CSRF->protectURI('plugins/MIPster/settings/advanced.html');
}

sub currentPage {
	 return Slim::Utils::Strings::string('PLUGIN_MIPSTER_SUBPAGE_ADVANCED');
}

sub pages {
	 return [{ 'name' => Slim::Utils::Strings::string('PLUGIN_MIPSTER_SUBPAGE_ADVANCED'), 'page' => page() }];
}

sub scValidateBands {
	my $params = shift;

	my @keys = qw(exportBand1 exportBand2 exportBand3 exportBand4 exportBand5);
	my @vals;

	my $unrated = $params->{'exportUnrated'};
	return (0, 'unrated') unless defined $unrated && $unrated =~ /^\d+$/ && $unrated >= 0 && $unrated <= 5;

	foreach my $k (@keys) {
		my $v = $params->{$k};
		return (0, $k) unless defined $v && $v =~ /^\d+$/ && $v >= 1 && $v <= 100;
		push @vals, $v;
	}

	for my $i (1 .. $#vals) {
		return (0, 'order') unless $vals[$i] > $vals[$i - 1];
	}

	return (1, '');
}

sub handler {
	 my ( $class, $client, $params ) = @_;

	 my @offered = Plugins::MIPster::Plugin::scTagFields();
	 my %ok = map { $_->{'id'} => 1 } @offered;

	 # Restore Defaults is its own button and does not go through the validator - the stock scale is
	 # valid by definition, and needing a valid page in order to get back to a valid page would be a
	 # trap. It writes and returns; nothing else on the page is saved by that press.
	 if ( $params->{'screstorebands'} ) {
		foreach my $key (keys %BANDDEFAULTS) {
			$prefs->set( $key, $BANDDEFAULTS{$key} );
		}
		$log->info("Rating bands restored to the stock scale\n");
		$params->{'scbandsrestored'} = 1;

	 } elsif ( $params->{'saveSettings'} ) {
		my ($bandsok, $why) = scValidateBands($params);
		if ($bandsok) {
			foreach my $key (keys %BANDDEFAULTS) {
				$prefs->set( $key, $params->{$key} );
			}

			foreach my $pref (@ADVPREFS) {
				next unless defined $params->{$pref};
				my $value = $params->{$pref};
				$value =~ s/^\s+|\s+$//g;
				$prefs->set( $pref, "$value" );
			}

			# MIP CUSTOM TAGS: the rows post as customtag0, customtag1 ... in screen order. Each offered
			# field once. A field left without a row is cleared by the next export (scMIPTagsClear).
			my @keys = sort { ($a =~ /(\d+)$/)[0] <=> ($b =~ /(\d+)$/)[0] } grep { /^customtag\d+$/ } keys %$params;
			my (@chosen, %seen);
			foreach my $k (@keys) {
				my $v = $params->{$k} // '';
				push @chosen, $v if $ok{$v} && !$seen{$v}++;
			}
			$prefs->set('customTags', \@chosen);
			main::INFOLOG && $log->is_info && $log->info("MIP custom tags set to: ".(join(', ', @chosen) || 'none')."\n");

		} else {
			$log->error("MusicIP rating bands refused ($why) - each band must start higher than the "
				. "one before it. NOTHING on this page was saved.\n");
			$params->{'scbandserror'} = 1;
		}
	 }

	 foreach my $key ((keys %BANDDEFAULTS), @ADVPREFS) {
		$params->{'prefs'}->{$key} = $prefs->get($key);
	 }

	 my $chosen = $prefs->get('customTags');
	 $params->{'tagchosen'} = [ grep { $ok{$_} } (ref $chosen eq 'ARRAY' ? @$chosen : ()) ];
	 $params->{'tagfields'} = [ map { { id => $_->{'id'}, label => Slim::Utils::Strings::string($_->{'label'}) } } @offered ];

	 return $class->SUPER::handler( $client, $params );
}

1;
