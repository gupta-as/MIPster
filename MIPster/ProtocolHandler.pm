# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file

package Plugins::MIPster::ProtocolHandler;

use strict;
use warnings;
use Plugins::MIPster::Plugin;
use Slim::Utils::Log;
my $log = logger('plugin.mipster');

sub overridePlayback {
	my ($class, $client, $url) = @_;

	if ($url !~ m|^mipster:(.*)$|) {
		return undef;
	}
	$log->debug("ProtocolHandler; Firing");
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1, \&Plugins::MIPster::Plugin::AlarmFired, $client);
	return 1;
}

sub canDirectStream { 0 }

sub contentType { return 'mipster'; }

sub isRemote { 0 }

sub getIcon { return Plugins::MIPster::Plugin->_pluginDataFor('icon'); }

1;
