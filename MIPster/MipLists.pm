# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file

# THE MUSICIP LIST FETCHER. This was PlayerSettings.pm, which drew the per-player settings page. That
# page is gone - every per-player control lives on MIP Controls now - but the three list helpers it
# owned are still the only place MusicIP is asked for its filters, recipes and moods, and Controls and
# the player menu both call them. Nothing here draws or saves anything.

package Plugins::MIPster::MipLists;

use strict;
use warnings;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use LWP::UserAgent;
use Plugins::MIPster::PowerSearch;

my $prefs = preferences('plugin.mipster');
my $log = logger('plugin.mipster');

my $timeoutvalue = 4;

# The one place that asks MusicIP for a list. The timeout backs off once MusicIP is known to be down
# - for all three pickers, until LMS restarts. Shaping stays with each caller: the '(None)' entry
# belongs to filters and recipes, the whitespace trim to moods only.
sub mipFetch {
	my $listname = shift; # 'filters' | 'recipes' | 'moods'

	my $MMSport = $prefs->get('mipPort');
	my $mipHost = $prefs->get('mipHost');

	my $url = 'http://' . $mipHost . ":$MMSport/api/$listname";
	my $ua = LWP::UserAgent->new();
	$ua->timeout($timeoutvalue);
	my $http = $ua->get($url);

	my @lines = ();
	@lines = split(/\n/, $http->content) if $http;

	if ($http && ($http->header("Client-Warning") || '') =~ /Internal response/) {
		$log->warn("\nMusicIP is NOT Running!");
		$timeoutvalue = 2;
	}

	return @lines;
}

# Filters and recipes only. Moods must NOT come through here: they get no '(None)' entry, and they
# trim whitespace, which these two must not do because a filter name is sent to MusicIP verbatim.
sub mipNamedList {
	my $listname = shift; # 'filters' | 'recipes'

	my %hash = ();
	my @names = mipFetch($listname);

	my $none = sprintf('(%s)', Slim::Utils::Strings::string('NONE'));
	push @names, $none;
	foreach my $name ( @names ) {
		if ($name eq $none) {
			$hash{0} = $name;
			next
		}
		$hash{$name} = $name;
	}
	return \%hash;
}

# THE POWER SEARCH ENTRY IS INJECTED HERE, and here only. mipNamedList builds the recipe list with
# the same code, so the entry cannot go in there without appearing in both. It appears only when the
# player has a search that passed its yield test - nothing is re-checked when the dropdown is drawn.
sub getFilterList {
	my $client = shift;

	my $list = mipNamedList('filters');

	# AND ONLY WHEN THE HOST CAN TAKE AN EXPRESSION. Offering it against a headless host let a
	# player be left on (Power Search) while scIsNone fell back to no filter, so the dropdown said
	# one thing and the mix was library-wide. The answer is kept for a minute, so this costs nothing
	# after the first draw, and it is asked only for a player that actually has a saved search.
	if ($client && Plugins::MIPster::PowerSearch::savedSearch($client)
		&& Plugins::MIPster::PowerSearch::hostCapability() eq 'ok') {
		$list->{ Plugins::MIPster::PowerSearch::psKey() }
			= Plugins::MIPster::PowerSearch::psLabel();
	}

	return $list;
}

sub getReceipesList { return mipNamedList('recipes'); }

sub ensureSeedMood {
	my $client = shift;
	return '' unless $client;

	my $mood = $prefs->client($client)->get('mood');
	return $mood if (defined $mood && $mood ne '');

	my $moods = getMoodsList();
	my ($first) = sort { lc($a) cmp lc($b) } keys %$moods;
	return '' unless defined $first;

	$prefs->client($client)->set('mood', $first);
	$log->debug("Seed Mood not set; defaulting to '$first'\n");
	return $first;
}

sub getMoodsList {
	my %moodHash = ();

	my @moods = mipFetch('moods');

	foreach my $mood ( @moods ) {
		next unless defined $mood;
		$mood =~ s/^\s+|\s+$//g;
		next unless length $mood;
		$moodHash{$mood} = $mood;
	}

	return \%moodHash;
}

1;
