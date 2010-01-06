package Acoustics;

use strict;
use warnings;

use Mouse;
use Module::Load 'load';
use DBI;
use SQL::Abstract::Limit;
use Log::Log4perl;
use Date::Parse 'str2time';
use Config::Tiny;

has 'db' => (is => 'ro', isa => 'DBI', handles => [qw(begin_work commit)]);
has 'config' => (is => 'ro', isa => 'Config::Tiny');
has 'abstract' => (is => 'ro', isa => 'SQL::Abstract');
has 'config_file' => (is => 'ro', isa => 'Str');

has 'player_id' => (is => 'ro', isa => 'Str', default => 'default player');

has 'voter_order' => (is => 'rw', isa => 'ArrayRef[Str]', default => sub {[]});

# Logger configuration:
# - Print out all INFO and above messages to the screen
# - Write out all WARN and above messages to a logfile
my $log4perl_conf = q(
log4perl.logger = INFO, Screen, Logfile
log4perl.logger.Acoustics.Web = INFO, Logfile

# INFO messages
log4perl.filter.MatchInfo = Log::Log4perl::Filter::LevelRange
log4perl.filter.MatchInfo.LevelMin      = INFO
log4perl.filter.MatchInfo.AcceptOnMatch = true

# Error messages
log4perl.filter.MatchError = Log::Log4perl::Filter::LevelRange
log4perl.filter.MatchError.LevelMin      = WARN
log4perl.filter.MatchError.AcceptOnMatch = true

# INFO to Screen
log4perl.appender.Screen        = Log::Log4perl::Appender::ScreenColoredLevels
log4perl.appender.Screen.Filter = MatchInfo
log4perl.appender.Screen.layout = Log::Log4perl::Layout::PatternLayout
log4perl.appender.Screen.layout.ConversionPattern = %p %d %F{1} %L> %m %n

# ERROR to Logfile
log4perl.appender.Logfile          = Log::Log4perl::Appender::File
log4perl.appender.Logfile.Filter   = MatchError
log4perl.appender.Logfile.filename = /tmp/acoustics.log
log4perl.appender.Logfile.layout   = Log::Log4perl::Layout::PatternLayout
log4perl.appender.Logfile.layout.ConversionPattern = %p %d %F{1} %L> %m %n
);
Log::Log4perl::init(\$log4perl_conf);
my $logger = Log::Log4perl::get_logger;

sub BUILD {
	my $self = shift;

	$self->{config} = Config::Tiny->read($self->config_file)
		or die "couldn't read config: \"" . $self->config_file . '"';

	$self->{db} = DBI->connect(
		$self->config->{database}{data_source},
		$self->config->{database}{user}, $self->config->{database}{pass},
		{RaiseError => 1, AutoCommit => 1},
	);
	$self->{abstract} = SQL::Abstract::Limit->new({
		limit_dialect => $self->db,
	});
}

sub check_if_song_exists {
	my $self = shift;
	my $path = shift;

	my @rows = $self->db->selectrow_array(
		'SELECT count(*) FROM songs WHERE path = ?',
		undef, $path,
	);

	return $rows[0];
}

sub add_song {
	my $self = shift;
	my $data = shift;

	my($sql, @values) = $self->abstract->insert('songs', $data);
	my $sth = $self->db->prepare($sql);
	$sth->execute(@values);
}

sub update_song {
	my $self  = shift;
	my $data  = shift;
	my $where = shift;

	my($sql, @values) = $self->abstract->update('songs', $data, $where);
	my $sth = $self->db->prepare($sql);
	$sth->execute(@values);
}

sub get_song {
	my $self   = shift;
	my $where  = shift;
	my $order  = shift;
	my $limit  = shift;
	my $offset = shift;

	my($sql, @values) = $self->abstract->select(
		'songs', '*', $where, $order, $limit, $offset,
	);
	my $sth = $self->db->prepare($sql);
	$sth->execute(@values);

	return @{$sth->fetchall_arrayref({})};
}

sub browse_songs_by_column {
	my $self   = shift;
	my $col    = shift;
	my $order  = shift;
	my $limit  = shift;
	my $offset = shift;

	# SQL injection.
	if ($col =~ /\W/) {
		$logger->error("SQL injection attempt with column '$col'");
		return;
	}

	my($sql, @values) = $self->abstract->select(
		'songs', "DISTINCT $col", {}, $order, $limit, $offset,
	);
	my $sth = $self->db->prepare($sql);
	$sth->execute(@values);

	return map {$_->[0]} @{$sth->fetchall_arrayref([$col])};
}

sub get_votes_for_song {
	my $self = shift;
	my $song_id = shift;

	my $select_votes = $self->db->prepare(
			'SELECT who FROM votes WHERE song_id=?');
	
	$select_votes->execute($song_id);

	return @{$select_votes->fetchall_arrayref({})};
}

sub get_songs_by_votes {
	my $self = shift;

	# Find all the voters, and add them to our ordering
	my @voter_list = @{$self->db->selectcol_arrayref(
		'SELECT who FROM votes WHERE player_id = ?
		GROUP BY who ORDER BY MIN(time)',
		undef, $self->player_id,
	)};

	# add any voters that we don't have listed to the end of the queue
	for my $who (@voter_list) {
		my %lookup = map {$_ => 1} @{$self->voter_order};
		push @{$self->voter_order}, $who unless $lookup{$who};
	}

	# remove extra voters from the list
	my %lookup = map {$_ => 1} @voter_list;
	@{$self->voter_order} = grep {$lookup{$_}} @{$self->voter_order};

	# Make a hash mapping voters to all the songs they have voted for
	my $select_votes = $self->db->prepare('
		SELECT votes.song_id, votes.time, votes.who, songs.artist, songs.album,
		songs.title, songs.length, songs.path, songs.track FROM votes INNER
		JOIN songs ON votes.song_id = songs.song_id WHERE votes.player_id = ?
	');
	$select_votes->execute($self->player_id);

	my %votes;
	while (my $row = $select_votes->fetchrow_hashref()) {
		my $who = delete $row->{who}; # remove the who, save it
		$row->{time} = str2time($row->{time});
		$votes{$row->{song_id}} ||= $row;
		push @{$votes{$row->{song_id}}{who}}, $who; # re-add the voter
	}

	return %votes;
}

sub build_playlist {
	my $self = shift;

	my %votes = $self->get_songs_by_votes;
	my @voter_order = @{$self->voter_order};

	# round-robin between voters, removing them from the temporary voter list
	# when all their songs are added to the playlist
	my @songs;
	while (@voter_order) {
		# pick the first voter
		my $voter = shift @voter_order;

		# find all songs matching this voter and sort by number of voters
		my @candidates = grep {
			grep {$_ eq $voter} @{$_->{who}}
		} values %votes;
		@candidates = reverse sort {@{$a->{who}} <=> @{$b->{who}}} reverse sort {$a->{time} <=> $b->{time}} @candidates;

		# if this user has no more stored votes, ignore them
		next unless @candidates;

		# grab the first candidate, remove it from the hash of votes
		push @songs, delete $votes{$candidates[0]{song_id}};

		# re-add the voter to the list since they probably have more songs
		push @voter_order, $voter;
	}

	return @songs;
}

# A deficit round robin playlist
sub build_drr_playlist {
	my $self = shift;
	my %votes = $self->get_songs_by_votes;
	my @voter_order = @{$self->voter_order};
	# map voter to deficit count
	my %voter_debts = map {$_ => 0} @voter_order;
	# deficit round robin voters
	my @songs;
	while (@voter_order) {
		# quantum starts huge, so a real quantum can be found
		my $quantum = 2**32;
		# find the smallest song length, call it the quantum
		foreach(@voter_order) {
			my $voter = $_;
			my @candidates = grep { grep { $_ eq $voter } @{$_->{who} } } values %votes;
			@candidates = reverse sort {@{$a->{who}} <=> @{$b->{who}}} reverse sort {$a->{time} <=> $b->{time}} @candidates;
			next unless @candidates;
			my $weighted_length = $candidates[0]{length}/(scalar @{$candidates[0]{who}});
			$quantum = $weighted_length if ($quantum > $weighted_length);
		}
		# Make a temporary voter order, separate so quantum is fixed for all voters each round
		my @temp_order = @voter_order;
		foreach my $voter (@temp_order) {
			# find all songs matching this voter and sort by number of voters
			my @candidates = grep {
				grep {$_ eq $voter} @{$_->{who}}
			} values %votes;
			@candidates = reverse sort {@{$a->{who}} <=> @{$b->{who}}} reverse sort {$a->{time} <=> $b->{time}} @candidates;
			# if this user has no more stored votes, remove them from voter pool
			unless (@candidates) {
				@voter_order = grep { $_ ne $voter } @voter_order;
				delete $voter_debts{$voter};
				next;
			}
			my %first = %{shift @candidates};
			# weight length based on # of voters
			my $weighted_length = $first{length}/(scalar @{$first{who}});
			# if first candidate's length is >= debt, push onto songs
			if ($voter_debts{$voter} >= $weighted_length) {
				# Collect the debt from each voter
				foreach my $partner (@{$first{who}}) {
					$voter_debts{$partner} -= $weighted_length;
				}
				push @songs, delete $votes{$first{song_id}};
			}
			# otherwise, add the quantum
			else {
				$voter_debts{$voter} += $quantum;
			}
		}
	}
	return @songs;
}

sub get_playlist {
	my $self = shift;
	my @playlist = $self->build_playlist;

	my($player) = $self->get_player({player_id => $self->player_id});
	return grep {$player->{song_id} != $_->{song_id}} @playlist;
}

sub get_current_song {
	my $self = shift;
	my @playlist = $self->build_playlist;
	if (@playlist) {
		return $playlist[0];
	}
	return;
}

sub delete_vote {
	my $self  = shift;
	my $where = shift;

	unless ($where) {
		$logger->logdie('you must pass an empty hashref to delete all votes');
	}

	$where->{player_id} ||= $self->player_id;

	my($sql, @values) = $self->abstract->delete('votes', $where);
	my $sth = $self->db->prepare($sql);
	$sth->execute(@values);
}

sub add_playhistory {
	my $self = shift;
	my $data = shift;

	my($sql, @values) = $self->abstract->insert('history', $data);
	my $sth = $self->db->prepare($sql);
	$sth->execute(@values);
}

sub get_history
{
	my $self = shift;
	my $amount = shift;

	my $sth = $self->db->prepare('SELECT time FROM history GROUP BY time ORDER BY time DESC LIMIT ?');
	$sth->execute($amount);
	my $final_time = (@{$sth->fetchall_arrayref({})})[-1]->{time};
	$sth->finish;

	my $select_history = $self->db->prepare('SELECT history.who, history.time,
		songs.* FROM history INNER JOIN songs ON history.song_id =
		songs.song_id WHERE history.time >= ? AND history.player_id = ? ORDER BY
		history.time DESC');
	$select_history->execute($final_time, $self->player_id);

	return @{$select_history->fetchall_arrayref({})};
}

sub delete_song {
	my $self  = shift;
	my $where = shift;

	unless ($where) {
		$logger->logdie('you must pass an empty hashref to delete all songs');
	}

	my($sql, @values) = $self->abstract->delete('songs', $where);
	my $sth = $self->db->prepare($sql);
	$sth->execute(@values);
}

sub vote {
	my $self = shift;
	my $song_id = shift;
	my $who = shift;

	my $sth = $self->db->prepare(
		'INSERT IGNORE INTO votes (song_id, time, player_id, who) VALUES (?, now(), ?, ?)'
	);

	$sth->execute($song_id, $self->player_id, $who);
}

sub add_player {
	my $self = shift;
	my $data = shift;
	$data  ||= {};
	$data->{player_id} = $self->player_id;

	my($sql, @values) = $self->abstract->insert('players', $data);
	my $sth  = $self->db->prepare($sql);

	$sth->execute(@values);
}

sub update_player {
	my $self = shift;
	my $data = shift;

	my($sql, @values) = $self->abstract->update(
		'players', $data, {player_id => $self->player_id},
	);
	my $sth = $self->db->prepare($sql);
	$sth->execute(@values);
}

sub remove_player {
	my $self = shift;
	my $sth  = $self->db->prepare('DELETE FROM players WHERE player_id = ?');

	$sth->execute($self->player_id);
}

sub get_player {
	my $self  = shift;
	my $where = shift;

	my($sql, @values) = $self->abstract->select('players', '*', $where);
	my $sth = $self->db->prepare($sql);
	$sth->execute(@values);

	return @{$sth->fetchall_arrayref({})};
}

sub player {
	my $self = shift;
	my $act  = shift;

	my $player_class = $self->config->{player}{module};
	load $player_class;

	$player_class->$act($self, @_);
}

sub rpc {
	my $self = shift;
	my $act  = shift;

	my $rpc_class = $self->config->{rpc}{module};
	load $rpc_class;

	$rpc_class->$act($self, @_);
}

sub reinit {
	my $self = shift;

	return Acoustics->new({config_file => $self->config_file});
}

1;
