# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file

# THE BASIC SETTINGS PAGE, the one Lyrion opens first (install.xml optionsURL). Everything here is server-wide. The per-player controls are on MIP Controls
# and in the player menu; there is no player settings page at all.
#
# The three statistics blocks and the four Auto Sleep times used to be per player. They are server
# values now - one set, one page - and only the Auto Sleep on/off switch stayed with the player.
# The export controls are here; the bands they write are on the Advanced page (SettingsExports.pm).

package Plugins::MIPster::Settings;

use strict;
use warnings;
use base qw(Plugins::MIPster::SettingsBase);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings;
use Slim::Utils::OSDetect;

my $prefs = preferences('plugin.mipster');
my $log = logger('plugin.mipster');

# ONE LIST, read by the save and by the load. A control in only one of the two can save but never
# display, silently - the fault this list exists to prevent.
my @MAINPREFS = qw(
	mipHost
	mipPort
	localmediapath
	nasconvertpath
	blockSinceExport
	blockPlaycount
	blockRating
	blockLastplayed
	sleepFrom
	sleepTo
	sleepDuration
	sleepVolumeDrop
);

sub new {
	 my ($class, $plugin) = @_;
	 $class->SUPER::new($plugin, 1);
}

sub name {
	 return Slim::Web::HTTP::CSRF->protectName('PLUGIN_MIPSTER');
}

sub page {
	 return Slim::Web::HTTP::CSRF->protectURI('plugins/MIPster/settings/settings.html');
}

sub currentPage {
	 return Slim::Utils::Strings::string('PLUGIN_MIPSTER_SUBPAGE_BASIC');
}

sub pages {
	 return [{ 'name' => Slim::Utils::Strings::string('PLUGIN_MIPSTER_SUBPAGE_BASIC'), 'page' => page() }];
}

sub handler {
	 my ( $class, $client, $params ) = @_;

	 if ( $params->{'saveSettings'} ) {
		foreach my $pref (@MAINPREFS) {
			next unless defined $params->{$pref};
			my $value = $params->{$pref};
			$value =~ s/^\s+|\s+$//g;
			$prefs->set( $pref, "$value" );
		}

		# The time may be saved empty, and empty is the off switch for the daily export. Do not
		# refuse a blank value or substitute a default - that would remove the only way to turn
		# it off. A value that is not a time is refused by the pref's own validator.
		my $exporttime = $params->{'exportTime'};
		if (defined $exporttime) {
			$exporttime =~ s/^\s+|\s+$//g;
			$prefs->set( 'exportTime', "$exporttime" );
		}
		$prefs->set( 'exportPostscan', $params->{'exportPostscan'} ? 1 : 0 );
	 }

	 # Export Now is never gated by the two automatic controls above.
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

	 foreach my $pref (@MAINPREFS, 'exportTime', 'exportPostscan') {
		$params->{'prefs'}->{$pref} = $prefs->get($pref);
	 }

	 return $class->SUPER::handler( $client, $params );
}

sub beforeRender {
	my ($class, $params) = @_;

	$params->{'squeezebox_server_jsondatareq'} = '/jsonrpc.js';
	$params->{'scactivelmsscan'} = 1 if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning);
	$params->{'scactivemipexport'} = 1 if $prefs->get('exportInprogress');
}

1;
