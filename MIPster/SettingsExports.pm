# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file

# THE EXPORTS PAGE. The export controls and the rating bands the export writes, on one page, with one
# Save. The bands are validated AS A SET - each must start higher than the one before - and a set that
# fails refuses the whole page, the export time included. That is deliberate: a half-saved page is
# worse than a refused one, and the user asked for all-or-nothing here.

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

sub name {
	 return Slim::Web::HTTP::CSRF->protectName('PLUGIN_MIPSTER_SUBPAGE_EXPORTS');
}

sub page {
	 return Slim::Web::HTTP::CSRF->protectURI('plugins/MIPster/settings/exports.html');
}

sub currentPage {
	 return Slim::Utils::Strings::string('PLUGIN_MIPSTER_SUBPAGE_EXPORTS');
}

sub pages {
	 return [{ 'name' => Slim::Utils::Strings::string('PLUGIN_MIPSTER_SUBPAGE_EXPORTS'), 'page' => page() }];
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

			# The time may be saved empty, and empty is the off switch for the daily export. Do not
			# refuse a blank value or substitute a default - that would remove the only way to turn
			# it off.
			my $exporttime = $params->{'exportTime'};
			if (defined $exporttime) {
				$exporttime =~ s/^\s+|\s+$//g;
				$prefs->set( 'exportTime', "$exporttime" );
			}
			$prefs->set( 'exportPostscan', $params->{'exportPostscan'} ? 1 : 0 );

		} else {
			$log->error("MusicIP rating bands refused ($why) - each band must start higher than the "
				. "one before it. NOTHING on this page was saved.\n");
			$params->{'scbandserror'} = 1;
		}
	 }

	 # Export Now is never gated by the two automatic controls above; it is pressable the moment this
	 # build is installed, on the STOCK bands rather than this user's values, and an export on them
	 # rewrites most of the library on the wrong scale. That is why the bands are on this page.
	 if ( $params->{'scexportnow'} ) {
		if ( $prefs->get('exportInprogress') ) {
			$log->warn("Export Now ignored - a MusicIP export is already running\n");
		} else {
			$log->info("Export Now pressed - starting a MusicIP export\n");
			Slim::Utils::Scheduler::add_task( \&Plugins::MIPster::Plugin::scMIPExportRun );
		}
	 } elsif ( $params->{'scexportabort'} ) {
		Plugins::MIPster::Plugin::scMIPExportAbort();
	 }

	 foreach my $key (keys %BANDDEFAULTS) {
		$params->{'prefs'}->{$key} = $prefs->get($key);
	 }
	 $params->{'prefs'}->{'exportTime'} = $prefs->get('exportTime');
	 $params->{'prefs'}->{'exportPostscan'} = $prefs->get('exportPostscan');

	 return $class->SUPER::handler( $client, $params );
}

sub beforeRender {
	my ($class, $params) = @_;

	$params->{'squeezebox_server_jsondatareq'} = '/jsonrpc.js';
	$params->{'scactivelmsscan'} = 1 if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning);
	$params->{'scactivemipexport'} = 1 if $prefs->get('exportInprogress');
}

1;
