# Spicefly - SugarCube
# Developed by Charles Parker
# Modifications by AF, (c) 2024
# Licensed under the GPLv3 - see LICENSE file

package Plugins::MIPster::Breakout;

use strict;
use warnings;
use base qw(Slim::Web::Settings);
use Plugins::MIPster::Plugin;
use Slim::Utils::Prefs;
use Slim::Utils::Log;

# The client-free string form throughout, not $client->string. Two of the subs that build the
# candidate table have no client in scope, and mixing the two forms would let one row render half in
# one language and half in another.
use Slim::Utils::Strings;
use Slim::Control::Request;
use File::Spec::Functions qw(:ALL);
use DBI qw(:sql_types);

my $log = logger('plugin.mipster');
my $prefs = preferences('plugin.mipster');
my $apc_enabled;

# Names only - title, artist, album, year, genre, artwork - asked once per track id. The NUMBERS
# beside them are deliberately not cached: APC moves a rating on every skip, and a stale number on
# the page this plugin is diagnosed from is worse than a cheap query. Dropped when a rescan finishes.
my %lvNameCache;
use constant LV_NAME_CACHE_MAX => 500;

sub scForgetNameCache {
	%lvNameCache = ();
}

sub getRandom {
	my $client = shift;
	my $genre = shift;

	my ($SCTRACKURL, $CurrentArtist, $CurrentTrack, $CurrentAlbum, $CurrentGenre, $CurrentAlbumArt, $FullAlbum);

	$log->debug("\nGet Random Track");

	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	$genre = $dbh->quote($genre);

	my $sql = "SELECT tracks.url, contributors.name, tracks.title, albums.title, genres.name, tracks.coverid, tracks.album FROM albums INNER JOIN contributors ON (albums.contributor = contributors.id) INNER JOIN tracks ON (tracks.album = albums.id) INNER JOIN genre_track ON tracks.id = genre_track.track INNER JOIN genres ON genre_track.genre = genres.id WHERE genres.name = $genre order by random() ASC limit 1";

	my $sth = $dbh->prepare($sql);
	$sth->execute();
	$sth->bind_col (1, \$SCTRACKURL);
	$sth->bind_col (2, \$CurrentArtist);
	$sth->bind_col (3, \$CurrentTrack);
	$sth->bind_col (4, \$CurrentAlbum);
	$sth->bind_col (5, \$CurrentGenre);
	$sth->bind_col (6, \$CurrentAlbumArt);
	$sth->bind_col (7, \$FullAlbum);

	if ($sth->fetch()) {
		$SCTRACKURL = Slim::Utils::Unicode::utf8decode ($SCTRACKURL, 'utf8');
		$CurrentArtist = Slim::Utils::Unicode::utf8decode ($CurrentArtist, 'utf8');
		$CurrentTrack = Slim::Utils::Unicode::utf8decode ($CurrentTrack, 'utf8');
		$CurrentAlbum = Slim::Utils::Unicode::utf8decode ($CurrentAlbum, 'utf8');
		$CurrentGenre = Slim::Utils::Unicode::utf8decode ($CurrentGenre, 'utf8');
		$CurrentAlbumArt = Slim::Utils::Unicode::utf8decode ($CurrentAlbumArt, 'utf8');
		$FullAlbum = Slim::Utils::Unicode::utf8decode ($FullAlbum, 'utf8');
	}

	$sth->finish();
	return ($SCTRACKURL, $CurrentArtist, $CurrentTrack, $CurrentAlbum, $CurrentGenre, $CurrentAlbumArt, $FullAlbum);
}

sub getalbum {
	my $client = shift;
	my $song = shift;
	my $SCAlbum;

	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $sth = $dbh->prepare('SELECT tracks.album FROM tracks WHERE tracks.url = ?');
	$sth->execute($song);
	$sth->bind_col (1, \$SCAlbum);
	if ($sth->fetch()) {
		$SCAlbum = Slim::Utils::Unicode::utf8decode ($SCAlbum, 'utf8');
	}
	$sth->finish();
	return ($SCAlbum);
}

sub getRealRandom {
	my $randomtrack;
	my $SCTitle;

	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $sql = "SELECT tracks.url FROM tracks order by random() limit 1";
	my $sth = $dbh->prepare($sql);
	$sth->execute();
	$sth->bind_col (1, \$randomtrack);
	if ($sth->fetch()) {
		$randomtrack = Slim::Utils::Unicode::utf8decode ($randomtrack, 'utf8');
	}

	$sth->finish();
	return ($randomtrack);
}

# The one place that asks LMS what a track looks like, so the answers match the queue by
# construction. Every field needs its own tag letter and a missing one is SILENT - dropping 'l'
# once cost a deploy, with the album line rendering as '1977 - ' and nothing after it.
sub scLMSDisplay {
	my $trackid = shift;
	return unless defined $trackid && $trackid =~ /^\d+$/;

	return $lvNameCache{$trackid} if exists $lvNameCache{$trackid};

	my $request = Slim::Control::Request::executeRequest (undef, ['titles', 0, 1, "track_id:$trackid", 'tags:aAelGgyJ']);
	return unless $request && !$request->isStatusError();

	my $loop = $request->getResult ('titles_loop');
	return unless ref $loop eq 'ARRAY' && scalar @{$loop};
	my $t = $loop->[0];

	my $names = {
		artist => $t->{'trackartist'} || $t->{'artist'} || '',
		title => $t->{'title'},
		album => $t->{'album'},
		genres => $t->{'genres'} || $t->{'genre'} || '',
		coverid => $t->{'artwork_track_id'},
		albumid => $t->{'album_id'},
		year => $t->{'year'},
	};

	scForgetNameCache() if scalar keys %lvNameCache >= LV_NAME_CACHE_MAX;
	$lvNameCache{$trackid} = $names;

	return $names;
}

sub scTrackStats {
	my $trackid = shift;
	return unless defined $trackid && $trackid =~ /^\d+$/;

	my $table = $apc_enabled ? 'alternativeplaycount' : 'tracks_persistent';
	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $query = "SELECT $table.playCount, tracks_persistent.rating, $table.lastPlayed FROM tracks INNER JOIN tracks_persistent ON (tracks.urlmd5 = tracks_persistent.urlmd5)";
	$query .= " left join alternativeplaycount on tracks.urlmd5 = alternativeplaycount.urlmd5" if ($apc_enabled);
	$query .= " where tracks.id = ?";

	my ($PC, $Rat, $LP);
	my $sth = $dbh->prepare($query);
	$sth->execute($trackid);
	$sth->bind_col (1, \$PC);
	$sth->bind_col (2, \$Rat);
	$sth->bind_col (3, \$LP);
	$sth->fetch();
	$sth->finish();

	$PC = Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_NEVERPLAYED') if (!defined($PC) || $PC eq '');
	$Rat = Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_NOTRATED') if (!defined($Rat) || $Rat eq '');

	if (!defined($LP) || $LP == -1) {
		$LP = Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_NEVERPLAYED');
	} else {
		$LP = scShortDate($LP);
	}

	return ($PC, $Rat, $LP);
}

sub getTSSongDetails {
	my $song = shift;

	my $trackid;
	my $track = Slim::Schema->rs('Track')->objectForUrl({'url' => $song});
	$trackid = $track->id if $track;

	if (!defined $trackid) {
		my $dbh = Slim::Schema->storage->dbh();
		my $sqlitetimeout = $prefs->get('sqlitetimeout');
		$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);
		my $sth = $dbh->prepare("SELECT tracks.id FROM tracks WHERE tracks.url = ?");
		$sth->execute($song);
		$sth->bind_col (1, \$trackid);
		$sth->fetch();
		$sth->finish();
		main::DEBUGLOG && $log->is_debug && $log->debug("getTSSongDetails - objectForUrl missed, url lookup gave " . (defined $trackid ? $trackid : 'nothing') . "\n");
	}

	return unless defined $trackid;

	my $d = scLMSDisplay ($trackid);
	return unless $d;

	my ($PC, $Rat, $LP) = scTrackStats ($trackid);

	my $CurrentAlbum = scYearAlbum ($d->{'year'}, $d->{'album'});
	my $CurrentGenre = scGenres ($d->{'genres'});

	return ($d->{'artist'}, $d->{'title'}, $CurrentAlbum, $CurrentGenre, $d->{'coverid'}, $d->{'albumid'}, $PC, $Rat, $LP);
}

sub getmyTSNextSong {
	no warnings 'numeric';

	my $client = shift;

	# Playing, not streaming. Lyrion buffers ahead, so asking which track is streaming and adding one
	# skips a track. CheckPosition and Live View's Currently Playing panel both measure from here, and
	# both panels must be measured from the same place or they describe different moments.
	my $songIndex = Slim::Player::Source::playingSongIndex($client);
	$songIndex++;
	my $listlength = Slim::Player::Playlist::count($client);
	return if $songIndex >= $listlength;
	my $track = Slim::Player::Playlist::track ($client, $songIndex);
	return unless $track && ref $track;
	my $trackid = $track->id;

	my $d = scLMSDisplay ($trackid);
	return unless $d;

	my ($PC, $Rat, $LP) = scTrackStats ($trackid);

	my $CurrentAlbum = scYearAlbum ($d->{'year'}, $d->{'album'});
	my $CurrentGenre = scGenres ($d->{'genres'});

	return ($d->{'artist'}, $d->{'title'}, $CurrentAlbum, $CurrentGenre, $d->{'coverid'}, $d->{'albumid'}, $PC, $Rat, $LP);
}

sub getGenre {
	my $client = shift;
	my $song = shift;
	my $SCGENRE;

	my $dbh = Slim::Schema->storage->dbh();
	my $sqlitetimeout = $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	my $sth = $dbh->prepare('SELECT genres.name FROM contributor_track INNER JOIN tracks ON (contributor_track.track = tracks.id) INNER JOIN contributors ON (contributor_track.contributor = contributors.id) INNER JOIN genre_track ON (genre_track.track = tracks.id) INNER JOIN genres ON (genre_track.genre = genres.id) WHERE tracks.url = ?');
	$sth->execute($song);
	$sth->bind_col (1, \$SCGENRE);
	if ($sth->fetch()) {
		$SCGENRE = Slim::Utils::Unicode::utf8decode ($SCGENRE, 'utf8');
	}

	$sth->finish();

	return ($SCGENRE);
}

sub CheckPosition {
	my $client = shift;
	my $listlength = Slim::Player::Playlist::count($client);
	my $playingTrackPos = Slim::Player::Source::playingSongIndex($client);
	my $returnvalue = ($listlength - $playingTrackPos);
	return $returnvalue;
}

# The one place that opens this plugin's own database. Do not turn it into a shared or cached
# handle - declined: one long-lived handle makes Live View and the mix loop contend for the file,
# which shows up as an intermittent stall, not an error. This is NOT for Lyrion's database.
sub scOpenDB {
	my $fallback = shift;

	my $path = Slim::Utils::OSDetect::dirsFor('prefs');
	$path = catfile ($path, 'plugin', 'mipster.db');

	my $dbh = DBI->connect("dbi:SQLite:$path") || die "Cannot connect: $DBI::errstr";

	my $sqlitetimeout = defined $fallback
		? ($prefs->get('sqlitetimeout') // $fallback)
		: $prefs->get('sqlitetimeout');
	$dbh->sqlite_busy_timeout ($sqlitetimeout * 1000);

	return $dbh;
}

sub init {
	$log->info("Initialising MIPster Database\n");
	my $dbh = scOpenDB(30);

	$dbh->do("CREATE TABLE IF NOT EXISTS WorkingSet (id INTEGER PRIMARY KEY, client, trackingno, temptrack, SCtrack, SCalbum, SCgenres, SCartist, SCplaycount integer, SCrating integer, SClastplayed integer, cover, album)");

	# Self-cleaning. WorkingSet is the only table this plugin owns. SQLite does not drop a table just
	# because the code stopped mentioning it, so anything else found here is a cobweb inherited from an
	# older build - removed wholesale rather than by a list of names that could only ever grow.
	my $tables = $dbh->selectcol_arrayref(
		"SELECT name FROM sqlite_master WHERE type='table' "
		. "AND name != 'WorkingSet' AND name NOT LIKE 'sqlite_%'");

	for my $tbl (@$tables) {
		$log->info("Removing table '$tbl' - left over from a removed feature or an older version.\n");
		$dbh->do("DROP TABLE " . $dbh->quote_identifier($tbl));
	}

	my $catalog_rowset = $dbh->selectall_arrayref("PRAGMA table_info(WorkingSet)");
	my @col_names = map { $_->[1] } @{$catalog_rowset};
	if (grep { $_ eq 'cover' } @col_names) {
	} else {
		$log->debug("Updating database table\n");
		$dbh->do("ALTER TABLE WorkingSet ADD cover");
		$dbh->do("ALTER TABLE WorkingSet ADD album");
	}
	$catalog_rowset = $dbh->selectall_arrayref("PRAGMA table_info(WorkingSet)");
	@col_names = map { $_->[1] } @{$catalog_rowset};
	if (grep { $_ eq 'scyear' } @col_names) {
	} else {
		$log->debug("Adding year to the working set table\n");
		$dbh->do("ALTER TABLE WorkingSet ADD scyear");
	}
	if (grep { $_ eq 'trackid' } @col_names) {
		$log->debug("Database tables are ready\n");
	} else {
		$log->debug("Updating database table some more\n");
		$dbh->do("ALTER TABLE WorkingSet ADD trackid");
	}

	# Two dates per row, different questions - do not merge them. SClastplayed is the later of APC's
	# played and skipped, which is right for the 'x days' block. SClmsplayed is Lyrion's own, stamped at
	# track START, which is what the since-export block needs because APC writes nothing until a track ends.
	$catalog_rowset = $dbh->selectall_arrayref("PRAGMA table_info(WorkingSet)");
	@col_names = map { $_->[1] } @{$catalog_rowset};
	if (grep { $_ eq 'SClmsplayed' } @col_names) {
	} else {
		$log->debug("Adding Lyrion last-played to the working set table\n");
		$dbh->do("ALTER TABLE WorkingSet ADD SClmsplayed integer");
	}
	$dbh->do("DROP TABLE IF EXISTS MIPReturned");
	$dbh->disconnect;
}

sub postinitPlugin {
	my $class = shift;
	$apc_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::AlternativePlayCount::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Alternative Play Count" is enabled') if $apc_enabled;
}

sub myworkingset {
	no warnings 'numeric';

	my $client = shift;
	my (@miparray) = @_;

	my $clientid = Slim::Player::Client::id($client);
	my $dbh = scOpenDB();

	my $sth = $dbh->prepare("DELETE FROM WorkingSet WHERE client = '$clientid' ");
	$sth->execute();

	$sth = $dbh->prepare("INSERT INTO WorkingSet (client, trackingno, temptrack, SCtrack, SCalbum, SCgenres, SCartist, SCplaycount, SCrating, SClastplayed, cover, album, trackid, scyear, SClmsplayed) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)");

	my $arraysize = scalar(@miparray);
	my $i = 0;
	while ($i < $arraysize) {
		my $SCplaycount = $miparray[ $i + 5 ];
		my $SCrating = $miparray[ $i + 6 ];
		my $SClastplayed = $miparray[ $i + 7 ];
		my $SClmsplayed  = $miparray[ $i + 12 ]; # Lyrion's own lastPlayed

		$SCplaycount += 0;
		if ($SCplaycount <= 0) {
			$SCplaycount = -1;
		}
		$SCrating += 0;
		if ($SCrating <= 0) {
			$SCrating = -1;
		}
		$SClastplayed += 0;
		if ($SClastplayed <= 0) {
			$SClastplayed = -1;
		}
		$SClmsplayed += 0;
		if ($SClmsplayed <= 0) {
			$SClmsplayed = -1;
		}

		$sth->bind_param (1, $clientid, SQL_VARCHAR);
		$sth->bind_param (2, 'OK', SQL_VARCHAR);
		$sth->bind_param (3, $miparray[$i], SQL_VARCHAR); # temptrack; track filename
		$sth->bind_param (4, $miparray[ $i + 1 ], SQL_VARCHAR); #SCTrack
		$sth->bind_param (5, $miparray[ $i + 2 ], SQL_VARCHAR); #SCAlbum
		$sth->bind_param (6, $miparray[ $i + 3 ], SQL_VARCHAR); #SCgenres
		$sth->bind_param (7, $miparray[ $i + 4 ], SQL_VARCHAR); # SCartist
		$sth->bind_param (8, $SCplaycount, SQL_INTEGER); # playcount
		$sth->bind_param (9, $SCrating, SQL_INTEGER); # rating
		$sth->bind_param (10, $SClastplayed, SQL_INTEGER); # last played
		$sth->bind_param (11, $miparray[ $i + 8 ], SQL_VARCHAR); # cover
		$sth->bind_param (12, $miparray[ $i + 9 ], SQL_VARCHAR); # album
		$sth->bind_param (13, $miparray[ $i + 10 ], SQL_VARCHAR); # trackid
		$sth->bind_param (14, $miparray[ $i + 11 ], SQL_VARCHAR); # year
		$sth->bind_param (15, $SClmsplayed, SQL_INTEGER); # Lyrion last played
		$sth->execute;
		$i = $i + 13; # INCREMENT IF ADDING COLUMNS - and the two strides in Plugin.pm with it
	}

	$sth->finish();

	$prefs->client($client)->set('mipLastCall', time());

	return;
}

sub mystuff {
	my $client = shift;
	my @myworkingset = ();
	my $clientid = Slim::Player::Client::id($client);

	my $dbh = scOpenDB();

	my $sth = $dbh->prepare("SELECT temptrack, SCTrack, SCalbum, SCgenres, SCartist, SCplaycount, SCrating, SClastplayed, cover, album FROM WorkingSet WHERE WorkingSet.trackingno = 'OK' AND client ='$clientid' ORDER BY id ASC");
	$sth->execute();

	my $array_ref = $sth->fetchall_arrayref();
	foreach my $row (@$array_ref) {
		push @myworkingset,
		my ($url, $track, $SCalbum, $genres, $artist, $playcount, $rating, $lastplayed, $cover, $album) = @$row;
	}
	$sth->finish();
	return @myworkingset;
}

sub blockedfallback {
	my $client = shift;
	my @myworkingset = ();
	my $clientid = Slim::Player::Client::id($client);

	my $dbh = scOpenDB();

	my ($rowid) = $dbh->selectrow_array(
		"SELECT id FROM WorkingSet WHERE client ='$clientid' AND WorkingSet.trackingno != 'DROPSEED' ORDER BY id ASC LIMIT 1");

	if (defined $rowid) {
		my $sth = $dbh->prepare("SELECT temptrack, SCTrack, SCalbum, SCgenres, SCartist, SCplaycount, SCrating, SClastplayed, cover, album FROM WorkingSet WHERE id = $rowid");
		$sth->execute();

		my $array_ref = $sth->fetchall_arrayref();
		foreach my $row (@$array_ref) {
			push @myworkingset,
			my ($url, $track, $SCalbum, $genres, $artist, $playcount, $rating, $lastplayed, $cover, $album) = @$row;
		}
		$sth->finish();

		# Not 'OK'. mystuff selects on 'OK' and this row deliberately never becomes one - it did not pass,
		# it was taken anyway.
		$dbh->do("UPDATE WorkingSet SET trackingno = 'BREACHED' WHERE id = $rowid");
	}

	$log->debug("blockedfallback returning;" . (scalar(@myworkingset) ? $myworkingset[0] : 'nothing') . "\n");
	return @myworkingset;
}

sub droptsmetrics {
	my $client = shift;
	my $clientid = Slim::Player::Client::id($client);

	my $blockRating = $prefs->get('blockRating') || 0;
	my $blockPlaycount = $prefs->get('blockPlaycount') || 0;
	my $blockLastplayed = $prefs->get('blockLastplayed') || 0;

	my $dbh = scOpenDB();

	if ($blockRating == 0) {
		$log->debug("Statistics - Use Track Rating - Disabled\n");
	} else {

		my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno='DROPTSRATING' "
			. "WHERE (WorkingSet.SCrating BETWEEN 0 AND ?) "
			. "AND WorkingSet.client = ? AND WorkingSet.trackingno = 'OK'");
		$sth->execute ($blockRating, $clientid) or warn $dbh->errstr . "\n";
		my $n = $sth->rows;
		$sth->finish();
		$log->debug("Stats block - RATING 0..$blockRating marked " . ($n > 0 ? $n : 0) . " rows\n");
	}

	if ($blockPlaycount == 0) {
	} else {
		my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno='DROPTSPLAYCOUNT' "
			. "WHERE (WorkingSet.SCplaycount >= ?) "
			. "AND WorkingSet.client = ? AND WorkingSet.trackingno = 'OK'");
		$sth->execute ($blockPlaycount, $clientid) or warn $dbh->errstr . "\n";
		my $n = $sth->rows;
		$sth->finish();
		$log->debug("Stats block - PLAYCOUNT >= $blockPlaycount marked " . ($n > 0 ? $n : 0) . " rows\n");
	}
	if ($blockLastplayed == 0) {
	} else {
		my $currenttime = time; # Current time in epoch
		my $epochYestertime = time - (($blockLastplayed * 24) * 60 * 60); # subtract secs in day from current epoch time

		my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno='DROPTSLASTPLAYED' "
			. "WHERE (WorkingSet.SClastplayed BETWEEN ? AND ?) "
			. "AND WorkingSet.client = ? AND WorkingSet.trackingno = 'OK'");
		$sth->execute ($epochYestertime, $currenttime, $clientid) or warn $dbh->errstr . "\n";
		my $n = $sth->rows;
		$sth->finish();
		$log->debug("Stats block - PLAYED or SKIPPED within last $blockLastplayed day(s) marked " . ($n > 0 ? $n : 0) . " rows\n");
	}

	# The counts do not overlap and the first label wins: every stage selects on trackingno='OK', so
	# once a row is labelled no later stage can see it. A stage logging 'marked 0 rows' is normal. Any
	# new block must carry the same guard or the displayed drop reason stops being the true one.
	if (main::DEBUGLOG && $log->is_debug) {
		my $sth = $dbh->prepare("SELECT trackingno, COUNT(*) FROM WorkingSet WHERE client = ? GROUP BY trackingno ORDER BY trackingno");
		$sth->execute($clientid);
		my $tally = join ', ', map { "$_->[0]=$_->[1]" } @{$sth->fetchall_arrayref()};
		$sth->finish();
		$log->debug("WorkingSet after all blocks; $tally\n");
	}
}

sub DropSinceExport {
	my $client = shift;
	my $clientid = Slim::Player::Client::id($client);

	# BLOCK / DON'T, on the Main settings page, server-wide. Default Block. MusicIP holds no play
	# history since the last export, so without this the same tracks keep coming back until the next
	# one runs.
	if (!($prefs->get('blockSinceExport') // 1)) {
		$log->debug("Since-export block - switched off, nothing to do\n");
		return;
	}

	my $lastsuccess = $prefs->get('exportLastsuccess') || 0;
	if (!$lastsuccess) {
		$log->debug("Since-export block - no successful export recorded yet, nothing to do\n");
		return;
	}

	my $dbh = scOpenDB();

	my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno = 'DROPSINCEEXPORT' "
		. "WHERE WorkingSet.client = ? AND WorkingSet.trackingno = 'OK' "
		. "AND WorkingSet.SClmsplayed > ?");
	$sth->execute ($clientid, $lastsuccess);
	my $n = $sth->rows;
	$sth->finish();
	$dbh->disconnect;

	$log->debug("Since-export block - played since " . scStampDate($lastsuccess) . " marked "
		. ($n > 0 ? $n : 0) . " row(s)\n");
	return;
}

sub DropSeed {
	my $client = shift;
	my $clientid = Slim::Player::Client::id($client);

	my $seed = Slim::Player::Playlist::url($client) || '';
	return unless length $seed;

	# The tmp: address is converted first. kickoff converts its own copy for the request, but the queue
	# still holds the original - without this the seed is never struck from MusicIP's answer, so the
	# track you are listening to can be queued again.
	if ($seed =~ m/^tmp:/i) {
		my $z = substr $seed, 0, 3, "file"; # replaces tmp with file
	}

	$seed = Slim::Utils::Misc::pathFromFileURL($seed);
	$seed = Plugins::MIPster::Plugin::dirtyencoder($seed);
	return unless length $seed;

	my $dbh = scOpenDB();

	my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno = 'DROPSEED' "
		. "WHERE WorkingSet.temptrack = ? AND WorkingSet.client = ? "
		. "AND WorkingSet.trackingno = 'OK'");
	$sth->execute ($seed, $clientid);
	my $n = $sth->rows;
	$sth->finish();

	$log->debug("Seed drop - marked " . ($n > 0 ? $n : 0) . " row(s)\n");
	return;
}

# Nothing already sitting in this player's queue may be queued again. LMS keeps played tracks behind
# the playing one and trims the queue to its own Performance limit, so the queue already holds this
# session's recent history - no table of our own is needed, and it is immediate where APC is not.
sub DropInQueue {
	my $client = shift;
	return unless $client;
	my $clientid = Slim::Player::Client::id($client);

	my $count = Slim::Player::Playlist::count($client) || 0;
	return unless $count;

	# The queue already holds track objects, so reading them straight out avoids a database lookup and
	# a validity check that stats the file on disk, once per queued track, every track change.
	# ref() rather than blessed(): an unresolved entry comes back as a plain url string and is skipped.
	my @ids;
	for (my $i = 0; $i < $count; $i++) {
		my $track = Slim::Player::Playlist::track ($client, $i);
		next unless $track && ref $track;
		my $id = eval { $track->id };
		push @ids, $id if (defined $id && $id =~ /^\d+$/);
	}
	return unless @ids;

	my $dbh = scOpenDB();

	my $placeholders = join ',', ('?') x scalar(@ids);
	my $sth = $dbh->prepare("UPDATE WorkingSet SET trackingno = 'DROPINQUEUE' "
		. "WHERE WorkingSet.client = ? AND WorkingSet.trackingno = 'OK' "
		. "AND WorkingSet.trackid IN ($placeholders)");
	$sth->execute ($clientid, @ids);
	my $n = $sth->rows;
	$sth->finish();
	$dbh->disconnect;

	$log->debug("In-queue drop - " . scalar(@ids) . " track(s) in the queue, marked "
		. ($n > 0 ? $n : 0) . " row(s)\n");
	return;
}

sub scStampDate {
	my $epoch = shift;
	return '' if (!defined($epoch) || $epoch <= 0);
	my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
	my @t = localtime($epoch);
	return sprintf ('%s %d, %d %02d:%02d',
		$months[ $t[4] ], $t[3], $t[5] + 1900, $t[2], $t[1]);
}

sub scShortDate {
	my $epoch = shift;
	return Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_NEVERPLAYED') if (!defined($epoch) || $epoch <= 0);
	my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
	my @t = localtime($epoch);
	return $months[ $t[4] ] . ' ' . $t[3] . ' ' . ($t[5] + 1900);
}

sub scYearAlbum {
	my ($year, $album) = @_;
	$album = '' unless defined $album;
	return $album if (!defined($year) || $year eq '' || $year == 0);
	return $year . ' - ' . $album;
}

sub scGenres {
	my $genres = shift;
	return '' unless defined $genres;
	$genres =~ s/\s*,\s*/, /g;
	return $genres;
}

sub StatsPuller {
	my $client = shift;
	my $clientid = Slim::Player::Client::id($client);
	my (@rows, $col1, $col2, $col3, $col4, $col5, $col6, $col7, $col8, $col10, $col12, $col13);

	my $artsize = '300x300_f'; # what we ask Lyrion for - Material's own list/grid spec
	my $iconsize = 100;       # what we draw it at

	my $dbh = scOpenDB();

	my $sth = $dbh->prepare("SELECT trackingno, SCtrack, SCalbum, SCartist, SCgenres, SCplaycount, SCrating, SClastplayed, cover, trackid, scyear FROM WorkingSet WHERE WorkingSet.client = '$clientid' ORDER BY WorkingSet.id ASC");
	$sth->execute();
	$sth->bind_col (1, \$col1); # tracking status ie. played already, playcount etc
	$sth->bind_col (2, \$col2); # track name
	$sth->bind_col (3, \$col3); # album name
	$sth->bind_col (4, \$col4); # artist name
	$sth->bind_col (5, \$col5); # genres
	$sth->bind_col (6, \$col6); # playcount
	$sth->bind_col (7, \$col7); # rating
	$sth->bind_col (8, \$col8); # lastplayed
	$sth->bind_col (9, \$col10); # albumart cover number
	$sth->bind_col (10, \$col12); # track id
	$sth->bind_col (11, \$col13); # year

	my $clientid_uri = $client->id;
	$clientid_uri =~ s/:/%3A/g; # URI player id - for links only, NEVER for a server command
	my $clientid_raw = $client->id; # unencoded - the server matches on this, %3A matches nothing

	my $scCanReplace = (Plugins::MIPster::Breakout::CheckPosition($client) <= 2) ? 1 : 0;

	while ($sth->fetch) {
	if ($col6 == -1) { $col6 = Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_NEVERPLAYED'); }
	if ($col7 == -1) { $col7 = Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_NOTRATED'); }
	if ($col1 eq 'DROPTSLASTPLAYED') {
		$col1 = Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_DROP_LASTPLAYED');
	} elsif ($col1 eq 'DROPINQUEUE') { $col1 = Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_DROP_QUEUE');
	} elsif ($col1 eq 'DROPSINCEEXPORT') { $col1 = Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_DROP_SINCEEXPORT');
	} elsif ($col1 eq 'DROPTSPLAYCOUNT') { $col1 = Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_DROP_PLAYCOUNT');
	} elsif ($col1 eq 'DROPTSRATING') { $col1 = Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_DROP_RATING');
	} elsif ($col1 eq 'DROPSEED') { $col1 = Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_DROP_SEED');

	# The breach label reuses the pop-up's own key. The pop-up that fires when a block is breached and
	# the row that records it here are the same announcement on two surfaces. Do not split them.
	} elsif ($col1 eq 'BREACHED') { $col1 = Slim::Utils::Strings::string('PLUGIN_MIPSTER_POPUP_BREACHED');
	} elsif ($col1 ne 'OK') {

		# Catch-all. A label from a rule this build no longer has would otherwise show as raw shouting,
		# because its translation was deleted with the rule while old rows kept the word. WorkingSet is
		# cleared only when that player next asks MusicIP, so old rows survive for months.
		$col1 = Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_DROP_OTHER');
	}

	$col8 = ($col8 == -1)
		? Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_NEVERPLAYED')
		: scShortDate($col8);

	if (!defined($col10) || $col10 eq '') { $col10 = "0"; }

	my $rowTitle = $col2;
	my $rowArtist = $col4;
	my $rowAlbum = scYearAlbum ($col13, $col3);
	my $rowGenres = scGenres ($col5);
	my $rowCover = $col10;

	if (my $d = scLMSDisplay ($col12)) {
		$rowTitle = $d->{'title'};
		$rowArtist = $d->{'artist'};
		$rowAlbum = scYearAlbum ($d->{'year'}, $d->{'album'});
		$rowGenres = scGenres ($d->{'genres'});
		$rowCover = $d->{'coverid'} if (defined $d->{'coverid'} && $d->{'coverid'} ne '');
	}

	# The in-flight word goes inside a JavaScript single-quoted string, so it is escaped first -
	# one apostrophe in a translator's wording would close the string early and break the link for
	# everybody in that language. Backslash first, then quote, or the escape eats itself.
	(my $scLvReplacing = Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_REPLACING')) =~ s/([\\'])/\\$1/g;

	my $build = $scCanReplace
		? "<a onclick=\"this.innerHTML='$scLvReplacing';var a=this;"
		. "var r=new XMLHttpRequest();r.open('POST','/jsonrpc.js',true);"
		. "r.setRequestHeader('Content-Type','application/json');"
		. "r.onloadend=function(){var m='';"
		. "try{m=JSON.parse(r.responseText).result.scmsg||'';}catch(e){}"
		. "if(m){a.innerHTML=m;}"
		. "else if(window.scLvRefresh){scLvRefresh();}else{location.reload();}};"
		. "r.send(JSON.stringify({id:1,method:'slim.request',params:['"
		. $clientid_raw
		. "',['mipster','replacesel','"
		. $col12
		. "']]}));\" style=\"cursor:pointer;text-decoration:underline\">"
		. Slim::Utils::Strings::string('PLUGIN_MIPSTER_LV_USEASNEXT')
		. "</a>"
		: '&nbsp;';

	push @rows, {
		'iconsize'   => $iconsize,
		'artsize'    => $artsize,
		'cover'      => $rowCover,
		'link'       => $build,
		'descriptor' => $col1,
		'title'      => $rowTitle,
		'artist'     => $rowArtist,
		'album'      => $rowAlbum,
		'genre'      => $rowGenres,
		'rating'     => $col7,
		'playcount'  => $col6,
		'lastplayed' => $col8,
	};
	}

	$sth->finish();
	return \@rows;
}

1;
