# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file

package Plugins::MIPster::Plugin;

use strict;
use warnings;
use base qw(Slim::Plugin::Base);
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.mipster',
	'defaultLevel' => 'WARN',
	'description' => getDisplayName(),
});

use Slim::Utils::Strings qw(string);
use Slim::Control::Request;
use Slim::Utils::OSDetect;
use Plugins::MIPster::SettingsBase;
use Plugins::MIPster::Settings;
use Plugins::MIPster::SettingsExports;
use Plugins::MIPster::MipLists;
use Plugins::MIPster::PowerSearch;
use Plugins::MIPster::Breakout;
use Plugins::MIPster::ProtocolHandler;
use Scalar::Util qw(blessed);
use Slim::Utils::Timers;
use URI::Escape;
use LWP::UserAgent;
use Slim::Utils::Scheduler;
use Slim::Utils::DateTime;
use Slim::Music::Import;
my @unique = ();
my @myworkingset = ();
my $prefs = preferences('plugin.mipster');
my $htmlTemplateLV = 'plugins/MIPster/settings/liveview.html';
my $htmlQuickSettings = 'plugins/MIPster/settings/quicksettings.html';
my $htmlPowerSearch  = 'plugins/MIPster/settings/powersearch.html';
my $global_quickmix = 0; # if quick fire mix from currently playing selected
my %mixstatus; # Holds status of MusicIP service, keyed by player - Filter and Recipe are
my $apc_enabled;
my $material_enabled;

sub getDisplayName { return 'PLUGIN_MIPSTER'; }

my %clientDefaults = (
	chainStatus     => 0,   # off - never hijack a player that was just plugged in
	chainSize       => 20,  # trim depth, not a length: only the top survivor is queued
	chainFilter     => 0,   # (None)
	chainRecipe     => 0,   # (None)
	chainRejectsize => 0,
	chainStyle      => 20,
	chainVariety    => 0,

	sleepStatus     => 0,
);

# ONE PARAMETER SET. A batch uses the same six values the Chain does; there is no second copy to
# remember, and no page on which the two could disagree. The Auto Sleep TIMES are server-wide and
# live in %serverDefaults - only the on/off switch is per player.
my %serverDefaults = (
	blockSinceExport => 1,   # Block. The only value that is not zero.
	blockPlaycount   => 0,
	blockRating      => 0,   # LMS's own 0-100 scale
	blockLastplayed  => 0,

	sleepFrom        => 0,
	sleepTo          => 0,
	sleepDuration    => 0,
	sleepVolumeDrop  => 0,   # points off a 0-100 scale at each track change. 0 = leave alone
);

sub applyClientDefaults {
	my $client = shift;
	return unless $client;

	$prefs->client($client)->init(\%clientDefaults);
}

sub scNewClientCallback {
	my $request = shift;
	my $client = $request->client() || return;
	applyClientDefaults ($client);
}

sub initPlugin {
	my $class = shift;
	my $client = shift;
	$class->SUPER::initPlugin();

	Plugins::MIPster::Settings->new;
	Plugins::MIPster::SettingsExports->new;

	$prefs->init(\%serverDefaults);

	Plugins::MIPster::Breakout::init();

	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	if (!defined $sqlitetimeout || $sqlitetimeout eq '') {
		$sqlitetimeout = 30;
		$prefs->set ('sqlitetimeout', "$sqlitetimeout");
		$log->debug("Sqlitetimeout, default to 30secs\n");
	}

	my $mipPort = $prefs->get('mipPort');
	if (!defined $mipPort || $mipPort eq '') {
		$mipPort = '10002';
		$prefs->set ('mipPort', "$mipPort");
		$log->debug("MIPster Port not Set; $mipPort for this client, default set to 10002\n");
	}
	my $mipHost = $prefs->get('mipHost');
	if (!defined $mipHost || $mipHost eq '') {
		$mipHost = 'localhost';
		$prefs->set ('mipHost', "$mipHost");
		$log->debug("MIPster MIP URL not Set; $mipHost for this client, default set to localhost\n");
	}
	my $mipDelay = $prefs->get('mipDelay');
	if (!defined $mipDelay || $mipDelay !~ /^\d+$/ || $mipDelay < 1) {
		$mipDelay = 1;
		$prefs->set ('mipDelay', "$mipDelay");
		$log->debug("Pause before Next Fetch was unset or below the floor - set to 1\n");
	}

	Slim::Control::Request::subscribe (\&commandCallback,
		[ [ 'play', 'pause', 'stop', 'power', 'playlist' ] ]);

	scMIPExportInitPrefs();
	Slim::Control::Request::subscribe (\&scMIPExportPostScanCB, [ [ 'rescan' ], [ 'done' ] ]);
	Slim::Control::Request::subscribe (\&scMIPExportScanRequestCB, [ [ 'rescan' ] ]);

	Slim::Control::Request::subscribe (
		\&Plugins::MIPster::Breakout::scForgetNameCache, [ [ 'rescan' ], [ 'done' ] ]);

	Slim::Control::Request::subscribe (\&scNewClientCallback,
		[ [ 'client' ], [ 'new', 'reconnect' ] ]);
	my $icon = Plugins::MIPster::Plugin->_pluginDataFor('icon');

	my @menu = (
		{
			text => Slim::Utils::Strings::string('PLUGIN_MIPSTER'),
			id => 'pluginFoobarActivateSomething',
			'icon-id' => $icon,
			weight => 20,
			actions => {
				go => {
					player => 0,
					cmd => [ 'mipster', 'menu' ],
					params => { activate => '1', },
				}
			},
			window => {
				titleStyle => 'settings',
				'icon-id' => $class->_pluginDataFor('icon')
			},
		},
	);
	Slim::Control::Jive::registerPluginMenu (\@menu, 'settings');

	Slim::Control::Request::addDispatch(['mipster', 'menu'], [0, 0, 1, \&jiveMIPsterMenu]);
	Slim::Control::Request::addDispatch(['mipster', 'setting'], [1, 0, 1, \&jiveMIPsterSetting]);
	Slim::Control::Request::addDispatch(['mipster', 'filters', '_filter'], [1, 0, 0, \&jive_menu_save_filter]);
	Slim::Control::Request::addDispatch(['mipster', 'recipe', '_recipe'], [1, 0, 0, \&jive_menu_save_recipe]);
	Slim::Control::Request::addDispatch(['mipster', 'mood', '_mood' ], [1, 0, 0, \&jive_menu_save_mood]);
	Slim::Control::Request::addDispatch(['mipster', 'batch', '_seedtype', '_idtype', '_id', '_mode'], [1, 0, 0, \&jiveSCBatch]);
	Slim::Control::Request::addDispatch(['mipster', 'replacesel', '_trackid'], [1, 0, 0, \&scReplaceSelection]);

	Slim::Menu::TrackInfo->registerInfoProvider(
		scbatchsong => (
			before => 'playitem',
			func => \&scBatchSongMenu,
		)
	);

	Slim::Menu::TrackInfo->registerInfoProvider(
		scbatchalbum => (
			after => 'scbatchsong',
			func => \&scBatchAlbumMenu,
		)
	);

	Slim::Menu::AlbumInfo->registerInfoProvider(
		scbatchalbum => (
			before => 'playitem',
			func => \&scBatchAlbumMenuFromAlbum,
		)
	);

	Slim::Player::ProtocolHandlers->registerHandler(
		mipster => 'Plugins::MIPster::ProtocolHandler');

	getAlarmPlaylists();

}

sub postinitPlugin {
	my $class = shift;

	$apc_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::AlternativePlayCount::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Alternative Play Count" is enabled') if $apc_enabled;

	$material_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Material Skin" is enabled') if $material_enabled;

	# Armed unconditionally, even mid-scan. Arming only when LMS happens not to be scanning is the bug
	# both source plugins carry: start the server during a scan and the export is never armed for that
	# whole run. The scheduler books its own next wake and sleeps through a scan. Do not put the condition back.
	Slim::Utils::Timers::setTimer(undef, time() + 2, \&scMIPExportScheduler);

	# LMS calls postinitPlugin only on the main module, so Breakout's own copy runs only because it is
	# called here. Without this its APC flag stays undef and Live View's two panels show LMS play counts
	# while the candidate list below shows APC's.
	Plugins::MIPster::Breakout->postinitPlugin();

	# Switching the Chain on asks for the next track at once. Without this a player paused or stopped
	# on its last track stays silent: the chain only ever asks on a song change, and resuming the same
	# track is not one. kickoff does nothing unless the player is on its last track, so this is always
	# safe. A synced player asks through its master, the one Lyrion reports song changes against.
	# DSTM is no longer switched off from here - see disableDSTM.
	$prefs->setChange(sub {
		my ($pref, $new, $client) = @_;
		return unless blessed($client);
		return unless $new;
		kickoff(Slim::Player::Sync::isSlave($client) ? $client->master : $client);
	}, 'chainStatus');

	foreach my $client (Slim::Player::Client::clients()) {
		applyClientDefaults ($client);
	}

}

sub scBatchSongMenu {
	my ($client, $url, $obj, $remoteMeta, $tags, $objectType) = @_;
	return scBatchMenuItem ($client, $obj, 'song', 'track', 'PLUGIN_MIPSTER_BATCH_SONG', $tags || {});
}

sub scBatchAlbumMenu {
	my ($client, $url, $obj, $remoteMeta, $tags, $objectType) = @_;
	return scBatchMenuItem ($client, $obj, 'album', 'track', 'PLUGIN_MIPSTER_BATCH_ALBUM', $tags || {});
}

sub scBatchAlbumMenuFromAlbum {
	my ($client, $url, $obj, $remoteMeta, $tags, $objectType) = @_;
	return scBatchMenuItem ($client, $obj, 'album', 'album', 'PLUGIN_MIPSTER_BATCH_ALBUM', $tags || {});
}

sub scBatchMenuItem {
	my ($client, $obj, $seedtype, $idtype, $stringtoken, $tags) = @_;
	return unless $client;
	return unless $obj && ref($obj) && $obj->can('id');

	return unless length scBatchSeedUrl ($idtype, $obj->id);

	if (!$tags->{menuMode}) {
		return {
			type => 'text',
			name => $client->string($stringtoken),
			scseedtype => $seedtype,
			scidtype => $idtype,
			scobjid => $obj->id,
			scadd => $client->string('PLUGIN_MIPSTER_BATCH_ADD'),
			web => {
				'type' => 'htmltemplate',
				'value' => 'plugins/MIPster/HTML/scbatchlink.html',
			},
		};
	}

	my $playaction = {
		player => 0,
		cmd => [ 'mipster', 'batch', $seedtype, $idtype, $obj->id, 'play' ],
		params => { menu => 1 },
		nextWindow => 'nowPlaying',
	};

	my $addaction = {
		player => 0,
		cmd => [ 'mipster', 'batch', $seedtype, $idtype, $obj->id, 'add' ],
		params => { menu => 1 },
		nextWindow => 'parent',
	};

	return {
		type => 'playlist',
		name => $client->string($stringtoken),
		favorites => 0,
		jive => {
			actions => {
				go => $playaction,
				play => $playaction,
				add => $addaction,
				'add-hold' => $addaction,
			},
			nextWindow => 'nowPlaying',
		},
	};
}

sub scBatchWeb {
	my ($client, $params, $callback, $httpClient, $response) = @_;

	my $seedtype = $params->{'seedtype'} || 'song';
	my $idtype = $params->{'idtype'} || 'track';
	my $id = $params->{'id'};
	my $mode = ($params->{'mode'} && $params->{'mode'} eq 'add') ? 'add' : 'play';

	if (defined $client && defined $id && length $id) {
		PlaySCBatch ($client, $seedtype, $idtype, $id, $mode);
		$params->{'scbatchdone'} = 1;
		$params->{'scbatchmsg'} = Slim::Utils::Strings::string($mode eq 'add'
			? 'PLUGIN_MIPSTER_BATCH_ADDING'
			: 'PLUGIN_MIPSTER_BATCH_STARTING');
	} else {
		$log->error("SC Batch from the web with no player or no id - nothing done\n");
	}

	return Slim::Web::HTTP::filltemplatefile
		('plugins/MIPster/HTML/scbatchdone.html', $params);
}

sub scBatchSeedUrl {
	my ($idtype, $id) = @_;
	return '' unless defined $id && length $id;

	my $track;
	if ($idtype eq 'album') {
		my $album = Slim::Schema->rs('Album')->find($id);
		return '' unless $album;
		$track = $album->tracks->first;
	} else {
		$track = Slim::Schema->rs('Track')->find($id);
	}
	return '' unless $track;

	my $trackurl = $track->url;
	return '' unless defined $trackurl && length $trackurl;
	return '' if Slim::Music::Info::isRemoteURL($trackurl);

	return $trackurl;
}

sub jiveSCBatch {
	my $request = shift;
	my $client = $request->client();

	if (!defined $client) {
		$request->setStatusNeedsClient();
		return;
	}

	my $seedtype = $request->getParam('_seedtype') || 'song';
	my $idtype = $request->getParam('_idtype') || 'track';
	my $id = $request->getParam('_id');
	my $mode = $request->getParam('_mode') || 'play';

	PlaySCBatch ($client, $seedtype, $idtype, $id, $mode);

	$request->setStatusDone();
}

sub PlaySCBatch {
	my ($client, $seedtype, $idtype, $id, $mode) = @_;
	$mode = 'play' unless defined $mode && $mode eq 'add';

	my $seedurl = '';
	if ($seedtype eq 'mood') {
		Plugins::MIPster::MipLists::ensureSeedMood ($client);
	} else {
		$seedurl = scBatchSeedUrl ($idtype, $id);
		if (!length $seedurl) {
			$log->error("SC Batch asked for but no seedable path found for $idtype id;"
				. (defined $id ? $id : 'undef') . "\n");
			return;
		}
	}

	$log->debug("SC Batch; mode=$mode seedtype=$seedtype seed=$seedurl\n");

	my $mypageurl = buildMIPReq ($client, $seedurl,
		{ seedtype => $seedtype, constraints => 'batch' });

	if (!defined $mypageurl) {
		$log->error("SC Batch; no request could be built - queue left alone\n");
		return;
	}

	if ($mode ne 'add') {
		my $request = $client->execute ([ 'playlist', 'clear' ]);
		$request->source('PLUGIN_MIPSTER');
	} else {
		if (Plugins::MIPster::Breakout::CheckPosition($client) == 2) {
			my $songIndex = Slim::Player::Source::streamingSongIndex($client) + 1;
			my $request = $client->execute ([ 'playlist', 'delete', $songIndex ]);
			$request->source('PLUGIN_MIPSTER');
			$log->debug("SC Batch Add - dropped the one track queued ahead; it came from the "
				. "continuous settings, not from this batch\n");
		}
	}

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&gotMIP,
		\&gotErrorViaHTTP,
		{
			caller => ($mode eq 'add') ? 'SCBatchAdd' : 'SCBatch',
			callerProc => \&PlaySCBatch,
			client => $client,
			timeout => 60
		}
	);
	$http->get($mypageurl);
}

# THE PLAYER MENU - iPeng and the hardware players. Material does NOT show this menu: it lists only
# items registered under the node 'settingsPlayer', and this one is registered under 'settings'.
# Material's MIPster surface is the Controls page, in Extras.
#
# THE STOPS AND THE COMMANDS ARE BUILT FROM ONE LIST. In 0.9.2 each picker carried its labels and its
# commands as two hand-written lists side by side, which is an invitation for the fifth label to fire
# the fourth command. scJiveChoice writes both from the same numbers, so they cannot drift.
# Order here is the order on screen and is the user's; it is NOT the Controls page order, deliberately.
sub scJiveChoice {
	my ($label, $pref, $current, @stops) = @_;

	my $index = 1;
	for my $i (0 .. $#stops) {
		$index = $i + 1 if $stops[$i] eq "$current";
	}

	return {
		text          => Slim::Utils::Strings::string($label),
		selectedIndex => $index,
		choiceStrings => [ @stops ],
		actions       => {
			do => {
				choices => [ map { { player => 0,
					cmd => [ 'mipster', 'setting', "$pref:$_" ] } } @stops ],
			},
		},
	};
}

# The nearest stop below the stored value. A pref set from the Controls slider can sit between two
# menu stops; without this the picker would show the first stop whatever the value was.
sub scJiveNearest {
	my ($value, @stops) = @_;
	my $best = $stops[0];
	for my $stop (@stops) {
		$best = $stop if $stop <= $value;
	}
	return $best;
}

sub jiveMIPsterMenu {
	no warnings 'numeric';

	$log->debug("jiveMIPsterMenu\n");
	my $request = shift;
	my $client = $request->client();

	if (!defined $client) {
		$request->setStatusNeedsClient();
		return;
	}

	my $cprefs = $prefs->client($client);
	my @sizestops    = qw(20 40 60 80 100);
	my @stylestops   = qw(0 20 40 60 80 100 120 140 160 180 200);
	my @varietystops = qw(0 1 2 3 4 5 6 7 8 9);
	# Reject Size runs to 10, matching the slider on Controls. The two lists must not drift.
	my @rejectstops  = qw(0 1 2 3 4 5 6 7 8 9 10);

	my $onoff = [ ucfirst (Slim::Utils::Strings::string('OFF')),
		      ucfirst (Slim::Utils::Strings::string('ON')) ];

	my @menuItems = (
		{
			text    => Slim::Utils::Strings::string('PLUGIN_MIPSTER_JIVE_FILTER'),
			actions => { go => { player => 0,
				cmd => [ 'mipster', 'setting', 'filterList:0' ] } },
		},
		{
			text    => Slim::Utils::Strings::string('PLUGIN_MIPSTER_JIVE_RECIPE'),
			actions => { go => { player => 0,
				cmd => [ 'mipster', 'setting', 'recipeList:0' ] } },
		},
		{
			text       => Slim::Utils::Strings::string('PLUGIN_MIPSTER_KICKOFF'),
			nextWindow => 'refresh',
			actions    => { do => { player => 0,
				cmd => [ 'mipster', 'setting', 'startChain:0' ] } },
		},
		{
			text       => Slim::Utils::Strings::string('PLUGIN_MIPSTER_WEB_QS_CHANGENEXT'),
			nextWindow => 'refresh',
			actions    => { do => { player => 0,
				cmd => [ 'mipster', 'setting', 'changeNext:0' ] } },
		},
		{
			text    => Slim::Utils::Strings::string('PLUGIN_MIPSTER_WEB_SEEDMOOD'),
			actions => { go => { player => 0,
				cmd => [ 'mipster', 'setting', 'moodList:0' ] } },
		},
		{
			text       => Slim::Utils::Strings::string('PLUGIN_MIPSTER_WEB_QS_MOODPLAY'),
			nextWindow => 'refresh',
			actions    => { do => { player => 0,
				cmd => [ 'mipster', 'batch', 'mood', 'none', 0, 'play' ] } },
		},
		scJiveChoice('PLUGIN_MIPSTER_JIVE_SIZE', 'chainSize',
			scJiveNearest($cprefs->get('chainSize') // 20, @sizestops), @sizestops),
		scJiveChoice('PLUGIN_MIPSTER_JIVE_MIXSTYLE', 'chainStyle',
			scJiveNearest($cprefs->get('chainStyle') // 20, @stylestops), @stylestops),
		scJiveChoice('PLUGIN_MIPSTER_JIVE_VARIETY', 'chainVariety',
			$cprefs->get('chainVariety') // 0, @varietystops),
		scJiveChoice('PLUGIN_MIPSTER_JIVE_SPACING', 'chainRejectsize',
			$cprefs->get('chainRejectsize') // 0, @rejectstops),
		{
			text          => Slim::Utils::Strings::string('PLUGIN_MIPSTER_JIVE_SLEEP'),
			choiceStrings => $onoff,
			selectedIndex => ($cprefs->get('sleepStatus') || 0) + 1,
			actions       => { do => { choices => [
				{ player => 0, cmd => [ 'mipster', 'setting', 'sleepStatus:0' ] },
				{ player => 0, cmd => [ 'mipster', 'setting', 'sleepStatus:1' ] },
			] } },
		},
		{
			text          => Slim::Utils::Strings::string('PLUGIN_MIPSTER_JIVE_STATUS'),
			choiceStrings => $onoff,
			selectedIndex => ($cprefs->get('chainStatus') || 0) + 1,
			actions       => { do => { choices => [
				{ player => 0, cmd => [ 'mipster', 'setting', 'chainStatus:0' ] },
				{ player => 0, cmd => [ 'mipster', 'setting', 'chainStatus:1' ] },
			] } },
		},
	);

	my $cnt = 0;
	foreach my $item (@menuItems) {
		$request->setResultLoopHash ('item_loop', $cnt, $item);
		$cnt++;
	}
	$request->addResult ('offset', 0);
	$request->addResult ('count', scalar(@menuItems));
	$request->setStatusDone();
}

sub scJivePicker {
	my ($request, $client, $listhash, $active, $verb) = @_;

	$active = '' unless defined $active;

	my @menu = ();
	# SORTED ON THE TEXT, not the stored key. '(None)' is stored as 0 and '(Power Search)' as
	# __MIPSTER_PS__, and neither would land where it is read if the key decided the order.
	foreach my $key (sort { lc($listhash->{$a}) cmp lc($listhash->{$b}) } keys %$listhash) {
		my $entry = $listhash->{$key};
		push @menu,
		 {
			id => $entry,
			text => $entry,
			radio => ($entry eq $active ? 1 : 0),
			actions => {
				do => {
					player => 0,
					cmd => [ 'mipster', $verb, $entry ],
				},
			},
		 };
	}

	$request->addResult ("base", { window => { titleStyle => 'noidea' } });
	$request->addResult ("count", scalar(@menu));
	$request->addResult ("offset", 0);
	my $cnt = 0;
	for my $eachPreset (@menu) {
		$request->setResultLoopHash ('item_loop', $cnt, $eachPreset);
		$cnt++;
	}

	$request->setStatusDone();

	Slim::Control::Jive::sliceAndShip ($request, $client, \@menu);
}

sub filter_filter {
	$log->debug("Filter_filter\n");
	my $request = shift;
	my $client = $request->client();

	scJivePicker ($request, $client,
		Plugins::MIPster::MipLists::getFilterList($client),
		$prefs->client($client)->get('chainFilter'),
		'filters');
}

sub recipe_filter {
	$log->debug("recipe_filter\n");
	my $request = shift;
	my $client = $request->client();

	scJivePicker ($request, $client,
		Plugins::MIPster::MipLists::getReceipesList($client),
		$prefs->client($client)->get('chainRecipe'),
		'recipe');
}

sub mood_filter {
	$log->debug("mood_filter\n");
	my $request = shift;
	my $client = $request->client();

	scJivePicker ($request, $client,
		Plugins::MIPster::MipLists::getMoodsList($client),
		Plugins::MIPster::MipLists::ensureSeedMood ($client),
		'mood');
}

sub mixfromplaying {
	my $request = shift;
	my $whocalled = shift;
	my $client;

	no warnings 'numeric';

	if ($whocalled eq "yes")
	{ # if yes then came from web page otherwise came from player
		$client = $request;
	} else {
		$client = $request->client();
	}

	AutoStartMix($client);

}

sub scJiveSave {
	my ($request, $param, $prefkey, $applynow) = @_;

	my $client = $request->client();
	if (!defined $client) {
		$request->setStatusNeedsClient();
		return;
	}

	if (defined($request->getParam($param))) {
		$log->debug("Param $param\n");
		my $new = $request->getParam($param);
		my $was = $prefs->client($client)->get($prefkey);
		my $changed = (!defined $was || $was ne $new);
		$prefs->client($client)->set($prefkey, $new);
		scApplyRequestChange ($client, $changed) if $applynow;
	}

	$request->setStatusDone();
}

sub jive_menu_save_filter {
	my $request = shift;
	return scJiveSave ($request, '_filter', 'chainFilter', 1);
}

sub jive_menu_save_recipe {
	my $request = shift;
	return scJiveSave ($request, '_recipe', 'chainRecipe', 1);
}

sub jive_menu_save_mood {
	my $request = shift;
	return scJiveSave ($request, '_mood', 'mood', 0);
}

sub jiveMIPsterSetting {
	no warnings 'numeric';

	my $request = shift;
	my $client = $request->client();

	if (!defined $client) { $request->setStatusNeedsClient(); return; }

	if (defined($request->getParam('filterList'))) {
		filter_filter($request);
	}
	if (defined($request->getParam('recipeList'))) {
		recipe_filter($request);
	}
	if (defined($request->getParam('moodList'))) {
		mood_filter($request);
	}
	if (defined($request->getParam('startChain'))) {
		AutoStartMix($client);
	}

	# CHANGE NEXT from the iPeng menu. Same call as the button on Controls, and like it, not gated
	# on chainStatus - it does one thing once.
	if (defined($request->getParam('changeNext'))) {
		MIPsterReplaceNext($client);
	}

	if (defined($request->getParam('sleepStatus'))) {
		$prefs->client($client)->set('sleepStatus', $request->getParam('sleepStatus'));
	}
	if (defined($request->getParam('chainStatus'))) {
		$prefs->client($client)->set('chainStatus', $request->getParam('chainStatus'));
	}
	if (defined($request->getParam('chainStyle'))) {
		$prefs->client($client)->set('chainStyle', $request->getParam('chainStyle'));
	}
	if (defined($request->getParam('chainVariety'))) {
		$prefs->client($client)->set('chainVariety', $request->getParam('chainVariety'));
	}
	if (defined($request->getParam('chainSize'))) {
		$prefs->client($client)->set('chainSize', $request->getParam('chainSize'));
	}
	if (defined($request->getParam('chainRejectsize'))) {
		my $new = $request->getParam('chainRejectsize');
		my $was = $prefs->client($client)->get('chainRejectsize');
		my $changed = (!defined $was || $was ne $new);
		$prefs->client($client)->set('chainRejectsize', $new);
		scApplyRequestChange ($client, $changed);
	}
	$request->setStatusDone();
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe (\&commandCallback);
}

sub MIPsterReplaceNext {
	no warnings 'numeric';

	my $client = shift;

	# Never on a queue the chain did not build: with more than one track ahead (a Batch or an Album)
	# the delete went through and nothing came back.
	return if (Plugins::MIPster::Breakout::CheckPosition($client) > 2);

	my $request;
	my $songIndex = Slim::Player::Source::streamingSongIndex($client);
	$songIndex++;
	my $listlength = Slim::Player::Playlist::count($client);
	if ($listlength == 1 || $listlength == 0 || $listlength == $songIndex) {
	} else {
		$request = $client->execute ([ 'playlist', 'delete', $songIndex ]);
	}
	kickoff($client);
}

sub scPathPair {
	my $lmspath = $prefs->get('localmediapath') // '';
	my $mippath = $prefs->get('nasconvertpath') // '';

	return () unless length $mippath; # MusicIP sees what LMS sees - nothing to convert

	if (!length $lmspath) {
		my $dirs = preferences('server')->get('mediadirs');
		$lmspath = (ref $dirs eq 'ARRAY' && @$dirs) ? $dirs->[0] : '';
	}

	return () unless length $lmspath;
	return () if $lmspath eq $mippath; # identical - nothing to convert

	return ($lmspath, $mippath);
}

# The one conversion out to MusicIP - Erland Isaksson's, ported from TrackStat as he wrote it.
# Start from the address Lyrion STORED, swap the root, force forward slashes, then un-escape and
# escape once. The address is NEVER decoded into letters and re-encoded. Do not improve it.
sub scMIPPath {
	my $url = shift;
	return '' unless defined $url && length $url;

	my ($lmspath, $mippath) = scPathPair();

	if (defined $lmspath) {
		my $miproot = $mippath;
		$miproot =~ s{\\}{/}g;
		$miproot = URI::Escape::uri_escape_utf8($miproot);

		my $lmsroot = Slim::Utils::Misc::fileURLFromPath($lmspath);
		$lmsroot = '' unless defined $lmsroot;
		$lmsroot =~ s{\\}{/}g;

		if (length $lmsroot && $url =~ /\Q$lmsroot\E/i) {
			$url =~ s{\\}{/}g;
			$url =~ s/\Q$lmsroot\E/$miproot/ig;
		} else {
			$url = Slim::Utils::Misc::pathFromFileURL($url);
		}
	} else {
		$url = Slim::Utils::Misc::pathFromFileURL($url);
	}

	return '' unless defined $url && length $url;

	$url =~ s{\\}{/}g;
	$url = scUnescape($url);

	return URI::Escape::uri_escape($url);
}

# The one conversion back in, also Erland's. MusicIP answers raw, so there is nothing to un-escape.
# Two repairs exist here that do not exist going out, and the asymmetry is deliberate: outbound a
# mistake is refused, inbound it is silent - the track simply is not found.
sub scLMSUrl {
	my $address = shift;
	return '' unless defined $address && length $address;

	$address = Slim::Utils::Unicode::utf8decode($address, 'utf8');
	$address =~ s/^\s+//;
	$address =~ s/\s+$//;
	return '' unless length $address;

	my ($lmspath, $mippath) = scPathPair();

	if (defined $lmspath) {
		my $miproot = $mippath;
		$address =~ s{\\}{/}g;
		$miproot =~ s{\\}{/}g;
		$address =~ s/\Q$miproot\E/$lmspath/ig;
	}

	my $url = Slim::Utils::Misc::fileURLFromPath($address);
	return '' unless defined $url && length $url;

	$url =~ s{\\}{/}g;

	return $url;
}

sub scUnescape {
	my $in = shift;
	return '' unless defined $in;

	$in =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;

	return $in;
}

sub scReplaceSelection {
	my $request = shift;
	my $client = $request->client();
	return unless $client;

	my $trackid = $request->getParam('_trackid');
	if (!defined($trackid) || $trackid eq '') {
		$log->warn("Use as Next Track called with no track\n");
		$request->addResult ('scmsg', $client->string('PLUGIN_MIPSTER_LV_NOTRACK'));
		$request->setStatusDone();
		return;
	}

	my $track = Slim::Schema->find('Track', $trackid);
	if (!blessed($track) || !$track->url) {
		$log->warn("Use as Next Track - no track found for id $trackid\n");
		$request->addResult ('scmsg', $client->string('PLUGIN_MIPSTER_LV_NOTINLIBRARY'));
		$request->setStatusDone();
		return;
	}

	my $ahead = Plugins::MIPster::Breakout::CheckPosition($client);
	if ($ahead > 2) {
		$log->info("Use as Next Track ignored - $ahead tracks queued. MIPster only replaces a "
			. "queue of its own making\n");
		$request->addResult ('scmsg', $client->string('PLUGIN_MIPSTER_LV_TOOMANY'));
		$request->setStatusDone();
		return;
	}

	my $songIndex = Slim::Player::Source::streamingSongIndex($client);
	$songIndex++;
	my $listlength = Slim::Player::Playlist::count($client);
	if (!($listlength == 1 || $listlength == 0 || $listlength == $songIndex)) {
		my $del = $client->execute ([ 'playlist', 'delete', $songIndex ]);
		$del->source('PLUGIN_MIPSTER');
	}

	addtrack ($client, $track->url);
	$log->info("Use as Next Track - queued '" . $track->title . "' by hand\n");

	$request->setStatusDone();
	return;
}

sub scApplyRequestChange {
	no warnings 'numeric';

	my ($client, $changed) = @_;
	return '' unless ($client && $changed);

	if (Slim::Player::Playlist::count($client) == 0) {
		mixfromplaying ($client, "yes");
		return 'started';
	}

	my $ahead = Plugins::MIPster::Breakout::CheckPosition($client);
	if ($ahead > 2) {
		$log->debug("Request setting changed, but $ahead tracks are queued - MIPster only "
			. "replaces a queue of its own making. Leaving it alone\n");
		return '';
	}

	MIPsterReplaceNext ($client);
	return 'replaced';
}

sub kickoff {
	no warnings 'numeric';

	my $client = shift;
	return unless $client; # Catch when client has disappeared
	my $song;

	my $quicksong = Slim::Player::Playlist::url($client) || '';;

	if (Slim::Music::Info::isRemoteURL($quicksong) == 1) {
		return;
	}

	if ($quicksong =~ m/^napster:/i
		|| $quicksong =~ m/.pls/i
		|| $quicksong =~ m/http:/i
		|| $quicksong =~ m/.asx/i
		|| $quicksong =~ m/rtmp:/i
		|| $quicksong =~ m/^lfm:/i
		|| $quicksong =~ m/^pandora:/i
		|| $quicksong =~ m/^slacker:/i
		|| $quicksong =~ m/^live365:/i
		|| $quicksong =~ m/^mediafly:/i
		|| $quicksong =~ m/^mog:/i
		|| $quicksong =~ m/https:/i
		|| $quicksong =~ m/^deezer:/i
		|| $quicksong =~ m/^spotify:/i
		|| $quicksong =~ m/^rhapd:/i
		|| $quicksong =~ m/^classical:/i
		|| $quicksong =~ m/^loop:/i)
	{ # Check whether we are streaming if so abort
		return;
	}

	if (!defined($song)) { $song = Slim::Player::Playlist::url($client); }

	if ($song =~ m/^tmp:/i) {
		my $z = substr $song, 0, 3, "file"; # replaces tmp with file
	}

	# The seed is handed over as Lyrion stored it. Turning it into a path here was the decoding step
	# the Erland port exists to remove.
	my $untouchedtrack = $song;

	my $scposition = Plugins::MIPster::Breakout::CheckPosition($client); # If we dont require a track exit the routine

	if ($scposition != 1) {
		return;
	}

	my $mypageurl = buildMIPReq ($client, $untouchedtrack);

	if (!defined $mypageurl) {
		return;
	}

	my $diditwork = SendtoMIPAsync ($client, $mypageurl);
}

sub gotMIP {
	no warnings 'numeric';

	my $http = shift;
	my $params = $http->params();
	my $client = $params->{'client'};
	my ($element, $song, $track, $changeindex, $temptrack);
	my @quickone;
	my $content = $http->content();
	my @miparray = split (/\n/, $content);

	$log->debug("\n#### MusicIP Responded with ####\n$content\n");

	$mixstatus{$client->id} = ''; # Reset MIP Status for this player

	my $creator = $params->{'caller'}; # CHECK WHETHER ASYNC WAS FROM QUICK MIX

	$global_quickmix = 0;

	$changeindex = 0;

	foreach (@miparray) {
		$element = scLMSUrl ($miparray[$changeindex]);
		push (@unique, $element);
		$changeindex++;
	}

	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $table = $apc_enabled ? 'alternativeplaycount' : 'tracks_persistent';

	my $lasttouched = $apc_enabled
		? "MAX(ifnull(alternativeplaycount.lastPlayed, 0), ifnull(alternativeplaycount.lastSkipped, 0))"
		: "tracks_persistent.lastPlayed";

	my $query = "SELECT tracks.url, tracks.title, albums.title, group_concat(DISTINCT genres.name), contributors.name, $table.playCount, tracks_persistent.rating, $lasttouched, tracks.coverid, tracks.album, tracks.id, albums.year, tracks_persistent.lastPlayed FROM contributors, tracks INNER JOIN genre_track ON (genre_track.track = tracks.id) INNER JOIN tracks_persistent ON (tracks.urlmd5 = tracks_persistent.urlmd5)";
	$query .= " left join alternativeplaycount on tracks.urlmd5 = alternativeplaycount.urlmd5" if ($apc_enabled);
	$query .= " INNER JOIN genres ON (genre_track.genre = genres.id) INNER JOIN albums ON (tracks.album = albums.id) INNER JOIN contributor_track ON tracks.id = contributor_track.track AND contributor_track.contributor = contributors.id AND contributor_track.role in (1,6) WHERE tracks.url IN (";

	my $sth;
	if (scalar @unique) {
		$query .= (join ',', ('?') x scalar(@unique))
		 . ") group by tracks.url"; # one row per track even when a track carries several genres
		$sth = $dbh->prepare($query);
		$sth->execute(@unique);
	}

	if ($sth) {
		while (my @results = $sth->fetchrow_array()) {
			push @quickone, $results[0], $results[1], $results[2], $results[3],
			 $results[4], $results[5], $results[6], $results[7], $results[8],
			 $results[9], $results[10], $results[11], $results[12]; # [11] = year, added 2026-08-09
		}
	}
	if (!$sth || $sth->rows == 0) {
		$log->debug("Failed to obtain LMS metadata from database\n\n"); # Need to do something probably :)
	}

	my %mip_order;
	for my $idx (0 .. $#unique) { $mip_order{$unique[$idx]} //= $idx; }
	my @groups;
	for (my $i = 0; $i < scalar(@quickone); $i += 13) {
		push @groups, [@quickone[$i .. $i+12]];
	}
	@groups = sort { ($mip_order{$a->[0]} // 9999) <=> ($mip_order{$b->[0]} // 9999) } @groups;
	@quickone = map { @$_ } @groups;

	Plugins::MIPster::Breakout::myworkingset ($client, @quickone); # Save all our stuff

	Plugins::MIPster::Breakout::DropSeed($client);

	Plugins::MIPster::Breakout::DropInQueue($client);

	Plugins::MIPster::Breakout::DropSinceExport($client);

	Plugins::MIPster::Breakout::droptsmetrics($client);

	# MusicIP's acoustic ranking is preserved and never re-sorted. The blocks filter it; nothing reorders it.
	$log->debug("Stats blocks applied; keeping MIP order\n");
	@myworkingset = Plugins::MIPster::Breakout::mystuff($client);

	my $isbatch = (($creator || '') eq 'SCBatch' || ($creator || '') eq 'SCBatchAdd');
	if ($isbatch) {
		my $arraysize = scalar $#myworkingset + 1;

		if ($arraysize != 0) {
			my $stack_size = $arraysize / 10;
			for (my $i = 0 ; $i < $stack_size ; $i++) {
				$log->debug("SC Batch; queueing; $myworkingset[$i*10]\n");
				addtrack ($client, $myworkingset[ $i * 10 ]); # song is hashed up
			}
		} else {
			$log->error("SC BATCH GOT NO TRACKS - MusicIP returned nothing for the batch Filter and Recipe\n");
			gotErrorContinue ($client, $http, 'empty');
		}

	} else {

		{
			$song = $myworkingset[0] // '';

			if (length($song) == 0) {
				$log->debug("All tracks blocked; falling back to the best MusicIP track\n");
				@myworkingset = Plugins::MIPster::Breakout::blockedfallback($client);
				$song = $myworkingset[0] // '';

				if (length($song) != 0) {
					$log->warn("SC BLOCK BREACHED - every track MusicIP offered was blocked; "
						. "playing its best one anyway\n");

					scTellUser ($client, $client->string('PLUGIN_MIPSTER_POPUP_BREACHED'));
				}
			}

			if (length($song) == 0) {
				$log->error("MUSICIP RETURNED NOTHING - the Filter and Recipe found no tracks\n");
				$mixstatus{$client->id} = 'MusicIP returned nothing. Check Filter/Recipe';
				scTellUser ($client, $client->string('PLUGIN_MIPSTER_POPUP_NOTRACKS'), 'error');

				# Never invent a track. MusicIP answered with nothing, so the Filter or Recipe found nothing.
				# Queuing nothing and an explicit stop were both tried and both failed - do not propose either again.
				# The alarm is the one exception: silence is a failed alarm, the failure you cannot notice in time.
				if ( (($params->{'caller'} // '') eq 'SpiceflyAlarm') ) {
					$song = randompuller($client); # Assumes something is playing; fails harmlessly if not
					$log->debug("MIP returned nothing. ALARM - got Random Track instead;$song\n");
					if ( (length($song) == 0) || ($song eq 'FAILED')) {
						$log->debug("Track still not good have;$song .Getting RealRandom track to use\n");
						$song = Plugins::MIPster::Breakout::getRealRandom();
						$log->error("COMPLETELY RANDOM TRACK USED FOR ALARM - nothing from MusicIP, "
							. "and nothing playing to take a genre from\n");
					}
				} else {
					$song = Slim::Player::Playlist::url($client) // '';

					if ($song =~ m/^tmp:/i) {
						my $z = substr $song, 0, 3, "file";
					}

					if (length($song) != 0) {
						$log->error("MUSICIP EMPTY - repeating the current track as an audible warning\n");
					} else {
						$log->error("STOPPING - nothing queued, and nothing playing to repeat\n");
					}
				}
			} else {
				$log->debug("\nQueueing; $myworkingset[4] : $myworkingset[1]\n");
			}

			if (length($song) != 0) {
				$log->debug("Asking LMS to Queue Track;\n$song\n");
				$song = Slim::Schema->rs('Track')->objectForUrl($song);
			}
		}

		if (length($song) == 0) {
			$log->error("********* FAILED STOP - Nothing to work with, no track queued *********\n");
		} else {
			addtrack ($client, $song); # song is hashed up
		}
	}

	$#unique = -1;
	slideVolume($client); # decides for itself - Auto Sleep on, inside the hours, drop above 0
	sleepplayer($client);

	$creator = $params->{'caller'};

	if ($creator eq 'SpiceflyAlarm') {

		my $request = $client->execute ([ 'playlist', 'delete', 0 ]);
		$request->source('PLUGIN_MIPSTER');
		$request = $client->execute (['play']);
		$request->source('PLUGIN_MIPSTER');
		return 1; # Need to return 1 to stop being attacked by alarm calls
	}
	if ($creator eq 'SpiceflyAutoMix' || $creator eq 'SCBatch') {
		my $request = $client->execute (['play']);
		$request->source('PLUGIN_MIPSTER');
	}
}

sub randompuller {
	my $client = shift;

	my $song = Slim::Player::Playlist::url($client); # CHECK WHETHER ASYNC WAS FROM ALARM or AUTOMIX - IF SO THEN DONT SAVE CURRENT TRACK

	if (!defined($song) || $song eq 'mipster:track') { # Breakout if there is no currently playing track we can pull the genre from
		$song = "FAILED";
		$log->debug("\nNo Currently Playing Track to get Genre from\n");
		return $song;
	}
	$log->debug("\nLMS Reported Track Playing;\n$song\n");

	 (my $NEWSCgenre) = Plugins::MIPster::Breakout::getGenre ($client, $song);
	$log->debug("\nCurrently Playing; $song\n");
	$log->debug("\nCurrently Playing Genre; $NEWSCgenre\n");

	(
		my $SCTRACKURL,
		my $RNDArtist,
		my $RNDTrack
	) = Plugins::MIPster::Breakout::getRandom ($client, $NEWSCgenre);

	$log->error("RANDOM FALLBACK USED - not a MusicIP choice: $RNDTrack by $RNDArtist\n");

	return $SCTRACKURL;

}

sub delayNextFetch {
	my $client = shift;

	if (Slim::Player::Sync::isSlave($client)) {
		return;
	} else {
		kickoff($client);
	}
}

sub currentTrackArtist {
	my $client = shift;
	return '' unless $client;

	my $url = Slim::Player::Playlist::url($client) || '';
	return '' unless length $url;

	my $artist = '';
	eval {
		my $dbh = Slim::Schema->dbh;
		my $sth = $dbh->prepare (
			'SELECT contributors.name FROM contributors '
			. 'INNER JOIN contributor_track ON contributor_track.contributor = contributors.id '
			. 'INNER JOIN tracks ON tracks.id = contributor_track.track '
			. 'WHERE tracks.url = ? AND contributor_track.role IN (1,6) '
			. 'ORDER BY contributor_track.role DESC LIMIT 1'
		);
		$sth->execute ($url);
		($artist) = $sth->fetchrow_array;
		$sth->finish;
	};
	if ($@) {
		$log->warn("Could not read the track artist for $url;$@\n");
		return '';
	}
	$artist = '' unless defined $artist;
	$log->debug("Track artist for seeding;$artist\n");
	return $artist;
}

sub escapeFilterName {
	my $name = shift;
	my $myos = Slim::Utils::OSDetect::OS();
	if ($myos eq 'win' || $myos eq 'mac') {
		return URI::Escape::uri_escape($name);
	}
	return Slim::Utils::Misc::escape($name);
}

# THE ONE PLACE that decides whether a filter or recipe selection means "none". The stored value is
# the zero the pickers carry; the translated text is accepted too, so a hand-edited pref or an older
# page cannot slip a literal through. Both were tested in different places in 0.9.2 and disagreed.
sub scIsNone {
	my ($value, $client) = @_;
	return 1 unless defined $value && length $value;
	return 1 if $value eq '0';
	return 1 if $value eq sprintf('(%s)', Slim::Utils::Strings::string('NONE'));

	# POWER SEARCH FALLS BACK TO NONE when there is nothing usable behind it - no saved search, or a
	# host that cannot take an expression. Sending one to a host that ignores it would mix from the
	# whole library while the page still said the search was in force.
	if (Plugins::MIPster::PowerSearch::isPowerSearch($value)) {
		return defined Plugins::MIPster::PowerSearch::activeExpression($client) ? 0 : 1;
	}

	return 0;
}

sub buildMIPReq {

	my $client = shift;
	my $tracktitle = shift;
	my $opts = shift || {};

	my $seedtype = $opts->{'seedtype'};
	my $constraints = $opts->{'constraints'} || 'normal';

	$tracktitle = '' unless defined $tracktitle;

	$seedtype = 'song' unless defined $seedtype;

	my $seedname = ''; # the mood or artist name, when one of those is the seed

	if ($seedtype eq 'mood') {
		$seedname = $opts->{'seedname'};
		$seedname = $prefs->client($client)->get('mood')
			unless defined $seedname;
		$seedname = '' unless defined $seedname;

		if ($seedname eq '' || $seedname eq '0' || $seedname eq '(None)') {
			$log->error("Seed is Mood but no mood is set - building no request\n");
			return undef;
		}
	} elsif ($seedtype eq 'artist') {
		$seedname = $opts->{'seedname'};
		$seedname = currentTrackArtist ($client) unless defined $seedname;
		$seedname = '' unless defined $seedname;

		if (!length $seedname) {
			$log->error("Seed is Artist but the playing track has no artist - building no request\n");
			return undef;
		}
	}

	$tracktitle = '' unless ($seedtype eq 'song' || $seedtype eq 'album');

	$seedtype = 'none'
		if (($seedtype eq 'song' || $seedtype eq 'album') && !length $tracktitle);

	my $mipPort = $prefs->get('mipPort');
	my $mipHost = $prefs->get('mipHost');
	my $asksize = $prefs->client($client)->get('chainSize') // 20;

	if ($constraints eq 'batch') {
		$asksize = $prefs->client($client)->get('chainSize') // 20;
	}

	my $mypageurl;

	$log->debug("Seed address from Lyrion;$tracktitle\n") if length $tracktitle;

	$tracktitle = scMIPPath ($tracktitle);
	my $stylevalue = ($constraints eq 'batch')
		? ($prefs->client($client)->get('chainStyle') // 20)
		: $prefs->client($client)->get('chainStyle');
	my $varietyvalue = ($constraints eq 'batch')
		? ($prefs->client($client)->get('chainVariety') // 0)
		: $prefs->client($client)->get('chainVariety');

	my $chainStyle = '&style=' . $stylevalue;
	my $chainVariety = '&variety=' . $varietyvalue;

	my $seedparam = '';
	if ($seedtype eq 'album') {
		$seedparam = '&album%3d' . $tracktitle; # album= takes a full path to ANY song on it
	} elsif ($seedtype eq 'song') {
		$seedparam = '&song%3d' . $tracktitle;

		# Override Shuffle, triggered on a song= request and nowhere else. A song seed means the chain
		# re-seeds from the playing track, and LMS shuffle breaks that at both ends - it re-seeds from
		# something already heard, and the last-track test never comes true, so mixing simply stops.
		my $lmsshuffle = Slim::Player::Playlist::shuffle($client);
		if ($lmsshuffle == 1 || $lmsshuffle == 2) {
			$log->debug("Song seed sent; switching LMS shuffle off to protect the chain\n");
			$client->execute ([ "playlist", "shuffle", 0 ]);
		}
	} elsif ($seedtype eq 'mood') {
		$seedparam = '&mood=' . escapeFilterName ($seedname);
		$log->debug("Seeding from mood;$seedname\n");
	} elsif ($seedtype eq 'artist') {
		$seedparam = '&artist=' . escapeFilterName ($seedname);
		$log->debug("Seeding from artist;$seedname\n");
	} else {
		$log->debug("No seed - MIP will pick a random song from within the current filter\n");
	}

	$mypageurl = ( 'http://'
		 . $mipHost . ':'
		 . $mipPort
		 . '/api/mix?&sizetype=tracks&size='
		 . $asksize
		 . $seedparam
		 . $chainStyle
		 . $chainVariety);

	# ONE SET OF VALUES, whether this is the Chain or a batch, and ONE spelling of "no selection".
	# scIsNone is the only place that decides what counts as none; it takes both the stored zero and
	# the translated text, so a picker and a pref can no longer disagree.
	my $activefilter = $prefs->client($client)->get('chainFilter');
	if (scIsNone($activefilter, $client)) {
		$log->debug("Filter is set to NONE\n");
	} elsif (Plugins::MIPster::PowerSearch::isPowerSearch($activefilter)) {
		# MusicIP has ONE filter slot and the last one in the url wins, so the expression goes in
		# exactly where a named filter would. Never both - the dropdown has one selection.
		my $expr = Plugins::MIPster::PowerSearch::activeExpression($client);
		$mypageurl = $mypageurl . '&filter=' . Plugins::MIPster::PowerSearch::escapeExpression($expr);
		$log->debug("Filter is the saved Power Search;$expr\n");
	} else {
		$mypageurl = $mypageurl . '&filter=' . escapeFilterName($activefilter);
	}

	my $recipename = $prefs->client($client)->get('chainRecipe');
	if (scIsNone($recipename)) {
		$log->debug("Recipe is set to NONE\n");
	} else {
		$mypageurl = $mypageurl . '&recipe=' . escapeFilterName($recipename);
	}

	my $chainRejectsize = $prefs->client($client)->get('chainRejectsize') // 0;
	if ($chainRejectsize > 0) {
		$mypageurl = $mypageurl . '&rejectsize=' . $chainRejectsize . '&rejecttype=tracks';
	}

	$log->debug("\n#### Built URL Request for MusicIP:\n $mypageurl\n####\n");
	return $mypageurl;
}

sub scTellUser {
	my $client = shift;
	my $msg = shift;
	my $type = shift // 'info'; # 'info' or 'error' - Material accepts only those two

	return unless defined $client && defined $msg && length $msg;

	my $hasdisplay = $client->display && !$client->display->isa('Slim::Display::NoDisplay');

	if ($hasdisplay) {
		$client->showBriefly(
			{ 'line' => [ $client->string('PLUGIN_MIPSTER'), $msg ] },
			5
		);
	}

	$client->showBriefly(
		{
			'jive' => {
				'type' => 'popupplay',
				'text' => [ $client->string('PLUGIN_MIPSTER'), ' ', $msg ],
			}
		}
	);

	$log->debug("scTellUser; " . $client->id . " hasdisplay=" . ($hasdisplay ? 1 : 0)
		. " material=" . ($material_enabled ? 1 : 0) . "; $msg\n");

	# Always 'info' to Material, never 'error'. Material's showError takes the message as its SECOND
	# argument, so an error notification renders the timeout instead of the text. Its bug, not ours.
	if ($material_enabled) {
		my $who = Slim::Player::Client::name($client) // '';
		my $matmsg = length $who ? "$who: $msg" : $msg;
		Slim::Control::Request::executeRequest (undef,
			[ 'material-skin', 'send-notif', 'type:info', 'msg:' . $matmsg, 'timeout:5' ]);
	}
}

sub gotErrorViaHTTP {
	my $http = shift;
	my $params = $http->params();
	my $client = $params->{'client'};
	gotErrorContinue ($client, $http, 'unreachable');
}

sub gotErrorContinue {
	my $client = shift;
	my $http = shift;
	my $case = shift // 'unreachable';

	my $content = $http->content();

	my $why;
	if ($content eq 'API error - invalid request or internal error.') {
		$why = 'API error - invalid request or internal error';
	} elsif ($content eq '') {
		$why = 'no reply at all - check the MusicIP service is running';
	} else {
		$why = 'unrecognized reply';
	}

	if ($case eq 'empty') {
		$log->error("MUSICIP RETURNED NOTHING; $why\n");
		$mixstatus{$client->id} = 'MusicIP returned nothing. Check Filter/Recipe';
		scTellUser ($client, $client->string('PLUGIN_MIPSTER_POPUP_NOTRACKS'), 'error');
	} else {
		$log->error("MUSICIP COULD NOT BE REACHED; $why\n");
		$mixstatus{$client->id} = 'Cannot reach MusicIP. Check service/SC plugin settings';
		scTellUser ($client, $client->string('PLUGIN_MIPSTER_POPUP_NOMIP'), 'error');
	}

	my $errcreator = $http->params()->{'caller'} || '';

	if ($errcreator eq 'SCBatch') {
		$log->error("SC BATCH FAILED - the queue was cleared before the request, so there is nothing "
			. "to repeat; silence declares it\n");
		return;
	}

	if ($errcreator ne 'SpiceflyAlarm') {
		my $repeaturl = Slim::Player::Playlist::url($client) // '';

		if ($repeaturl =~ m/^tmp:/i) {
			my $z = substr $repeaturl, 0, 3, "file";
		}

		if (length($repeaturl) != 0) {
			$log->error("MUSICIP SILENT - repeating the current track as an audible warning\n");
			addtrack ($client, $repeaturl);
		} else {
			$log->error("STOPPING - nothing queued, and nothing playing to repeat\n");
		}
		return;
	}

	$log->debug("\nALARM with no MusicIP - requesting (from LMS db) a Random Track matching the Current Playing Tracks Genre\n");
	my $song = randompuller($client) // 'FAILED';
	if ($song eq 'FAILED') {
		$log->debug("\nFAILED, likely no playing track to use or track has no Genre\n");
		$log->error("COMPLETELY RANDOM TRACK USED - no MusicIP, and nothing playing to take a genre from\n");
		my $track = Plugins::MIPster::Breakout::getRealRandom();
		$log->debug("Selected Completely Random Track;\n$track\n");
		my ($CurrentArtist, $CurrentTrack) = Plugins::MIPster::Breakout::getTSSongDetails($track);

		$log->error("RANDOM FALLBACK USED - not a MusicIP choice: $CurrentTrack by $CurrentArtist\n");

		addtrack ($client, $track); # song is hashed up
		my $request = $client->execute (["play"]);

	} else { # Random Track selected was ok

		my $currentsong = Slim::Player::Playlist::url($client) // '';
		if (length($currentsong) != 0) {
			$log->debug("\nTrying to Queue Track;$song\n");

			addtrack ($client, $song); # song is hashed up
		} else {
			$log->debug("\nCould not use Playing Tracks Genre and LMS did not return anything usable\n");
			$log->debug("\n$song\n");
		}
	}

	if ($errcreator eq 'SpiceflyAlarm') {
		$log->error("ALARM WITH NO MUSICIP - clearing the alarm placeholder and playing the fallback track\n");
		my $request = $client->execute ([ 'playlist', 'delete', 0 ]);
		$request->source('PLUGIN_MIPSTER');
		$request = $client->execute (['play']);
		$request->source('PLUGIN_MIPSTER');
	}
}

sub SendtoMIPAsync {
	my $client = shift;
	my $mypageurl = shift;
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&gotMIP,
		\&gotErrorViaHTTP,
		{
			caller => 'Spicefly',
			callerProc => \&SendtoMIPAsync,
			client => $client,
			timeout => 60
		}
	);
	$http->get($mypageurl);
}

sub addtrack {
	my $client = shift;
	my $track = shift;
	if ($track ne "") {
		my $request = $client->execute ([ "playlist", "add", $track ]);
		$request->source('PLUGIN_MIPSTER');
	}
}

# The Chain counts for a sync group if it is on for any player in it. Lyrion reports song changes
# against the master only, so a Chain switched on from another player in the group would otherwise
# stop after one track.
sub scChainOn {
	my $client = shift;
	return 0 unless $client;
	foreach my $c ($client, $client->syncedWith) {
		return 1 if $prefs->client($c)->get('chainStatus');
	}
	return 0;
}

# Lyrion's DSTM asks this before it queues anything, because install.xml carries canConflictWithDSTM.
# A true answer makes DSTM skip that player. Read in Lyrion 9.1's DontStopTheMusic/Plugin.pm.
sub disableDSTM {
	my ($class, $client) = @_;
	return scChainOn($client) ? 1 : 0;
}

sub commandCallback {
	my $request = shift;
	my $client = $request->client();
	return unless $client; # Catch when client has disappeared
	my $checklive = $prefs->client($client)->get('chainStatus');
	if (!defined $checklive) {
		$checklive = 0;
		$prefs->client($client)->set( 'chainStatus', 0 );
		$log->debug("MIPster Prefs Not Set for this client, default to Disabled.\n");
	}

	return unless scChainOn($client);

	my $source = $request->source() || '';
	if ( ($source eq 'PLUGIN_MIPSTER')
		|| ($source eq 'ALARM'))
	{
		return 1;
	}

	if ($request->isCommand ([ ['playlist'], ['newsong'] ])) {

		# This pause is load-bearing, not a performance setting. kickoff queues a track only when you are
		# on the very last one; fire too early and LMS still reports the OLD position, so nothing is queued
		# and the next skip wraps you to the top of the queue. The floor of 1 is enforced in three places.
		my $mipDelay = $prefs->get('mipDelay');
		$mipDelay = 1 if (!defined $mipDelay || $mipDelay !~ /^\d+$/ || $mipDelay < 1);
		Slim::Utils::Timers::killTimers ($client, \&delayNextFetch);
		Slim::Utils::Timers::setTimer ($client,
			Time::HiRes::time() + $mipDelay,
			\&delayNextFetch);
	}
	if ($request->isCommand ([ ['stop'] ])) {
		$log->debug("We Stopped :(\n");
	}
	if ($request->isCommand ([ ['pause'] ])) {
		$log->debug("We Paused :(\n");
	}

}

sub inSleepWindow {
	my $client = shift;
	my $from = $prefs->get('sleepFrom') || 0;
	my $to   = $prefs->get('sleepTo') || 0;
	my ($sec, $min, $hour) = localtime(time);
	return ($from - $hour <= 0 && $to - $hour <= 0
		|| $from - $hour >= 0 && $to - $hour > 0) ? 1 : 0;
}

sub slideVolume {
	my $client = shift;

	my $sleepStatus = $prefs->client($client)->get('sleepStatus') || 0;
	return if $sleepStatus != 1;

	my $sleepVolumeDrop = $prefs->get('sleepVolumeDrop') || 0;
	return if $sleepVolumeDrop <= 0; # 0 is the off switch now that the tickbox has gone

	return unless inSleepWindow($client);

	my $volumeslide = Slim::Player::Client::volume($client);

	$volumeslide = $volumeslide - $sleepVolumeDrop;
	if ($volumeslide < 0) { $volumeslide = 0; }
	$log->debug("Auto Sleep - dropping volume by $sleepVolumeDrop to $volumeslide\n");
	$client->execute ([ "mixer", "volume", $volumeslide ]);
}

sub sleepplayer {
	my $client = shift;
	my $sleepStatus = $prefs->client($client)->get('sleepStatus') || 0;
	if ($sleepStatus == 1) {
		my $sleeper = $client->sleepTime();
		if ($sleeper == 0) {
			my $sleepDuration = $prefs->get('sleepDuration') || 0;
			if (inSleepWindow($client)) {
				$sleepDuration = $sleepDuration * 60;
				$client->execute ([ "sleep", $sleepDuration ]);
			}
		}
	}
}

sub dirtyencoder {
	my $mytitle = shift || '';

	return '' unless length $mytitle;

	$mytitle =~ s/\\/\//g;

	return Slim::Utils::Misc::fileURLFromPath($mytitle);
}

sub ToggleInjector {
	my ($client, $item) = @_;
	my $chainStatus;
	if ($item eq '{PLUGIN_MIPSTER_INJECTOR_ON}') {
		$chainStatus = 1;
	} else {
		$chainStatus = 0;
	}
	$prefs->client($client)->set ('chainStatus', "$chainStatus");
	$log->info("Chain set to $chainStatus for " . $client->name . "\n");
	return;
}

sub AutoStartMix {
	my ($client, $item) = @_;

	# Off means off. This is the only place a continuous mix is started and every surface passes through
	# here. The greyed button on the Controls page is not the rule and never was.
	if (!($prefs->client($client)->get('chainStatus') || 0)) {
		$log->info("Start New Chain refused - the Chain is off for this player\n");
		return;
	}

	my $request = $client->execute ([ 'playlist', 'clear' ]);
	$request->source('PLUGIN_MIPSTER');

	my $mypageurl = buildMIPReq ($client, '', { seedtype => 'none' });

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&gotMIP,
		\&gotErrorViaHTTP,
		{
			caller => 'SpiceflyAutoMix',
			callerProc => \&AutoStartMix,
			client => $client,
			timeout => 60
		}
	);
	$http->get($mypageurl);
}

sub ToggleSleep {
	my ($client, $item) = @_;
	my $sleepStatus;
	if ($item eq '{PLUGIN_MIPSTER_SLEEP_OFF}') {
		$sleepStatus = 0;
	} else {
		$sleepStatus = 1;
	}
	$prefs->client($client)->set ('sleepStatus', "$sleepStatus");
	$log->info("Auto Sleep set to $sleepStatus for " . $client->name . "\n");
	return;
}

sub getAlarmPlaylists {
	my $class = shift;
	Slim::Utils::Alarm->addPlaylists(
		'PLUGIN_MIPSTER',
		[
			{
				title => '{PLUGIN_MIPSTER_TRACK}',
				url => 'mipster:track'
			},
		]
	);
}

# THE ALARM SEEDS FROM THE QUEUE. Whatever is sitting in the player's queue is what the alarm mixes
# from; an empty queue falls through to a random seed inside the current filter, because buildMIPReq
# turns a song seed with no track into a seedless request by itself. A remote or streamed url is not a
# path MusicIP can take, so it is treated as no seed rather than sent and silently ignored.
# There are no alarm settings of any kind - this uses the player's own Chain values.
sub AlarmFired {
	my $client = shift;
	my $track;
	my $mypageurl;

	my $seed = Slim::Player::Playlist::url($client) || '';
	$seed = '' if (Slim::Music::Info::isRemoteURL($seed));
	if ($seed =~ m/^tmp:/i) {
		my $z = substr $seed, 0, 3, "file"; # replaces tmp with file
	}

	$log->debug("Alarm seeding from " . ($seed ne '' ? $seed : "nothing in the queue - random seed") . "\n");

	$mypageurl = buildMIPReq ($client, $seed);

	$log->debug("Alarm URL created; $mypageurl\n");

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&gotMIP,
		\&gotErrorViaHTTP,
		{
			caller => 'SpiceflyAlarm',
			callerProc => \&AlarmFired,
			client => $client,
			timeout => 60
		}
	);
	$http->get($mypageurl);
}

sub webPages {
	my $class = shift;
	my $urlBase = 'plugins/MIPster/settings';

	# LIVE VIEW AND CONTROLS ARE LISTED UNDER 'plugins', the list Lyrion's own plugins use. Classic
	# shows it in the plugins section of its home page; Material's Extras menu reads it too.
	# Classic's Extras lists entries in order of this internal name, not the name on screen, so Live
	# View's must sort after Controls' (PLUGIN_MIPSTERQS) for Controls to come first there.
	Slim::Web::Pages->addPageLinks ("plugins", { 'PLUGIN_MIPSTER_LIVEVIEW' => $htmlTemplateLV });
	Slim::Web::Pages->addPageLinks ("plugins", { 'PLUGIN_MIPSTERQS' => $htmlQuickSettings });

	Slim::Web::Pages->addPageLinks("icons", { 'PLUGIN_MIPSTER_LIVEVIEW' => 'plugins/MIPster/HTML/images/mipster.png' });
	Slim::Web::Pages->addPageFunction ("$urlBase/liveview.html", \&handleWebList);
	Slim::Web::HTTP::CSRF->protectURI("$urlBase/liveview.html");

	Slim::Web::Pages->addPageFunction ("$urlBase/quickplay.html", \&handleWebQP);
	Slim::Web::HTTP::CSRF->protectURI("$urlBase/quickplay.html");

	Slim::Web::Pages->addPageLinks( "icons", { 'PLUGIN_MIPSTERQS' => 'plugins/MIPster/HTML/images/mipster.png' });
	Slim::Web::Pages->addPageFunction ("$urlBase/quicksettings.html", \&handleWebQuickSettings);
	Slim::Web::HTTP::CSRF->protectURI("$urlBase/quicksettings.html");

	# NO PAGE LINK. Power Search is reached by the button on MIP Controls and nowhere else, so it
	# does not belong in the browse menus the way Controls and Live View do.
	Slim::Web::Pages->addPageFunction ("$urlBase/powersearch.html", \&handleWebPowerSearch);
	Slim::Web::HTTP::CSRF->protectURI("$urlBase/powersearch.html");

	Slim::Web::Pages->addPageFunction ("$urlBase/scbatch.html", \&scBatchWeb);
	Slim::Web::HTTP::CSRF->protectURI("$urlBase/scbatch.html");

	if (UNIVERSAL::can ("Slim::Plugin::Base", "addWeight")) {
		Slim::Plugin::Base->addWeight ("PLUGIN_MIPSTER_LIVEVIEW", 84);
		Slim::Plugin::Base->addWeight ("PLUGIN_MIPSTERQS", 83);
	}
}

sub handleWebQuickSettings {
	no warnings 'numeric';

	my ($client, $params) = @_;
	$client = Slim::Player::Client::getClient ($params->{player});
	return unless $client;

	my $replace = 0;

	foreach my $pref (qw(chainFilter chainRecipe chainRejectsize)) {
		next unless defined $params->{$pref};
		my $oldval = $prefs->client($client)->get($pref);
		$replace = 1 if (!defined $oldval || $oldval ne $params->{$pref});
		$prefs->client($client)->set($pref, $params->{$pref});
	}

	if (defined $params->{mood}) {
		$prefs->client($client)->set('mood', $params->{mood});
	}

	if (defined $params->{chainStatus}) {
		$prefs->client($client)->set('chainStatus', $params->{chainStatus});
	}

	if (defined $params->{sleepStatus}) {
		$prefs->client($client)->set('sleepStatus', $params->{sleepStatus});
	}

	foreach my $pref (qw(chainStyle chainVariety chainSize)) {
		next unless defined $params->{$pref};
		$prefs->client($client)->set($pref, $params->{$pref});
	}

	# AUTO-REPLACE IS FILTER, RECIPE AND REJECT SIZE ONLY, and only when the value actually changed.
	# Size, Style, Variety, Mood and the two toggles save quietly and take effect at the next fetch.
	# Replace Next Track as a button is gone from every surface; nothing here fires one on demand.

	Plugins::MIPster::MipLists::ensureSeedMood ($client);

	my $moodbatch = $params->{moodbatch} || '';
	if ($moodbatch eq 'play' || $moodbatch eq 'add') {
		PlaySCBatch ($client, 'mood', '', '', $moodbatch);
	}

	# COPY TO CHOSEN PLAYERS. Copies the mix values this player is holding to the players ticked on the
	# page (copyto = their ids, comma-separated), and stops there. Deliberately NOT copied: mood, chainStatus, sleepStatus -
	# each of those is a decision about that player, not a mix setting.
	# Nothing is replaced and no MusicIP call is made; the other players read their own prefs at
	# their next fetch, so the new values take effect one track later. Doing it any other way would
	# interrupt whatever the other rooms are playing.
	if ($params->{copyto}) {
		my %chosen = map { $_ => 1 } split /,/, $params->{copyto};
		my @mixprefs = qw(chainFilter chainRecipe chainSize chainStyle chainVariety chainRejectsize chainStatus);
		my %vals = map { $_ => $prefs->client($client)->get($_) } @mixprefs;

		# THE SEARCH TRAVELS WITH THE SELECTION. Copying a Power Search selection without the search
		# behind it would leave the other rooms showing Power Search and mixing from the whole
		# library, because scIsNone would find nothing saved and fall back to no filter.
		my $pssearch = Plugins::MIPster::PowerSearch::savedSearch($client);
		my $carryps = Plugins::MIPster::PowerSearch::isPowerSearch($vals{chainFilter}) && $pssearch;

		my $copied = 0;
		foreach my $other (Slim::Player::Client::clients()) {
			next unless blessed($other);
			next if ($other->id eq $client->id);
			next unless $chosen{$other->id};
			foreach my $pref (@mixprefs) {
				$prefs->client($other)->set($pref, $vals{$pref});
			}
			$prefs->client($other)->set('psSearch', $pssearch) if $carryps;
			$copied++;
		}
		$log->info("Copy to chosen players: mix settings from " . $client->name . " written to $copied other player(s)");
		$params->{copiedmsg} = $copied
			? sprintf (Slim::Utils::Strings::string('PLUGIN_MIPSTER_WEB_QS_COPIED'), $copied)
			: Slim::Utils::Strings::string('PLUGIN_MIPSTER_WEB_QS_COPIEDNONE');
	}

	if ($params->{forcestart} && !($prefs->client($client)->get('chainStatus') || 0)) {
		delete $params->{forcestart};
	}

	# CHANGE NEXT. Drops the queued next track and fetches a fresh one, and says so through Lyrion's
	# own notification at the moment it runs rather than on the page that comes back afterwards.
	# Deliberately NOT gated on chainStatus - it is finite, so it is a coherent request on a player
	# whose Chain is switched off.
	if ($params->{changenext}) {
		MIPsterReplaceNext ($client);
	}

	if ($params->{forcestart}) {
		mixfromplaying ($client, "yes");
	} elsif ($replace) {
		scApplyRequestChange ($client, 1);
	}

	# The collapsed group posts this with every change it contains, so the page comes back with the
	# group still open. Nothing else reads it and it is never stored.
	$params->{mixopen} = $params->{mixopen} ? 1 : 0;

	foreach my $pref (qw(chainFilter chainRecipe chainRejectsize
		chainStyle chainVariety chainSize mood chainStatus))
	{
		$params->{prefs}->{$pref} = $prefs->client($client)->get($pref);
	}

	# The players Copy can write to: every other player Lyrion knows, by name.
	$params->{otherplayers} = [ map { { id => $_->id, name => $_->name } }
		sort { lc($a->name) cmp lc($b->name) }
		grep { blessed($_) && $_->id ne $client->id } Slim::Player::Client::clients() ];

	$params->{filters} = Plugins::MIPster::MipLists::getFilterList($client);

	# THE FILTER DROPDOWN IS HANDED A LIST, NOT A HASH, and this is not a style choice.
	# Template Toolkit refuses to read any hash key that starts with an underscore, so looking up
	# '__MIPSTER_PS__' in a hash returns nothing at all and the entry draws as a blank line. Measured
	# on the live server. A list of key-and-label pairs has no such problem, because the stored
	# value is then ordinary data rather than the name of something.
	#
	# ORDER DECIDED HERE, ON THE TEXT. Sorting on the stored key put '(None)' first only by the
	# accident that it is stored as 0; '(Power Search)' would have landed among the user's own
	# filter names.
	my $filterhash = $params->{filters};
	$params->{filterlist} = [ map { { key => $_, label => $filterhash->{$_} } }
				  sort { lc($filterhash->{$a}) cmp lc($filterhash->{$b}) }
				  keys %$filterhash ];
	$params->{receipes} = Plugins::MIPster::MipLists::getReceipesList();
	$params->{moods} = Plugins::MIPster::MipLists::getMoodsList();

	return Slim::Web::HTTP::filltemplatefile ($htmlQuickSettings, $params);
}

# MIP POWER SEARCH. The page decides once, at the top, whether to draw the form at all: the
# capability question is asked fresh on every open, which costs one request a live host answered in
# 0.06 seconds. Outcomes 1 and 2 draw a red line where the form would have been, so a headless host
# can never be handed a search it would silently ignore.
#
# A SAVE THAT FAILS ITS YIELD TEST STORES NOTHING. The last passing search stays stored and stays in
# force, and the page comes back showing it - the typing that failed is discarded, by design.
sub handleWebPowerSearch {
	my ($client, $params) = @_;
	$client = Slim::Player::Client::getClient ($params->{player});
	return unless $client;

	$params->{pscap} = Plugins::MIPster::PowerSearch::hostCapability(1);
	$params->{playername} = $client->name;

	if ($params->{pscap} ne 'ok') {
		return Slim::Web::HTTP::filltemplatefile ($htmlPowerSearch, $params);
	}

	my $typed;   # what was sent, kept on screen when the save is refused

	if ($params->{pssave}) {
		my $search = Plugins::MIPster::PowerSearch::parseData ($params->{psdata});
		$typed = $search;
		my $bad = Plugins::MIPster::PowerSearch::badCharacter ($search);
		my $expr = Plugins::MIPster::PowerSearch::buildExpression ($search);

		if (defined $bad) {
			$params->{psmessage} = sprintf (Slim::Utils::Strings::string('PLUGIN_MIPSTER_PS_BADCHAR'), $bad);
		} elsif (!defined $expr) {
			$params->{psmessage} = Slim::Utils::Strings::string('PLUGIN_MIPSTER_PS_EMPTY');
		} else {
			my ($found, $how) = Plugins::MIPster::PowerSearch::yieldTest ($expr, $search->{min});
			if ($how ne 'ok') {
				$params->{psmessage} = Slim::Utils::Strings::string('PLUGIN_MIPSTER_PS_NOANSWER');
			} elsif ($found == 0) {
				$params->{psmessage} = Slim::Utils::Strings::string('PLUGIN_MIPSTER_PS_NOMATCH');
			} elsif ($found < $search->{min}) {
				$params->{psmessage} = sprintf (Slim::Utils::Strings::string('PLUGIN_MIPSTER_PS_SHORT'),
					$search->{min}, $found);
			} else {
				Plugins::MIPster::PowerSearch::saveSearch ($client, $search);
				$params->{psmessage} = Slim::Utils::Strings::string('PLUGIN_MIPSTER_PS_SAVED');
				$params->{psgood} = 1;
				$typed = undef;
				$log->info("Power Search saved for " . $client->name . ";$expr");
			}
		}
	}

	# WHAT THE PAGE COMES BACK SHOWING. A REFUSED SAVE KEEPS WHAT WAS TYPED, so one bad row can be
	# corrected instead of costing the whole search. Nothing was stored by it either way - the last
	# passing search is still the one in force, and it reappears on leaving the page and returning.
	# A save that passed, and a plain visit, both show what is stored.
	my $show = $typed || Plugins::MIPster::PowerSearch::savedSearch ($client);
	$params->{psdata} = $show ? Plugins::MIPster::PowerSearch::toData ($show) : '';
	$params->{psmin}   = $show ? $show->{min} : Plugins::MIPster::PowerSearch::minStart();
	$params->{psfloor} = Plugins::MIPster::PowerSearch::minFloor();
	$params->{psstart} = Plugins::MIPster::PowerSearch::minStart();

	my @fields;
	foreach my $f (@{ Plugins::MIPster::PowerSearch::fields() }) {
		my $hint = '';
		$hint = 'mm/dd/yyyy' if $f->{kind} eq 'date';
		$hint = 'yyyy' if $f->{id} eq 'year';
		$hint = '0-5'  if $f->{id} eq 'rating';
		push @fields, {
			id    => $f->{id},
			kind  => $f->{kind},
			hint  => $hint,
			label => Slim::Utils::Strings::string($f->{label}),
		};
	}
	$params->{psfields} = \@fields;

	return Slim::Web::HTTP::filltemplatefile ($htmlPowerSearch, $params);
}

sub handleWebQP {
	my ($client, $params) = @_;
	$client = Slim::Player::Client::getClient ($params->{player});
	if ($client) {
		mixfromplaying ($client, "yes");

		$params->{refresh} = 1;

		$params->{path} = $htmlTemplateLV;

		return handleWebList ($client, $params);
	}
}

sub scLVNoTrack {
	my $params = shift;

	$params->{'currentartist'} = "N/A";
	$params->{'currenttrack'} = "N/A";
	$params->{'currentalbum'} = "N/A";
	$params->{'currentgenre'} = "N/A";
	$params->{'currentalbumart'} = '0';
	$params->{'comingupnextartist'} = 'N/A';
	$params->{'comingupnexttrack'} = 'N/A';
	$params->{'comingupnextalbum'} = 'N/A';
	$params->{'comingupnextgenre'} = 'N/A';
	$params->{'comingupnextalbumart'} = '0';
	return;
}

sub handleWebList {
	my ($client, $params) = @_;
	$client = Slim::Player::Client::getClient ($params->{player});

	# Live View's refresh is its own and fixed. It used to read Lyrion's refreshRate, which is the
	# CLASSIC skin's page setting - so on a server where that is high the page sat half a minute behind
	# the queue it exists to show, for a reason nobody would think to look for.
	$params->{'refreshRate'} = 5 * 1000;

	$params->{'track'} = '';

	if ($client) {

		my $lvstamp = Plugins::MIPster::Breakout::scStampDate(
			$prefs->client($client)->get('mipLastCall') // 0);
		$params->{'mode'} = 'Last MIP Response' . (length $lvstamp ? ': ' . $lvstamp : '');

		my $master = Slim::Player::Sync::isMaster($client); # Returns 1 if true
		my $slave = Slim::Player::Sync::isSlave($client); # Returns 1 if true
		my $name = Slim::Player::Client::name($client);
		if ($master == 1) {
			$params->{'master'} = '';
		} elsif ($slave == 1) {
			my $sync_master = $client->master()->name();
			$params->{'master'} = sprintf(
				Slim::Utils::Strings::string('PLUGIN_MIPSTER_WEB_SYNCWARNING'), $name, $sync_master);
		} else {
			$params->{'master'} = '';
		}

		$params->{'mixstatus'} = $mixstatus{$client->id} // ''; # Error reporting, this player only
		$params->{refresh} = 1;

		$params->{'filters'} = Plugins::MIPster::Breakout::StatsPuller($client);

		# The two panels are gated on the track, not on a flag: drawn when Lyrion can describe what the
		# player is on. A stored 'mixInProgress' pref and a sentence used as a true/false switch are what
		# this replaced - do not put either back. The candidate table is deliberately NOT inside this gate.
		my $lvtrack = Slim::Player::Playlist::track($client);
		$params->{'track'} = ($lvtrack && ref $lvtrack && defined $lvtrack->title)
			? $lvtrack->title : '';
		my $lvnowurl = Slim::Player::Playlist::url($client) // '';
		my ($lvArtist, $lvTrack, $lvAlbum, $lvGenre, $lvArt, $lvFull, $lvPC, $lvRat, $lvLP);
		if (length $lvnowurl) {

			# Lyrion sometimes hands back a tmp: url for the playing track. pathFromFileURL refuses it, returns
			# nothing and logs a backtrace on every refresh, so both panels fall to N/A. Copied verbatim from
			# kickoff, which has guarded against this all along.
			if ($lvnowurl =~ m/^tmp:/i) {
				my $z = substr $lvnowurl, 0, 3, "file"; # replaces tmp with file
			}

			$lvnowurl = Slim::Utils::Misc::pathFromFileURL($lvnowurl);
			$lvnowurl = dirtyencoder($lvnowurl);
			($lvArtist, $lvTrack, $lvAlbum, $lvGenre, $lvArt, $lvFull, $lvPC, $lvRat, $lvLP)
				= Plugins::MIPster::Breakout::getTSSongDetails ($lvnowurl);
		}

		if (defined $lvTrack && $lvTrack ne '') {
			$params->{'showstats'} = "ON";
			$params->{'currentartist'} = $lvArtist;
			$params->{'currenttrack'} = $lvTrack;
			$params->{'currentalbum'} = $lvAlbum;
			$params->{'currentgenre'} = $lvGenre;
			$params->{'currentalbumart'} = $lvArt || '0';
			$params->{'currentpc'} = $lvPC;
			$params->{'currentrat'} = $lvRat;
			$params->{'currentlp'} = $lvLP;

			my ($nxArtist, $nxTrack, $nxAlbum, $nxGenre, $nxArt, $nxFull, $nxPC, $nxRat, $nxLP)
				= Plugins::MIPster::Breakout::getmyTSNextSong ($client);

			if (defined $nxTrack && $nxTrack ne '') {
				$params->{'comingupnextartist'} = $nxArtist;
				$params->{'comingupnexttrack'} = $nxTrack;
				$params->{'comingupnextalbum'} = $nxAlbum;
				$params->{'comingupnextgenre'} = $nxGenre;
				$params->{'comingupnextalbumart'} = $nxArt || '0';
				$params->{'comingupnextpc'} = $nxPC;
				$params->{'comingupnextrat'} = $nxRat;
				$params->{'comingupnextlp'} = $nxLP;
			} else {
				$params->{'comingupnextartist'} = 'Nothing queued';
				$params->{'comingupnexttrack'} = 'Nothing queued';
				$params->{'comingupnextalbum'} = '';
				$params->{'comingupnextgenre'} = '';
				$params->{'comingupnextalbumart'} = '0';
				$params->{'comingupnextpc'} = '';
				$params->{'comingupnextrat'} = '';
				$params->{'comingupnextlp'} = '';
			}
		} else {
			scLVNoTrack($params);
		}
	} else {
		scLVNoTrack($params);
	}

	return Slim::Web::HTTP::filltemplatefile ($htmlTemplateLV, $params);
}

my $scMIPExportLastCacheID = 0;
my $scMIPExportStartTime = 0;
my $scMIPExportAborted = 0;
my $scMIPExportErrors = 0;
my $scMIPExportFlushed = 0;
my @scMIPExportSongs = ();

sub scMIPExportInitPrefs {
	$prefs->init({
		exportTime => '',
		exportPostscan => 0,
		exportUnrated => 0,
		exportBand1 => 10,
		exportBand2 => 30,
		exportBand3 => 50,
		exportBand4 => 70,
		exportBand5 => 90,
		exportLastsuccess => 0,
		exportCacheid => 0,
		exportResult => 0,
		exportLastMessage => '',
	});

	# exportResult and exportLastMessage are NOT reset here. They hold how the last export ended and
	# when, and the Exports page shows them until the next export ends - across restarts too.
	$prefs->set('exportInprogress', 0);

	$prefs->setValidate({'validator' => \&scMIPExportIsTime}, 'exportTime');

	$prefs->setChange(sub {
		main::DEBUGLOG && $log->is_debug && $log->debug("MusicIP export pref changed - re-arming the scheduler\n");
		scMIPExportScheduler();
	}, 'exportTime', 'exportPostscan');
}

# The rating map: a table, evaluated highest band first. Unrated is a row, not a hidden pref - set
# it to 0 and unrated tracks are not exported, and the SQL scope below is derived from that one
# number rather than from a second switch that could disagree with it.
sub scMIPExportBand {
	my $rating = shift;

	$rating = 0 unless defined $rating && $rating =~ /^\d+(?:\.\d+)?$/;

	return ($prefs->get('exportUnrated') // 0) if $rating <= 0;

	return 5 if $rating >= ($prefs->get('exportBand5') // 90);
	return 4 if $rating >= ($prefs->get('exportBand4') // 70);
	return 3 if $rating >= ($prefs->get('exportBand3') // 50);
	return 2 if $rating >= ($prefs->get('exportBand2') // 30);
	return 1 if $rating >= ($prefs->get('exportBand1') // 10);
	return 0;
}

sub scMIPExportRun {
	if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		main::INFOLOG && $log->is_info && $log->info("Cannot export to MusicIP - an LMS scan is running\n");
		return;
	}

	@scMIPExportSongs = ();
	$scMIPExportStartTime = time();
	$prefs->set('exportInprogress', 1);
	$scMIPExportAborted = 0;
	$scMIPExportErrors = 0;
	$scMIPExportFlushed = 0;

	my ($mip_hostname, $mip_port, $mip_timeout) = scMIPExportTarget();

	my $http = LWP::UserAgent->new;
	$http->timeout($mip_timeout);
	my $testurl = "http://$mip_hostname:$mip_port/api/cacheid";
	my $response = $http->get($testurl);
	if (!$response->is_success) {
		$log->error("Failed to call MusicIP at $testurl - check the MusicIP Host Location and Port on the MIPster settings page, and that MusicIP is running and reachable from the server.\n");
		$scMIPExportErrors++;
	}

	unless ($scMIPExportErrors) {

		# APC's own lastPlayed, taken straight. NEVER MAX(lastPlayed, lastSkipped) - a skip is not a play
		# and must not reach MusicIP dressed as one, or MIP believes a track you keep rejecting is one you
		# keep choosing. The fallback to Lyrion's covers tracks played before APC was installed.
		my $lastplayed = $apc_enabled
			? 'ifnull(alternativeplaycount.lastPlayed, tracks_persistent.lastPlayed)'
			: 'tracks_persistent.lastPlayed';
		my $playcount = $apc_enabled ? 'alternativeplaycount.playCount' : 'tracks_persistent.playCount';

		my $sql = "SELECT tracks_persistent.url, $playcount, $lastplayed, tracks_persistent.rating";
		$sql .= " FROM tracks_persistent JOIN tracks ON tracks_persistent.urlmd5 = tracks.urlmd5";
		$sql .= " LEFT JOIN alternativeplaycount ON tracks.urlmd5 = alternativeplaycount.urlmd5" if $apc_enabled;
		$sql .= " WHERE ifnull(tracks.remote,0) = 0";
		$sql .= " AND ($lastplayed IS NOT NULL OR tracks_persistent.rating > 0)"
			unless ($prefs->get('exportUnrated') // 0) > 0;

		main::DEBUGLOG && $log->is_debug && $log->debug("MusicIP export SQL;$sql\n");

		my $dbh = Slim::Schema->dbh;
		my ($url, $playCount, $lastPlayed, $rating);
		eval {
			my $sth = $dbh->prepare($sql);
			$sth->execute();
			$sth->bind_columns(undef, \$url, \$playCount, \$lastPlayed, \$rating);
			while ($sth->fetch()) {
				push @scMIPExportSongs, {
					'url' => $url,
					'rating' => scMIPExportBand($rating),
					'playcount' => $playCount,
					'lastplayed' => $lastPlayed,
				};
			}
			$sth->finish();
		};
		if ($@) {
			$log->error("MusicIP export SQL error; $@\n");
			$scMIPExportErrors++;
		} else {
			main::INFOLOG && $log->is_info && $log->info("MusicIP export - ".scalar(@scMIPExportSongs)." tracks to send\n");
		}

		# A one-second pause every 30,000 tracks, so a player waiting for a track gets served. The plugin
		# is NOT deaf during an export - it hands Lyrion a full event-loop pass between every track. What
		# that cannot do is make MusicIP compute a mix while it works through this stream of writes, so the
		# pause stops sending. Do not rebuild the 'deaf' argument.
		my $sent = 0;
		foreach (@scMIPExportSongs) {
			scMIPExportTrack($_, $mip_hostname, $mip_port, $mip_timeout);
			last if $scMIPExportAborted;
			main::idleStreams();

			if (++$sent % 30000 == 0) {
				main::INFOLOG && $log->is_info && $log->info("MusicIP export - pausing one second after $sent tracks so a waiting player can be served\n");
				my $pauseuntil = Time::HiRes::time() + 1;
				while (Time::HiRes::time() < $pauseuntil) {
					main::idleStreams();
					last if $scMIPExportAborted;
					Time::HiRes::sleep(0.01);
				}
			}
		}

		scMIPExportFinish($mip_hostname, $mip_port, $mip_timeout) unless $scMIPExportAborted;
	}

	# THE OUTCOME KEPT FOR THE EXPORTS PAGE: a code for the colour (1 completed - green; 2 aborted,
	# 3 finished with errors, 4 failed - red) and the line itself, with the count and the end time.
	# 'Failed' means it never reached the cache flush, so MusicIP kept nothing and exportLastsuccess
	# was not stamped. Set once, here, at the end; nothing clears them.
	my $ended = Slim::Utils::DateTime::shortDateF(time()) . ' ' . Slim::Utils::DateTime::timeF(time());
	if ($scMIPExportAborted) {
		$prefs->set('exportResult', 2);
		$prefs->set('exportLastMessage', Slim::Utils::Strings::string('PLUGIN_MIPSTER_EXPORT_LAST_ABORTED', $ended));
	} elsif ($scMIPExportErrors > 0 && !$scMIPExportFlushed) {
		$prefs->set('exportResult', 4);
		$prefs->set('exportLastMessage', Slim::Utils::Strings::string('PLUGIN_MIPSTER_EXPORT_LAST_FAILED', $ended));
	} elsif ($scMIPExportErrors > 0) {
		$prefs->set('exportResult', 3);
		$prefs->set('exportLastMessage', Slim::Utils::Strings::string('PLUGIN_MIPSTER_EXPORT_LAST_ERRORS', $scMIPExportErrors, $ended));
	} else {
		$prefs->set('exportResult', 1);
		$prefs->set('exportLastMessage', Slim::Utils::Strings::string('PLUGIN_MIPSTER_EXPORT_LAST_DONE', $ended));
	}

	if ($scMIPExportAborted) {
		main::INFOLOG && $log->is_info && $log->info("MusicIP export aborted after ".(time() - $scMIPExportStartTime)." seconds\n");
	} elsif ($scMIPExportErrors > 0) {
		main::INFOLOG && $log->is_info && $log->info("MusicIP export finished with $scMIPExportErrors errors after ".(time() - $scMIPExportStartTime)." seconds\n");

		# A track MusicIP refuses is refused every night. A run that reached the flush counts for the
		# day, or the scheduler repeats it - and the flush - every 30 minutes. A failed flush still retries.
		$prefs->set('exportLastsuccess', $scMIPExportStartTime) if $scMIPExportFlushed;
	} else {
		main::INFOLOG && $log->is_info && $log->info("MusicIP export completed after ".(time() - $scMIPExportStartTime)." seconds\n");
		$prefs->set('exportCacheid', $scMIPExportLastCacheID);

		# The success marker (see also the errors branch above). Stamped with the time the export STARTED, not
		# finished: anything played during the run may or may not have made the query, so it falls after
		# the marker and stays blocked. Over-blocking is the safe direction.
		$prefs->set('exportLastsuccess', $scMIPExportStartTime);
	}

	@scMIPExportSongs = ();
	$prefs->set('exportInprogress', 0);
	$scMIPExportAborted = 0;
}

sub scMIPExportAbort {
	if ($prefs->get('exportInprogress')) {
		$scMIPExportAborted = 1;
		main::INFOLOG && $log->is_info && $log->info("Aborting the MusicIP export\n");
	}
}

sub scMIPExportTarget {
	my $host = $prefs->get('mipHost');
	my $port = $prefs->get('mipPort');
	my $timeout = preferences('server')->get('remotestreamtimeout') // 15;
	return ($host, $port, $timeout);
}

# The two failure branches must not collapse into one - 'MusicIP did not answer' and 'MusicIP
# answered and said no' are different faults with different causes. setRating is always sent,
# including 0: that is how MusicIP is told to REMOVE a rating, so a demotion propagates.
sub scMIPExportTrack {
	my ($track, $mip_hostname, $mip_port, $mip_timeout) = @_;

	my $url = $track->{'url'};
	if (!$url) {
		$log->warn("MusicIP export - a row came back with no url\n");
		$scMIPExportErrors++;
		return;
	}

	my $mippath = scMIPExportPath($url);
	if (!defined $mippath || !length $mippath) {
		$log->warn("MusicIP export - could not build a MusicIP path for $url\n");
		$scMIPExportErrors++;
		return;
	}

	my $http = LWP::UserAgent->new;
	$http->timeout($mip_timeout);

	my $rating = $track->{'rating'};
	my $playCount = $track->{'playcount'};
	my $lastPlayed = $track->{'lastplayed'};

	scMIPExportCall($http, "http://$mip_hostname:$mip_port/api/setRating?song=$mippath&rating=$rating", "Rating = $rating", $mippath);
	scMIPExportCall($http, "http://$mip_hostname:$mip_port/api/setPlayCount?song=$mippath&count=$playCount", "PlayCount = $playCount", $mippath) if $playCount;
	scMIPExportCall($http, "http://$mip_hostname:$mip_port/api/setLastPlayed?song=$mippath&time=$lastPlayed", "LastPlayed = $lastPlayed", $mippath) if $lastPlayed;
}

sub scMIPExportCall {
	my ($http, $callurl, $what, $mippath) = @_;

	my $response = $http->get($callurl);
	if (!$response->is_success) {
		$log->warn("MusicIP did not answer - could not set $what for $mippath\n");
		$scMIPExportErrors++;
		return;
	}

	my $result = $response->content;
	chomp $result if defined $result;
	if (defined $result && $result =~ /^\s*\d+\s*$/ && $result > 0) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Set $what for $mippath\n");
	} else {
		$log->warn("MusicIP answered but refused to set $what for $mippath\n");
		$scMIPExportErrors++;
	}
}

sub scMIPExportPath {
	my $url = shift;
	return undef unless defined $url && length $url;
	return undef if Slim::Music::Info::isRemoteURL($url);

	my $mippath = scMIPPath ($url);
	return undef unless defined $mippath && length $mippath;

	return $mippath;
}

sub scMIPExportFinish {
	my ($mip_hostname, $mip_port, $mip_timeout) = @_;

	my $http = LWP::UserAgent->new;
	$http->timeout($mip_timeout);

	my $response = $http->get("http://$mip_hostname:$mip_port/api/flush");
	if (!$response->is_success) {
		$log->warn("MusicIP did not answer the cache flush\n");
		$scMIPExportErrors++;
	} else {
		$scMIPExportFlushed = 1;
	}

	my $cacheurl = "http://$mip_hostname:$mip_port/api/cacheid";
	$response = $http->get($cacheurl);
	if ($response->is_success) {
		$scMIPExportLastCacheID = $response->content;
		chomp $scMIPExportLastCacheID if defined $scMIPExportLastCacheID;
	} else {
		$log->warn("MusicIP did not answer at $cacheurl\n");
		$scMIPExportErrors++;
	}
}

# The next wake is booked on the first line, before any decision is taken. Off means wake, look, do
# nothing, sleep - never stop waking, which would leave the export dead until LMS restarts. Do not
# move the setTimer down or add a return above it. The gate is the time field itself; blank is off.
sub scMIPExportScheduler {
	Slim::Utils::Timers::killTimers(undef, \&scMIPExportScheduler);

	Slim::Utils::Timers::setTimer(undef, time() + 1800, \&scMIPExportScheduler);

	my $exporttime = $prefs->get('exportTime');
	return unless defined($exporttime) && $exporttime ne '';

	if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		main::INFOLOG && $log->is_info && $log->info("MusicIP export scheduler - LMS is scanning, trying again in 30 minutes\n");
		return;
	}

	if ($prefs->get('exportInprogress')) {
		main::INFOLOG && $log->is_info && $log->info("MusicIP export already running - scheduler will retry in 30 minutes\n");
		return;
	}

	my $time = 0;
	if ($exporttime =~ m{^(0?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$}i) {
		if (defined $3) {
			$time = ($1 == 12 ? 0 : $1 * 3600) + ($2 * 60) + ($3 =~ /P/i ? 43200 : 0);
		} else {
			$time = ($1 * 3600) + ($2 * 60);
		}
	} else {
		$log->warn("MusicIP export - the stored export time '$exporttime' is not a time. The time validator may be missing; the nightly export cannot run until this is fixed.\n");
		return;
	}

	my ($sec, $min, $hour, $mday) = (localtime(time()))[0, 1, 2, 3];
	my $currenttime = $hour * 3600 + $min * 60;

	return unless $currenttime > $time;

	my $lastsuccess = $prefs->get('exportLastsuccess') || 0;
	if ($lastsuccess) {
		my @last = localtime($lastsuccess);
		my @now  = localtime(time());
		return if $last[3] == $mday && $last[4] == $now[4] && $last[5] == $now[5];
	}

	main::INFOLOG && $log->is_info && $log->info("Starting the scheduled MusicIP export\n");
	eval { Slim::Utils::Scheduler::add_task(\&scMIPExportRun); };
	$log->error("Scheduled MusicIP export failed to start; $@\n") if $@;
}

# Gated on exportPostscan and nothing else, and gated HERE rather than at the subscription -
# subscribing unconditionally and not reading the pref is how a post-scan export runs when the
# setting says No. It runs even if the nightly already ran today: a scan is the one event that
# changes what there is to export.
# WHAT KIND OF SCAN WAS ASKED FOR. Lyrion's 'rescan done' does not say, but the request that
# starts a scan does: 'rescan playlists' carries the mode 'playlists'; every other rescan (the
# settings page, 'rescan' with no mode, the 02:00 script's full scan) counts as full. Read in
# Lyrion 9.1 Slim/Control/Commands.pm rescanCommand. The 'rescan done' notice and the '?' query
# reach this subscription too and are ignored. Decided on in scMIPExportPostScanDelayed.
my $scScanSawFull = 0;
my $scScanSawPlaylists = 0;

sub scMIPExportScanRequestCB {
	my $request = shift;
	return if $request->isCommand([['rescan'], ['done']]);
	return unless $request->isCommand([['rescan']]);

	my $mode = $request->getParam('_mode');
	$mode = '' unless defined $mode;
	if ($mode eq 'playlists') {
		$scScanSawPlaylists = 1;
	} else {
		$scScanSawFull = 1;
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("Rescan requested, mode '$mode'\n");
}

sub scMIPExportPostScanCB {
	return unless $prefs->get('exportPostscan');

	Slim::Utils::Timers::killOneTimer(undef, \&scMIPExportPostScanDelayed);
	Slim::Utils::Timers::setTimer(undef, time() + 10, \&scMIPExportPostScanDelayed);
}

sub scMIPExportPostScanDelayed {
	return unless $prefs->get('exportPostscan');

	if (Slim::Music::Import->stillScanning) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Still scanning - waiting before the post-scan MusicIP export\n");
		Slim::Utils::Timers::setTimer(undef, time() + 10, \&scMIPExportPostScanDelayed);
		return;
	}

	# A PLAYLIST-ONLY RESCAN DOES NOT EXPORT. It changes no song, so the export after it only resent
	# what the export after the full scan had just sent. Skipped only when every scan asked for since
	# the last decision was a playlist rescan; anything else, or nothing seen at all, exports as before.
	my $playlistsonly = $scScanSawPlaylists && !$scScanSawFull;
	$scScanSawPlaylists = 0;
	$scScanSawFull = 0;
	if ($playlistsonly) {
		main::INFOLOG && $log->is_info && $log->info("Playlist-only rescan - no post-scan MusicIP export\n");
		return;
	}

	if ($prefs->get('exportInprogress')) {
		main::INFOLOG && $log->is_info && $log->info("MusicIP export already running - the post-scan export was skipped\n");
		return;
	}

	main::INFOLOG && $log->is_info && $log->info("Starting the post-scan MusicIP export\n");
	eval { Slim::Utils::Scheduler::add_task(\&scMIPExportRun); };
	$log->error("Post-scan MusicIP export failed to start; $@\n") if $@;
}

sub scMIPExportIsTime {
	my ($name, $arg) = @_;
	return 1 if !$arg || $arg eq '';
	return 1 if $arg =~ m/^(0?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$/i;
	return 0;
}

1;
