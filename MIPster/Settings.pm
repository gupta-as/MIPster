# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file

# THE MAIN SETTINGS PAGE. Everything here is server-wide. The per-player controls are on MIP Controls
# and in the player menu; there is no player settings page at all.
#
# The three statistics blocks and the four Auto Sleep times used to be per player. They are server
# values now - one set, one page - and only the Auto Sleep on/off switch stayed with the player.
# The export controls are NOT here; they are on the Exports page with the bands they write.

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
	sqlitetimeout
	mipDelay
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
	 return Slim::Utils::Strings::string('PLUGIN_MIPSTER_SUBPAGE_MAIN');
}

sub pages {
	 return [{ 'name' => Slim::Utils::Strings::string('PLUGIN_MIPSTER_SUBPAGE_MAIN'), 'page' => page() }];
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
	 }

	 foreach my $pref (@MAINPREFS) {
		$params->{'prefs'}->{$pref} = $prefs->get($pref);
	 }

	 return $class->SUPER::handler( $client, $params );
}

1;
