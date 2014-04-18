#!/usr/bin/env perl

=pod

=head1 Copyright

This file is part of twipper.

twipper is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

twipper is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with twipper.  If not, see <http://www.gnu.org/licenses/>.

=cut

use warnings;
use strict;

use feature "state";

use Module::Load::Conditional qw( can_load );
use Net::OAuth;
$Net::OAuth::PROTOCOL_VERSION = Net::OAuth::PROTOCOL_VERSION_1_0A;
use Digest::SHA qw( sha256_hex );
use HTTP::Request::Common;
use LWP::UserAgent;
use Storable;
use Getopt::Long;
use JSON;
use Date::Calc qw(System_Clock Decode_Month Delta_DHMS);
use Math::Random::Secure qw(rand);

binmode STDOUT, ":utf8";

my $consumer_key = "m8RaUkJAEe2ea5XJcDKTzQ";
my $consumer_secret = "oHyLboZvrnq5RFknZ3H0q9kNL9b9erB8jOXfBlHh2E0";

my $fetch=0;
my $count=5;
my $stdin=0;
my $window=0;
my $blank=0;
my $wrap=0;
my $indent=0;
my $twoline=0;
my $drawlines=0;
my $dryrun=0;
my $oneshot=0;
my $shortenLengthHttp=-1;
my $shortenLengthHttps=-1;
my $maxMediaSize=-1;
my $user=undef;

GetOptions(
	"count|c=i" => \$count,
	"fetch|f" => \$fetch,
	"stdin|s" => \$stdin,
	"window|w" => \$window,
	"blank|b" => \$blank,
	"wrap=i"   => \$wrap,
	"indent|i=i" => \$indent,
	"twoline|t" => \$twoline,
	"drawlines" => \$drawlines,
	"dry-run|n" => \$dryrun,
	"one-shot|1" => \$oneshot,
	"user|u=s" => \$user,
) or usage();

if( $oneshot && $window==0 ) {
	warn( "--one-shot doesn't make sense without --window" );
	usage();
	exit 1;
}

if( $twoline && $wrap==0 ) {
	warn( "--twoline requires setting a wrap length with --wrap" );
	usage();
	exit 1;
}

if( $drawlines && !$twoline ) {
	warn( "--drawline is meaningless without --twoline" );
}

if( $wrap != 0 ) {
	unless( can_load( Modules => { "Text::Wrap" => undef } ) ) {
		die( "wrapping (--wrap) requested but the Text::Wrap module is not available." );
	}
	$Text::Wrap::columns = $wrap;
	$Text::Wrap::columns = $wrap;
}

if( $blank == 1 ) {
	exit if `xscreensaver-command -time` =~ m/screen blanked/i;
	exit if `xset q` =~ m/Monitor is Off/i;
}

my $userAgent = LWP::UserAgent->new();

my( $token, $token_secret ) = getAuth( $user );

my $tweetVar = "";
my $tweetLabel = "(0/140)";
my $tweetEntry;
my %commands;

if( $fetch == 1 ) {
	exit fetch();
} elsif( $window == 1 ) {
	exit runWindowed();
} else {
	exit tweet();
}

#
# Implementation
#

sub runWindowed {
	unless( can_load( Modules => { "Tk" => undef } ) ) {
		die( "Undable to load perl Tk module. Please install the package (perl-tk on Debian) or module and try again:\n".$Module::Load::Conditional::ERROR );
	}

	# validate returns 0 (meaning keystroke made the tweet invalid) or 1
	# (meaning keystroke made the tweet valid and/or more keystrokes could make
	# it valid), and may change $tweetLabel for interactions
	%commands = (
		"reply" => [ \&validateReply, \&tweetReply ],
		"rt" => [ \&validateRetweet, \&tweetRetweet ],
		"go" => [ \&validateGo, \&tweetGo ],
		"fave" => [ \&validateFave, \&tweetFave ],
		"favorite" => [ \&validateFave, \&tweetFave ],
	);

	my $rootWindow = MainWindow->new;
	$rootWindow->title( "twipper.pl: tweet" );
	$rootWindow->geometry( "400x24" );
	$rootWindow->bind( "<Control-q>" => [ sub { exit(0); } ] );
	$tweetEntry = $rootWindow->Entry( -textvariable => \$tweetVar, -validate => "all", -vcmd => \&validateFromGUI, -font => $rootWindow->fontCreate( "entryFont" ) );
	$tweetEntry->bind( "<Return>" => \&tweetFromGUI );
	$tweetEntry->bind( "<Escape>" => \&clearFromGUI );
	$tweetEntry->focus();
	$tweetEntry->place( -anchor => "nw", -x => 0, -y => 0 ); #pack( -side => "left", -fill => "both", -expand => 0 );
	my $label = $rootWindow->Label( -textvariable => \$tweetLabel, -font => $rootWindow->fontCreate( "labelFont" ) );#, -font => $rootWindow->Font( -family => "Courier" ) );
	$label->place( -anchor => "ne", -relx => 1.0, -rely => 0.0 ); #pack( -fill => "both", -expand => 0 );
	$rootWindow->bind( "<Configure>" => [ sub {
		my( $ign, $root, $tweetEntry, $label ) = @_;
		$label->font( "configure", "labelFont", "-size", -1 * ( $root->height - 8 ) );
		$tweetEntry->font( "configure", "entryFont", "-size", -1 * ( $root->height - 13 ) );
		$tweetEntry->place( -width => ($root->width - $label->Width) );
	}, $rootWindow, $tweetEntry, $label ] );
	Tk::MainLoop();
}

sub updateConfigInfo {

	# Only update once an hour.
	state $lastUpdate = 0;
	return unless time > ($lastUpdate+3600);
	$lastUpdate = time;
	my $oaRequest = Net::OAuth->request( "protected resource" )->new(
		consumer_key     => $consumer_key,
		consumer_secret  => $consumer_secret,
		request_url      => 'https://api.twitter.com/1.1/help/configuration.json',
		request_method   => 'GET',
		signature_method => 'HMAC-SHA1',
		timestamp        => time,
		nonce            => sha256_hex( rand ),
		token            => $token,
		token_secret     => $token_secret,
		);
	$oaRequest->sign();
	my $response = $userAgent->request( GET $oaRequest->to_url() );
	if( !$response->is_success() ) {
		print( STDERR "TWITTER: Error: ".$response->status_line(), "\n" );
		print( STDERR "TWITTER: URL was '".$oaRequest->to_url()."'\n" );
		# Schedule another update for after when the rate limit resets, to avoid making a bunch of failed calls
		$lastUpdate = $response->header( "x-rate-limit-reset" ) - 3599;
		warn( "Failed to retrieve configuration information from twitter; cannot discern the shortened length of URLs. URLs will not be handled specially." );
	} else {
		my $response_data = decode_json $response->content();
		$shortenLengthHttp = $response_data->{ "short_url_length" };
		$shortenLengthHttps = $response_data->{ "short_url_length_https" };
		$maxMediaSize = $response_data->{ "photo_size_limit" };
	}
}

sub clearFromGUI {
	$tweetVar = "";
	# In one shot mode, escape should close the window.
	if( $oneshot ) {
		exit(0);
	}
}

sub validateGo {
	my $content = shift;
	my( $cmd, $num, $text ) = split( / /, $content, 3 );
	$tweetLabel = "GO ...";

	# validate overall format
	return 0 unless $content =~ m!/go [0-9]*( [0-9]*)?$!i;

	# validate tweet #
	return 1 if $num eq "";
	my $tweet = numToTweet( $num );
	my @urls = ( @{$tweet->{ "entities" }->{ "urls" }}, grep { exists $_->{ "url" } } @{$tweet->{ "entities" }->{ "media" }} );
	return 0 unless defined $tweet;

	$text = 1 if (!defined $text || $text eq "");
	return 0 unless $text =~ m/^[0-9]+$/;
	if( $text == 0 || ( !exists( $urls[0] ) && $text == 1 ) ) {
		$tweetLabel = "GO to tweet";
		return 1;
	} elsif( exists $urls[ $text - 1 ] ) {
		my $url = $urls[ $text - 1 ];
		my( $domain ) = split( '/', $url->{ "display_url" }, 2 );
		$tweetLabel = $domain;
		return 1;
	} else {
		return 0;
	}
}

sub tweetGo {
	my $content = shift;

	# Parse command
	my( $cmd, $num, $text ) = split( / /, $content, 3 );
	$text = 1 if (!defined $text || $text eq "");

	# Make sure validation is consistent
	return 0 unless validateGo( $content );

	# Locate tweet, parse URLs out (embedded URLs + media)
	my $tweet = numToTweet( $num );
	my @urls = ( @{$tweet->{ "entities" }->{ "urls" }}, grep { exists $_->{ "url" } } @{$tweet->{ "entities" }->{ "media" }} );

	# This doesn't always fail for validateGo, but should fail here
	my $url;
	if( $text == 0 || ( !exists( $urls[ 0 ] ) && $text == 1 ) ) {
		$url = "https://twitter.com/".$tweet->{ "user" }->{ "screen_name" }."/status/".$tweet->{ "id" };
	} elsif( exists( $urls[ $text - 1 ] ) ) {
		$url = $urls[ $text - 1 ]->{ "url" };
	} else {
		return 0;
	}

	# Call out to x-www-browser, set a temporary tweetLabel, clear tweetVar, return success
	system( 'x-www-browser "'.$url.'"' );
	$tweetLabel = "going...";
	$tweetVar = "";
	return 1;
}


sub validateFave {
	return validateRetweet( @_, "FAVE" );
}

sub validateRetweet {
	my $content = shift;
	my( $cmd, $num, $text ) = split( / /, $content, 3 );
	my $action = (shift or "RT");

	if(defined $num && length($num)==0) {
		$tweetLabel = "$action ...";
		return 1;
	}
	unless( $num =~ m/^[0-9]*$/ ) {
		return 0;
	}
	return 0 if $content =~ m/^[^ ]+ [0-9]+ .*$/;

	my $tweet = numToTweet( $num );
	if( $tweet ) {
		my $id = $tweet->{ "id" };
		$tweetLabel = sprintf( "%s @%s", $action, $tweet->{ "user" }->{ "screen_name" } );

		# Can continue typing numbers, but nothing else.
		if( $content =~ m/^[^ ]+ [^ ]+ / ) {
			return 0;
		}
		return 1;
	} else {
		$tweetLabel = "Bad Tweet Number";
		if( $content =~ m!/[^ ]+ ([0-9]+)] !i ) {
			return 0;
		} else {
			return 1;
		}
	}
}

sub tweetFave {
	my $content = shift;
	my( $cmd, $num, $text ) = split( / /, $content, 3 );

	# Weird looking code. Get the tweet ID from the buffer, refresh the tweet
	# (so we have the latest fave info), and then re-fetch from the buffer.
	my $tweet = numToTweet( $num );
	$tweet = refreshTweet( $tweet->{ "id" } );
	$tweet = numToTweet( $num );

	unless( $tweet ) {
		$tweetLabel = "Bad Tweet Number";
		return 0;
	}

	my $result;
	if( $tweet->{ "favorited" } ) {
		$result = postSigned( 'https://api.twitter.com/1.1/favorites/destroy.json', { "id" => $tweet->{ "id" }, "include_entities" => "false" } );
	} else {
		$result = postSigned( 'https://api.twitter.com/1.1/favorites/create.json', { "id" => $tweet->{ "id" }, "include_entities" => "false" } );
	}

	if( $result == 200 ) {
		$tweetVar = "";
		return 1;
	} elsif( $result == 403 ) {
		$tweetVar = "";
		return 1;
	} else {
		$tweetLabel = "ERROR $result";
		return 0;
	}
}

sub tweetRetweet {
	my $content = shift;
	my( $cmd, $num, $text ) = split( / /, $content, 3 );
	my $tweet = numToTweet( $num );
	unless( $tweet ) {
		$tweetLabel = "Bad Tweet Number";
		return 0;
	}

	my $id = $tweet->{ "id" };

	my $extra = {
		trim_user => 1,
	};

	my $oaRequest = Net::OAuth->request( "protected resource" )->new(
		consumer_key     => $consumer_key,
		consumer_secret  => $consumer_secret,
		request_url      => 'https://api.twitter.com/1.1/statuses/retweet/'.$id.'.json',
		request_method   => 'POST',
		signature_method => 'HMAC-SHA1',
		timestamp        => time,
		nonce            => sha256_hex( rand ),
		token            => $token,
		token_secret     => $token_secret,
		extra_params     => $extra,
	);

	$oaRequest->sign();

	if( $dryrun ) {
		print( "Not actually tweeting.\n" );
		$tweetVar = "";
		return 1;
	} else {
		my $response = $userAgent->request( POST $oaRequest->to_url() );
		if( !$response->is_success() ) {
			warn( "Something bad happened: ".$response->status_line() );
			if( $response->code == "401" ) {
				warn( "More specifically, it was a 401- this usually means $0 was de-authorized." );
				print( STDERR "If you think this might be the case, please try deleting ".$ENV{"HOME"}."/.twipper.secret and running me again.\n" );
			}
			return 0;
		}
	}

	$tweetVar = "";
	return 1;
}

sub validateReply {
	my $content = shift;
	my( $cmd, $num, $text ) = split( / /, $content, 3 );
	my $tweet = numToTweet( $num );
	if( $tweet ) {
		my $id = $tweet->{ "id" };
		my $len = 2+length( $tweet->{ "user" }->{ "screen_name" } ); # "@" <screen_name> " "
		if( $text ) {
			$len += calculateLength( $text, 0 );
		}
		$tweetLabel = sprintf( "@%s (%d/140)", $tweet->{ "user" }->{ "screen_name" }, $len );
		if( $len <= 140 ) {
			return 1;
		}
		return 0;
	} else {
		$tweetLabel = "Bad Tweet Number";
		if( $content =~ m!/reply ([0-9]+)] !i ) {
			return 0;
		} else {
			return 1;
		}
	}
}

sub tweetReply {
	my $content = shift;
	my( $cmd, $num, $text ) = split( / /, $content, 3 );
	my $tweet = numToTweet( $num );
	unless( defined $tweet ) {
		$tweetLabel = "Bad Tweet Number";
		return 0;
	}
	$tweetVar = "";
	return tweet( "@".($tweet->{ "user" }->{ "screen_name" })." $text", $tweet->{ "id" } );
}


sub validateFromGUI {
	my $content = shift;
	if( $content =~ m!^/([a-z]+) (.*)$!i ) {
		if( exists( $commands{ $1 } ) ) {
			return ($commands{ $1 }->[0])->( $content );
		}
	}

	my $len = calculateLength( $content, 0 );
	if( $len <= 140 ) {
		$tweetLabel = sprintf( "(%d/140)", $len );
		return 1;
	}
	return 0;
}

sub calculateLength {
	my $val = shift;
	my $block = shift;
	my $len = length $val;

	if( $val =~ m'https?://[^\s]+' ) {
		updateConfigInfo();
		if( $shortenLengthHttp != -1 && $shortenLengthHttps != -1 ) {
			my $url_munged_what = $val;
			my $http_placeholder = "x"x$shortenLengthHttp;
			my $https_placeholder = "x"x$shortenLengthHttps;
			$url_munged_what =~ s/http:\/\/[^\s]+/$http_placeholder/g;
			$url_munged_what =~ s/https:\/\/[^\s]+/$https_placeholder/g;
			$len = length $url_munged_what;
		}
	}
	return $len;
}

sub tweetFromGUI {
	my $content = $tweetVar;
	if( $content =~ m!^/([a-z]+) (.*)$!i ) {
		if( exists( $commands{ $1 } ) ) {
			if( ($commands{ $1 }->[1])->( $content ) ) {
				exit(0) if $oneshot;
				return 1;
			} else {
				return 0;
			}
		}
	}

	if( length( $tweetVar ) > 0 ) {
		if( tweet( $tweetVar ) ) {
			$tweetVar = "";
			exit(0) if $oneshot;
			return 1;
		} else {
			return 0;
		}
	}
}

sub getAuth {
	my( $token, $token_secret );
	my $user = shift;
	if( defined $user ) {
		$user = ".$user";
	} else {
		$user = "";
	}

	if( ! -e $ENV{"HOME"}."/.twipper.secret".$user ) {
		print( "You have not yet configured $0. Would you like to do so now? ([Y]/n) " );
		my $response = <STDIN>;
		chomp $response if( $response );
		unless( !$response || $response =~ m/^y?$/i ) {
			print( "Too bad. See you later!\n" );
			exit 0;
		}

		print( "Great! One second, I'm retrieving a request token...\n" );

		my $oaRequest = Net::OAuth->request( "request token" )->new(
			consumer_key     => $consumer_key,
			consumer_secret  => $consumer_secret,
			request_url      => 'https://api.twitter.com/oauth/request_token',
			request_method   => 'POST',
			signature_method => 'HMAC-SHA1',
			timestamp        => time,
			nonce            => sha256_hex( rand ),
			callback         => "oob"
		);

		$oaRequest->sign();

		$response = $userAgent->request( POST $oaRequest->to_url() );

		if( !($response->is_success()) ) {
			warn( "Sorry, something bad happened along the way to Twitter: ".$response->status_line() );
			return;
		}

		my $oaResponse = Net::OAuth->response( 'request token' )->from_post_body( $response->content );

		$token = $oaResponse->token;
		$token_secret = $oaResponse->token_secret;

		print( "Okay, got it! Next, you need to visit this URL to grant me write access to your twitter account:\n\n" );
		print( "http://api.twitter.com/oauth/authorize?oauth_token=$token\n\n" );
		print( "You should receive a PIN once you select 'Allow'. Please enter that PIN: " );
		$response = <STDIN>;
		chomp $response if( $response );

		$oaRequest = Net::OAuth->request( "access token" )->new(
			consumer_key     => $consumer_key,
			consumer_secret  => $consumer_secret,
			request_url      => 'https://api.twitter.com/oauth/access_token',
			request_method   => 'POST',
			signature_method => 'HMAC-SHA1',
			timestamp        => time,
			nonce            => sha256_hex( rand ),
			token            => $token,
			token_secret     => $token_secret,
			verifier         => $response,
		);
		$oaRequest->sign();
		$response = $userAgent->request( POST $oaRequest->to_url() );
		if( !$response->is_success() ) {
			warn( "Oof, sorry. Something bad happened: ".$response->status_line() );
			print( STDERR "This might mean you denied $0 access. If you meant to do that, well, sorry to see you go. Otherwise, please run me again.\n" );
			exit 1;
		}

		$oaResponse = Net::OAuth->response( 'access token' )->from_post_body( $response->content );
		$token = $oaResponse->token;
		$token_secret = $oaResponse->token_secret;

		store [ $token, $token_secret ], $ENV{"HOME"}."/.twipper.secret" or
			die( "Ack! I couldn't save your oauth tokens: $!" );

		print( "Excellent! We're on our way. You shouldn't have to do this again.\n" );
	} else {
		my $arr = retrieve( $ENV{"HOME"}."/.twipper.secret" ) or
			die( "Ack! I couldn't retrieve your oauth tokens: $!" );
		( $token, $token_secret ) = @$arr;
	}
	return ($token,$token_secret);
}

sub tweet {
	my $status = shift;
	my $reply = (shift or undef);
	if( !$status ) {
		if( scalar @ARGV > 0 ) {
			$status = join( ' ', @ARGV );
		} else {
			if( $stdin ) {
				print( "Reading tweet from STDIN...\n" );
				$status = <STDIN>;
				chomp $status;
			} else {
				usage();
			}
		}
	}

	# Calculate length, retrieving the config info in blocking mode if necessary
	my $len = calculateLength( $status, 1 );
	if( $len > 140 ) {
		print( STDERR "Oops! The tweet may not exceed the 140-character limit. You went over by ".($len - 140), "\n" );
		return 0;
	}

	my $extra = {
		status => $status
	};
	if( defined( $reply ) ) {
		$extra->{ "in_reply_to_status_id" } = $reply;
	}
	my $oaRequest = Net::OAuth->request( "protected resource" )->new(
		consumer_key     => $consumer_key,
		consumer_secret  => $consumer_secret,
		request_url      => 'https://api.twitter.com/1.1/statuses/update.json',
		request_method   => 'POST',
		signature_method => 'HMAC-SHA1',
		timestamp        => time,
		nonce            => sha256_hex( rand ),
		token            => $token,
		token_secret     => $token_secret,
		extra_params     => $extra,
	);

	$oaRequest->sign();

	if( $dryrun ) {
		print( "Not actually tweeting.\n" );
		return 1;
	} else {
		my $response = $userAgent->request( POST $oaRequest->to_url() );
		if( !$response->is_success() ) {
			warn( "Something bad happened: ".$response->status_line() );
			if( $response->code == "401" ) {
				warn( "More specifically, it was a 401- this usually means $0 was de-authorized." );
				print( STDERR "If you think this might be the case, please try deleting ".$ENV{"HOME"}."/.twipper.secret and running me again.\n" );
			}
			return 0;
		}
		return 1;
	}
}

sub usage {
	print( "Usage: $0 [-1] [-f] [-c <count>] [-w] [<tweet>]\n\n" );
	print( "    -f, --fetch      Instead of updating Twitter, fetch your personal timeline\n" );
	print( "    -c, --count <#>  Specifies the number of tweets to fetch. The default is 5,\n" );
	print( "                     if not specified.\n" );
	print( "        --wrap <#>   Specifies the number of columns to wrap to. See -i below if\n" );
	print( "                     you'd like a hanging indent to keep things pretty.\n" );
	print( "    -i, --indent <#> Only useful with --wrap, above, specifies the number of spaces\n" );
	print( "                     to use in a hanging indent.\n" );
	print( "        --twoline    Use a special two-line (multi-line, really) mode. This must be\n" );
	print( "                     combined with --wrap. Tweets will be displayed in a neat\n" );
	print( "                     column. The left will show the username and the time delta\n" );
	print( "                     and the right will show the actual tweet. Huzzah!\n" );
	print( "    -s, --stdin      Read and post a tweet from stdin\n" );
	print( "    -w, --window     Run in 'windowed' mode, which means a small window that\n" );
	print( "                     lives forever and lets you post to Twitter.\n" );
	print( "    -1, --one-shot   With --window, only process one command before exiting. Like\n" );
	print( "                     a run dialog, but for Twitter.\n" );
	print( "    -b, --blank      Exit immediately if xscreensaver-command reports the screen\n" );
	print( "                     is blanked. This is handy, since twitter does rate limiting\n" );
	print( "                     per account. If this script is run from conky on multiple\n" );
	print( "                     systems, it becomes much easier to reach this limit. This\n" );
	print( "                     option will prevent the script from running when,\n" );
	print( "                     assumably, the user is away from his or her terminal.\n" );
	print( "    -n, --dry-run    Don't actually tweet, or whatever. Do everything up until\n" );
	print( "                     that point.\n\n" );
	print( "    -u, --user <id>  Specify a different profile than the default. ID is whatever\n" );
	print( "                     you want; it doesn't need to be the Twitter handle.\n" );
	print( "If no flags are specified, the arguments will be joined with a space and posted to twitter.\n\n" );
	print( "The first time it's run, the script will automatically guide the user through the prompts necessary to authorize the client to post and/or retrieve.\n\n" );
	print( "NOTE: The OAuth protocol requires an accurate system clock. If your clock is too far off from Twitter's clock, authorization might fail, either consistently or intermittently. If you're having a problem like this, please try syncing your clock to an NTP server.\n\n" );
	print( "Report bugs to <pdbogen-twipper\@cernu.us>\n" );
	print( "twipper  Copyright (C) 2013 Patrick Bogen\n" );
	print( "This program comes with ABSOLUTELY NO WARRANTY; see COPYING for details. This is free software, and you are welcome to redistribute it under certain conditions; see COPYING for details.\n" );
	exit 0;
}

sub fetch {
	if( $count < 1 ) {
		print( STDERR "Funny. I can't retrieve less than one tweet.\n" );
		exit 1;
	}
	my $oaRequest = Net::OAuth->request( "protected resource" )->new(
		consumer_key     => $consumer_key,
		consumer_secret  => $consumer_secret,
		request_url      => 'https://api.twitter.com/1.1/statuses/home_timeline.json?count='.$count,
		request_method   => 'GET',
		signature_method => 'HMAC-SHA1',
		timestamp        => time,
		nonce            => sha256_hex( rand ),
		token            => $token,
		token_secret     => $token_secret
	);

	$oaRequest->sign();
	my $http_request = HTTP::Request->new( GET => $oaRequest->request_url(), [ "Authorization" => $oaRequest->to_authorization_header() ] );
	my $response = $userAgent->request( $http_request );
	if( !$response->is_success() ) {
		warn( "Something bad happened retrieving ".$oaRequest->request_url().": ".$response->status_line() );
		if( $response->code == "401" ) {
			print( STDERR "More specifically, it was a 401- this usually means $0 was de-authorized.", "\n" );
			print( STDERR "If you think this might be the case, please try deleting ".$ENV{"HOME"}."/.twipper.secret> and running me again.\n" );
		} else {
			print( STDERR "Sent:\n".$http_request->as_string, "\n" );
			print( STDERR "Received:\n".$response->as_string, "\n" );
		}
		exit 1;
	}
	my $content = from_json( $response->content );
	my @now = System_Clock(1);

	my $namelen = 0;
	my $numlen = 0;
	for my $tweet (reverse @$content) {
		my $l = length $tweet->{ 'user' }->{ 'screen_name' };
		my $n = length( sprintf( "#%d", tweetToNum( $tweet ) ) );
		$namelen = $l if( $l > $namelen );
		$numlen = $n if( $n > $numlen );
	}
	$namelen += 2; # Two for the ": " that follows names

	if( $twoline ) {
		die( "names are too long, can't continue in twoline mode with this wrap size! ($namelen >= $wrap)" ) if $namelen >= $wrap;
		$Text::Wrap::columns = ( $wrap - $namelen );
	}

	if( $indent == 0 ) {
		$indent = 9 + $namelen;
	}


	my( $hsep, $vsep, $isect ) = ( " ", " ", " " );
	if( $drawlines ) {
		$hsep = "-"; $vsep = "|"; $isect = "+";
	}
	print( ($hsep)x($namelen-2).$isect.($hsep)x($wrap-$namelen+1)."\n" ) if $drawlines;

	for my $tweet (@$content) {
		my @date = split( / /, $tweet->{ "created_at" } );
		my $line = "";
		my $delta;
		my $num = tweetToNum( $tweet );
		@date = Delta_DHMS( $date[5], Decode_Month( $date[1] ), $date[2], split( /:/, $date[3] ), @now[0..5] );
		if( $date[0] > 0 ) {
			$delta = sprintf( "%2dd", $date[0] );
		} elsif( $date[1] > 0 ) {
			$delta = sprintf( "%2dh", $date[1] );
		} elsif( $date[2] > 0 ) {
			$delta = sprintf( "%2dm", $date[2] );
		} else {
			$delta = sprintf( "%2ds", $date[3] );
		}
		$tweet->{ 'text' } =~ s/&lt;/</gi;
		$tweet->{ 'text' } =~ s/&gt;/>/gi;
		$tweet->{ 'text' } =~ s/&amp;/&/gi;
		$tweet->{ 'text' } =~ s/\n/ /gs;
		if( $twoline ) {
			my @lines = split( /\n/s, Text::Wrap::wrap( "", "", $tweet->{ 'text' } ) );
			printf( "%".($namelen-1)."s%s\n", $tweet->{ 'user' }->{ 'screen_name' }.$vsep, shift @lines );
			printf( "%".($namelen-2)."s".$vsep."%s\n", $delta." ago", ($lines[0]?shift @lines:"") );
			printf( "%".($namelen-2)."s".$vsep."%s\n", ($tweet->{ "favorited" }?"*":" ")." #".$num, ($lines[0]?shift @lines:"") );
			for my $line( @lines ) {
				print( " "x($namelen-2).$vsep."$line\n" );
			}
			print( ($hsep)x($namelen-2).$isect.($hsep)x($wrap-$namelen+1)."\n" );
		} else {
			$line = sprintf( "%s %".$numlen."s, $delta ago, %".$namelen."s%s\n", $tweet->{ "favorited" }?"*":" ", "#".$num, $tweet->{ 'user' }->{ 'screen_name' }.": ", $tweet->{ 'text' } );
			if( $wrap != 0 ) {
				print( Text::Wrap::wrap( "", " " x $indent, $line ) );
			} else {
				print( $line );
			}
		}
	}
	exit 0;
}

sub numToTweet {
	state $mtime = 0;
	state $buffer = undef;
	my $num = shift;
	return undef unless defined $num && $num =~ /^[0-9]+$/;

	my $file_mtime = (stat( $ENV{"HOME"}."/.twipper.refs" ))[9] ;
	if( $file_mtime > $mtime ) {
		$buffer = retrieve( $ENV{"HOME"}."/.twipper.refs" ) or
			return undef;
	}
	return $buffer->{ $num }->[1];
}

sub tweetToNum {
	my $tweet = shift;
	my $id = $tweet->{ "id" };
	state $buffer;
	if( -e $ENV{"HOME"}."/.twipper.refs" ) {
		eval {
			$buffer = retrieve( $ENV{"HOME"}."/.twipper.refs" )
				unless defined $buffer;
		}; warn $@ if $@;
	}

	$buffer = { begin => 0, end => 0 }
		unless defined $buffer;

	my $begin = $buffer->{ "begin" };
	my $end = $buffer->{ "end" };

	# If begin and end are equal, the buffer is empty. Otherwise, search the
	# buffer for the tweet ID, update the stored tweet if found and return the
	# index.

	if( $end < $begin ) {
		for( my $i = $begin; $i < 100; $i++ ) {
			if( $buffer->{ $i }->[0] == $id ) {
				$buffer->{ $i }->[1] = $tweet;
				store( $buffer, $ENV{"HOME"}."/.twipper.refs" );
				return $i;
			}
		}
		for( my $i = 0; $i <= $end; $i++ ) {
			if( $buffer->{ $i }->[0] == $id ) {
				$buffer->{ $i }->[1] = $tweet;
				store( $buffer, $ENV{"HOME"}."/.twipper.refs" );
				return $i;
			}
		}
	} elsif( $end > $begin ) {
		for( my $i = $begin; $i < $end; $i++ ) {
			if( $buffer->{ $i }->[0] == $id ) {
				$buffer->{ $i }->[1] = $tweet;
				store( $buffer, $ENV{"HOME"}."/.twipper.refs" );
				return $i;
			}
		}
	}

	$end++;
	if( $end == 100 ) {
		$end = 0;
	}
	if( $end == $begin ) {
		$begin++;
		if( $begin == 100 ) {
			$begin = 0;
		}
	}
	$buffer->{ $end-1 } = [ $id, $tweet ];
	$buffer->{ "end" } = $end;
	store( $buffer, $ENV{"HOME"}."/.twipper.refs" );
	return $end-1;
}

sub postSigned {
	my $url = shift or die( "postSigned called without a URL" );
	my $extra = shift;
	die( "extra parameters not a hashref" ) unless ref($extra) eq "HASH";

	my $oaRequest = Net::OAuth->request( "protected resource" )->new(
		consumer_key     => $consumer_key,
		consumer_secret  => $consumer_secret,
		request_url      => $url,
		request_method   => 'POST',
		signature_method => 'HMAC-SHA1',
		timestamp        => time,
		nonce            => sha256_hex( rand ),
		token            => $token,
		token_secret     => $token_secret,
		extra_params     => $extra,
	);

	$oaRequest->sign();

	if( $dryrun ) {
		print( "not actually POSTing.\n" );
		return 200;
	} else {
		my $response = $userAgent->request( POST $oaRequest->to_url() );
		if( !$response->is_success() ) {
			warn( "Something bad happened: ".$response->status_line() );
			print( STDERR $response->content );
			if( $response->code == "401" ) {
				warn( "More specifically, it was a 401- this usually means $0 was de-authorized." );
				print( STDERR "If you think this might be the case, please try deleting ".$ENV{"HOME"}."/.twipper.secret and running me again.\n" );
			} elsif( $response->code >= 400 && $response->code < 500 ) {
				warn( "400-series response code indicates a problem with this request" );
				print( STDERR $response->as_string );
			}
		}
		return $response->code();
	}
}

sub refreshTweet {
	my $id = shift or die( "refreshTweet called without tweet ID" );
	die( "refreshTweet called with non-numeric tweet ID" ) unless $id =~ m/^[0-9]+$/;

	my $oaRequest = Net::OAuth->request( "protected resource" )->new(
		consumer_key     => $consumer_key,
		consumer_secret  => $consumer_secret,
		request_url      => 'https://api.twitter.com/1.1/statuses/show.json',
		request_method   => 'GET',
		signature_method => 'HMAC-SHA1',
		timestamp        => time,
		nonce            => sha256_hex( rand ),
		token            => $token,
		token_secret     => $token_secret,
		extra_params     => { id => $id },
	);

	$oaRequest->sign();

	my $response = $userAgent->request( GET $oaRequest->to_url() );
	if( $response->is_success() ) {
		my $tweet = from_json( $response->content );
		tweetToNum( $tweet );
	} else {
		warn( "Something bad happened: ".$response->status_line() );
		if( $response->code == "401" ) {
			warn( "More specifically, it was a 401- this usually means $0 was de-authorized." );
			print( STDERR "If you think this might be the case, please try deleting ".$ENV{"HOME"}."/.twipper.secret and running me again.\n" );
		} elsif( $response->code >= 400 && $response->code < 500 ) {
			warn( "400-series response code indicates a problem with this request" );
			print( STDERR $response->content );
		}
	}
	return $response->code();
}
