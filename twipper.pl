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

use Module::Load::Conditional qw( can_load );
use Net::OAuth;
$Net::OAuth::PROTOCOL_VERSION = Net::OAuth::PROTOCOL_VERSION_1_0A;
use Digest::SHA qw( sha256_hex );
use HTTP::Request::Common;
use LWP::UserAgent;
use Storable;
use Getopt::Long;
use Data::Dumper;
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
my $shortenLengthHttp=-1;
my $shortenLengthHttps=-1;

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
) or usage();

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

my( $token, $token_secret ) = getAuth();

my $tweetVar = "";
my $tweetLabel = "(0/140)";

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

	my $rootWindow = MainWindow->new;
	$rootWindow->title( "twipper.pl: tweet" );
	$rootWindow->bind( "<Control-q>" => [ sub { exit(0); } ] );
	my $tweetEntry = $rootWindow->Entry( -textvariable => \$tweetVar, -validate => "all", -vcmd => \&validateFromGUI, -font => $rootWindow->fontCreate( "entryFont" ) );
	$tweetEntry->bind( "<Return>" => \&tweetFromGUI );
	$tweetEntry->bind( "<Escape>" => \&clearFromGUI );
	$tweetEntry->after( 1000, \&updateConfigInfo );
	$tweetEntry->after( 3600000, \&updateConfigInfo );
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
		die( "Failed to retrieve configuration information from twitter; cannot discern the shortened length of URLs. URLs will not be handled specially." );
	} else {
		my $response_data = decode_json $response->content();
		$shortenLengthHttp = $response_data->{ "short_url_length" };
		$shortenLengthHttps = $response_data->{ "short_url_length_https" };
	}
}

sub clearFromGUI {
	$tweetVar = "";
}

sub validateFromGUI {
	my $len = calculateLength( shift, 0 );
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
	if( ( $shortenLengthHttp == -1 || $shortenLengthHttps == -1 ) && $block ) {
		updateConfigInfo();
	}
	if( $shortenLengthHttp != -1 && $shortenLengthHttps != -1 ) {
		my $url_munged_what = $val;
		my $http_placeholder = "x"x$shortenLengthHttp;
		my $https_placeholder = "x"x$shortenLengthHttps;
		$url_munged_what =~ s/http:\/\/[^\s]+/$http_placeholder/g;
		$url_munged_what =~ s/https:\/\/[^\s]+/$https_placeholder/g;
		$len = length $url_munged_what;
	}
	return $len;
}

sub tweetFromGUI {
	if( length( $tweetVar ) > 0 ) {
		tweet( $tweetVar );
		$tweetVar = "";
	}
}

sub getAuth {
	my( $token, $token_secret );

	if( ! -e <~/.twipper.secret> ) {
		print( "You have not yet configured $0. Would you like to do so now? ([Y]/n) " );
		my $response = <>;
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
		$response = <>;
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
		
		store [ $token, $token_secret ], <~/.twipper.secret> or
			die( "Ack! I couldn't save your oauth tokens: $!" );
	
		print( "Excellent! We're on our way. You shouldn't have to do this again.\n" );
	} else {
		my $arr = retrieve( <~/.twipper.secret> ) or
			die( "Ack! I couldn't retrieve your oauth tokens: $!" );
		( $token, $token_secret ) = @$arr;
	}
	return ($token,$token_secret);
}

sub tweet {
	my $status = shift;
	if( !$status ) {
		if( scalar @ARGV > 0 ) {
			$status = join( ' ', @ARGV );
		} else {
			if( $stdin ) {
				print( "Reading tweet from STDIN...\n" );
				$status = <>;
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
		return 1;
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
		extra_params => {
			status => $status
		}
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
				print( STDERR "If you think this might be the case, please try deleting ".<~/.twipper.secret>." and running me again.\n" );
			}
			return 1;
		}
	}

	return 0;
}

sub usage {
	print( "Usage: $0 [-f] [-c <count>] [-w] [<tweet>]\n\n" );
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
	print( "    -b, --blank      Exit immediately if xscreensaver-command reports the screen\n" );
	print( "                     is blanked. This is handy, since twitter does rate limiting\n" );
	print( "                     per account. If this script is run from conky on multiple\n" );
	print( "                     systems, it becomes much easier to reach this limit. This\n" );
	print( "                     option will prevent the script from running when,\n" );
	print( "                     assumably, the user is away from his or her terminal.\n" );
	print( "    -n, --dry-run    Don't actually tweet, or whatever. Do everything up until\n" );
	print( "                     that point.\n\n" );
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
			print( STDERR "If you think this might be the case, please try deleting ".<~/.twipper.secret>." and running me again.\n" );
		} else {
			print( STDERR "Sent:\n".$http_request->as_string, "\n" );
			print( STDERR "Received:\n".$response->as_string, "\n" );
		}
		exit 1;
	}
	my $content = from_json( $response->content );
	my @now = System_Clock(1);

	my $namelen = 0;
	for my $tweet (@$content) {
		my $l = length $tweet->{ 'user' }->{ 'screen_name' };
		$namelen = $l if( $l > $namelen );
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
			for my $line( @lines ) {
				print( " "x($namelen-2).$vsep."$line\n" );
			}
			print( ($hsep)x($namelen-2).$isect.($hsep)x($wrap-$namelen+1)."\n" );
		} else {
			$line = sprintf( "$delta ago, %".$namelen."s%s\n", $tweet->{ 'user' }->{ 'screen_name' }.": ", $tweet->{ 'text' } );
			if( $wrap != 0 ) {
				print( Text::Wrap::wrap( "", " " x $indent, $line ) );
			} else {
				print( $line );
			}
		}
	}
	exit 0;	
}
