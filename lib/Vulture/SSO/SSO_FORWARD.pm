#file:SSO/SSO_FORWARD.pm
#-------------------------
#!/usr/bin/perl
package SSO::SSO_FORWARD;

use strict;
use warnings;

BEGIN {
    use Exporter ();
    our @ISA       = qw(Exporter);
    our @EXPORT_OK = qw(&forward);
}

use Apache2::RequestRec ();
use Apache2::RequestIO  ();
use Apache2::Connection ();

use Apache2::Log;
use Apache2::Reload;

use LWP::UserAgent;
use WWW::Mechanize;
use WWW::Mechanize::GZip;
use HTTP::Request;
use HTML::Form;

use Apache2::Const -compile => qw(OK REDIRECT FORBIDDEN);

use Core::VultureUtils qw(&session &get_app_cookies &get_cookie &get_mech_object &get_ua_object);
use Core::VultureUtils_Kerberos qw(&getKerberosServiceToken);
use SSO::ProfileManager qw(&get_profile &delete_profile);

use Apache::SSLLookup;
use MIME::Base64;

use APR::URI;
use APR::Table;
use APR::SockAddr;

use URI::Escape;
use List::Util;

use Try::Tiny;

sub rewrite_uri {    # Rewrite uri for being valid
    my ( $r, $app, $uri, $real_post_url, $log ) = @_;
    my $hostname = $app->{name};
    if ( $app->{name} =~ /([^\/]*)\// ) {
        $hostname = $1;
    }
    if ( $uri !~ /^(http|https):\/\/(.*)/ ) {
        if ( $uri =~ /^\/(.*)/ ) {
	   return $uri;
        }
        else {
	    my $rewrite_uri2 = APR::URI->parse( $r->pool, $real_post_url );
	    my $rpath = $rewrite_uri2->path();
            $rpath =~ s/[^\/]+$/$uri/g;
	    return $rpath;
        }
    }
    else{
        my $rewrite_uri = APR::URI->parse( $r->pool, $uri );
        $rewrite_uri->hostname($hostname);
        $rewrite_uri->scheme($r->is_https ? 'https' : 'http');
        $rewrite_uri->port( $r->connection->local_addr->port );
        return $rewrite_uri->unparse;
    }
}

sub handle_action {
    my ( $r, $log, $dbh, $app, $response, $user ) = @_;

    my ( $query, $type, $options );
    $query =
'SELECT is_in_url, is_in_url_action, is_in_url_options, is_in_page, is_in_page_action, is_in_page_options, is_in_url_redirect, is_in_url_redirect_action, is_in_url_redirect_options FROM sso, app WHERE app.id = ? AND sso.id = app.sso_forward_id';
    my $sth = $dbh->prepare($query);
    $sth->execute( $app->{id} );
    my (
        $is_in_url,          $is_in_url_action,
        $is_in_url_options,  $is_in_page,
        $is_in_page_action,  $is_in_page_options,
        $is_in_url_redirect, $is_in_url_redirect_action,
        $is_in_url_redirect_options
    ) = $sth->fetchrow;
    $sth->finish();

    #Check if action is needed (grep in url, grep in page or by return code)
    if ( $is_in_url and $r->unparsed_uri =~ /$is_in_url/ ) {
        $type    = $is_in_url_action;
        $options = $is_in_url_options;
    }
    elsif ( $is_in_page and $response->as_string =~ /$is_in_page/ ) {
        $type    = $is_in_page_action;
        $options = $is_in_page_options;
    }
    elsif ( $response->headers->header('Location')
        and $is_in_url_redirect
        and $response->headers->header('Location') =~ /$is_in_url_redirect/ )
    {
        $type    = $is_in_url_redirect_action;
        $options = $is_in_url_redirect_options;

        # Headers
    }
    else {
        if ( $response->is_info ) {
            # 10x headers
            $query =
'SELECT is_info, is_info_options FROM sso JOIN app ON sso.id = app.sso_forward_id WHERE app.id = ?';
        }
        elsif ( $response->is_success ) {
            # 20x headers
            $query =
'SELECT is_success, is_success_options FROM sso JOIN app ON sso.id = app.sso_forward_id WHERE app.id = ?';
        }
        elsif ( $response->is_redirect ) {
            # 30x headers
            $query =
'SELECT is_redirect, is_redirect_options FROM sso JOIN app ON sso.id = app.sso_forward_id WHERE app.id = ?';
        }
        elsif ( $response->is_error ) {
            # 40x and 50x headers
            $query =
'SELECT is_error, is_error_options FROM sso JOIN app ON sso.id = app.sso_forward_id WHERE app.id = ?';
        }
        # No action defined
        $log->debug($query);

        $sth = $dbh->prepare($query);
        $sth->execute( $app->{id} );
        ( $type, $options ) = $sth->fetchrow;
        $sth->finish();
    }

    my $followredirect=1;

    #Trigger action to do
    if ($type) {
        $log->debug( $type . ' => ' . $options );
        if ( $type eq 'message' ) {
            $r->content_type('text/html');
            if ($options) {
                $r->print($options);
            }
            else {
                $r->print( $response->content );
            }
            return Apache2::Const::OK;
        }
        elsif ( $type eq 'log' ) {
            $log->debug( 'Response from app : ' . $response->as_string );
        }
        elsif ( $type eq 'redirect' ) {
            $r->headers_out->set( 'Location' => $options );
            $r->status(302);
            return Apache2::Const::REDIRECT;
        }
        elsif ( $type eq 'relearning' ) {
            SSO::ProfileManager::delete_profile( $r, $log, $dbh, $app, $user );
            $log->debug(
                'Pattern detected, deleting profile and relearning credentials'
            );
            $r->pnotes( 'SSO_Forwarding' => 'LEARNING' );
	    my $redir = $r->hostname . $r->unparsed_uri;
	    if ($r->is_https) {
	    	$redir = 'https://'.$redir; 
	    }
	    else {
		$redir = 'http://'.$redir;
	    }
	    $log->debug('Redirecting to ' .$redir );
	    #$r->headers_out->add( 'Location' => $r->unparsed_uri );
	    $r->headers_out->add( 'Location' => $redir );

            #Set status
            $r->status(302);
            return Apache2::Const::REDIRECT;
        }
        elsif ( $type eq 'nofollowredirect' ) {
            $followredirect=0;
        }

    }

#If no action defined, redirect client to Location header (if defined) or to the /
#	my $redirect = $r->unparsed_uri;

    my $redirect = "http://" . $r->hostname;
    my $rewrite_uri = APR::URI->parse( $r->pool, $redirect );
    $rewrite_uri->scheme('http');
    $rewrite_uri->scheme('https') if $r->is_https;
    $rewrite_uri->port( $r->get_server_port() );
    $rewrite_uri->path( $r->unparsed_uri );
    $redirect = $rewrite_uri->unparse;
    if ( $response->headers->header('Location') and $followredirect == 1 ) {
        $redirect = SSO::SSO_FORWARD::rewrite_uri(
            $r, $app,
            $response->headers->header('Location'),
            $app->{url} . $app->{logon_url}, $log
        );
        $log->debug("Changing redirect to $redirect");
    }

    $log->debug("Ending SSO Forward");
    $r->pnotes( 'SSO_Forwarding' => undef );
    $r->headers_out->add( 'Location' => $redirect );
    $r->status(302);
    return Apache2::Const::REDIRECT;
}

sub forward {
    my ( $package_name, $r, $log, $dbh, $app, $user, $password ) = @_;

    $r = Apache::SSLLookup->new($r);
    my $mc_conf = $r->pnotes('mc_conf');
    my (%session_app);
    Core::VultureUtils::session( \%session_app, undef,
        $r->pnotes('id_session_app'),
        $log, $mc_conf, $app->{update_access_time} );

    my %headers_vars = (
        2  => 'SSL_CLIENT_I_DN',
        3  => 'SSL_CLIENT_M_SERIAL',
        4  => 'SSL_CLIENT_S_DN',
        5  => 'SSL_CLIENT_V_START',
        6  => 'SSL_CLIENT_V_END',
        7  => 'SSL_CLIENT_S_DN_C',
        8  => 'SSL_CLIENT_S_DN_ST',
        9  => 'SSL_CLIENT_S_DN_Email',
        10 => 'SSL_CLIENT_S_DN_L',
        11 => 'SSL_CLIENT_S_DN_O',
        12 => 'SSL_CLIENT_S_DN_OU',
        13 => 'SSL_CLIENT_S_DN_CN',
        14 => 'SSL_CLIENT_S_DN_T',
        15 => 'SSL_CLIENT_S_DN_I',
        16 => 'SSL_CLIENT_S_DN_G',
        17 => 'SSL_CLIENT_S_DN_S',
        18 => 'SSL_CLIENT_S_DN_D',
        19 => 'SSL_CLIENT_S_DN_UID',
    );

    $log->debug("########## SSO_FORWARD ##########");

    my $config = $r->pnotes('config');
    $log->debug(
        "LWP::UserAgent is emulating post request on " . $app->{name} );

    #Getting SSO type
    my $sso_forward_type        = $app->{'sso'}->{'type'};
    my $sso_follow_get_redirect = $app->{'sso'}->{'follow_get_redirect'};
    my $sso_is_post             = $app->{'sso'}->{'is_post'};
    my $sso_verify_mech_cert    = $app->{'sso'}->{'verify_mech_cert'};

   if ($sso_verify_mech_cert eq '') {
	$sso_verify_mech_cert=1;
   }

    $log->debug( "SSO_FORWARD_TYPE=" . $sso_forward_type );
    $log->debug( "SSO_VERIFY_CERT=" . $sso_verify_mech_cert );

    my %ssl_opts = (
        verify_hostname => $sso_verify_mech_cert,
    );
    my $SSL_ca_file = $config->get_key('SSL_ca_file')||'';
    if ($SSL_ca_file){
        $ssl_opts{SSL_ca_file} = $SSL_ca_file;
    }
    #Setting browser
    my ( $mech, $response, $post_response, $request);

    my $cleaned_cookies = Core::VultureUtils::get_app_cookies($r);
    my $route = '';
    if ($app->{Balancer_Activated}){
        $route = Core::VultureUtils::get_cookie($r->headers_in->{Cookie},$app->{Balancer_Stickyness}. '=([^;]*)' ) || '' ;
        # if stickiness cookies contains a dot, route begins after it
        # see https://httpd.apache.org/docs/2.2/mod/mod_proxy_balancer.html#stickyness_implementation
        if ($route){
            $route =~ s/^[^.]*\.//g;
            $log->debug("route: $route");
        }
    }
    $mech = Core::VultureUtils::get_mech_object($r,$app->{remote_proxy}, $sso_verify_mech_cert);

    $mech->delete_header('Cookie');
    $mech->add_header( 'Cookie', $cleaned_cookies ) if ($cleaned_cookies ne '');

    #$mech->cookie_jar->set_cookie( $cleaned_cookies );
    $mech->delete_header('Host');
    $mech->add_header( 'Host' => $r->headers_in->{'Host'} );

    #Setting proxy if needed
    if ( $app->{remote_proxy} ne '' ) {
        $ENV{HTTPS_PROXY} = $app->{remote_proxy};
        $ENV{HTTP_PROXY}  = $app->{remote_proxy};
    }

    # The base url of the app we'll connect to 
    my $base_url = $app->{url};

    if ( $app->{url} =~ /balancer:\/\// ) {
        # We cannot pass a balancer:// uri to LWP user agentt
        # So for now, Vulture does mod_balancer job, and choose the route
        # So we'll have to set the stickiness cookie later 
        my @urls = split( ';', $app->{Balancer_Node} );
        my $u;
        my @shuffled;
        if ( $route eq '' ) {
            @shuffled = List::Util::shuffle(@urls);
            my @row = split( ' ', $shuffled[0] );
            $base_url = $row[0];
            foreach $r (@row) {
                if ( $r =~ /route=(.*)/ ) {
                    # Now I see the reason: mod_proxy_balancer will use only the part of the cookie 
                    # that is after the first dot as the route.
                    $route = "$1";
                }
            }
        }
        else {
            foreach $u (@urls) {
                if ( $u =~ /^\s*([^\s]+).*\s+route=.*$route/ ) {
                    $base_url = $1;
                    last;
                }
            }
        }
    }

    #Just send request with Authorization
    if ( $sso_forward_type eq 'sso_forward_htaccess' ) {
        $request = HTTP::Request->new( GET => $base_url . $app->{logon_url} );

        $request->push_header( 'Referer' => '-' );

        #Sending Authorization header if needed by SSO forward type
        $request->push_header( 'Authorization' => "Basic "
              . encode_base64( $user . ':' . $password ) );

        #Get form first then POST infos, only if we don't wan't to post directly
    }
    #Send request with kerberos Authorization header 
    elsif ( $sso_forward_type eq 'sso_forward_kerberos' ) {
        $log->debug("::forward: sso_type = sso_forward_kerberos => request kerberos service token");

        $request = HTTP::Request->new( GET => $base_url . $app->{logon_url} );
        $request->push_header( 'Referer' => '-' );

        my $token = Core::VultureUtils_Kerberos::getKerberosServiceToken($log, $r, $dbh, $app, $user, $password);
        if ( $token ) {
            $log->debug("::forward: sso_type = sso_forward_kerberos => set kerberos service token in authorization header");

            #Sending Negotiate (Kerberos) Authorization header
            $request->push_header( 'Authorization' => "Negotiate " . encode_base64($token,"") );
        } else {
            $log->debug("::forward: sso_type = sso_forward_kerberos => request kerberos service token failed");
        }
    }
    elsif ( ( int($sso_is_post) != 1 ) ) {
        $log->debug("Automatic POST enabled");

        #Push user-agent, etc.
        #Get login page in order to fill the form and click the submit buttom
        $mech->delete_header('User-Agent');
        $mech->add_header( 'User-Agent' => $r->headers_in->{'User-Agent'} );
        my $sth =
          $dbh->prepare("SELECT name, type, value FROM header WHERE app_id= ?");
        $sth->execute( $app->{id} );

        #Push specific headers to get the right form
        while ( my ( $name, $type, $value ) = $sth->fetchrow ) {
            if ( $type eq "REMOTE_ADDR" ) {
                $value = $r->connection->remote_ip;

                #Nothing to do
            }
            elsif ( $type eq "CUSTOM" ) {

                #Types related to SSL
            }
            else {
                $value = $r->ssl_lookup( $headers_vars{$type} )
                  if ( exists $headers_vars{$type} );
            }

            #Try to push custom headers
            try {
			$request->remove_header($name);
			$request->push_header($name => $value);
			$mech->delete_header($name);
			$mech->add_header($name => $value);
			$log->debug("Pushing custom header $name => $value");
            }
	    catch {
		$log->debug("Unable to push custom header $name => $value");
	    }
        }
        $sth->finish();

        #Get the form page if no redirect follow
        if ( int($sso_follow_get_redirect) != 1 ) {
            $mech->max_redirect(0);
        }
        $mech->add_header( 'Host' => $r->headers_in->{'Host'} );

        #get 'get' response
        $response = $mech->get( $base_url . $app->{logon_url} );

        $log->debug( $response->request->as_string );
        $log->debug( $response->as_string );

        $log->debug("This is cookie that we get from GET request ". $mech->cookie_jar->as_string);
        foreach ( split( "\n", $mech->cookie_jar->as_string ) ) {
            if (/([^,; ]+)=([^,; ]*)/) {
                $cleaned_cookies .= $1 . "=" . $2 . ";";
                $log->debug( "ADD/REPLACE " . $1 . "=" . $2 );
            }
        }
        #Get profile
        my %results =
          %{ SSO::ProfileManager::get_profile( $r, $log, $dbh, $app, $user ) };

        #Get form which contains fields set in admin
        #while (my ($key, $value) = each(%results)){
		while (my ($key, @vals) = each(%results)){
			my ($value,$type) = ($vals[0][0],$vals[0][1]);
			$log->debug($key);
			if ($type eq "cookie") {
				$cleaned_cookies = "$key=$value;$cleaned_cookies";
				$r->err_headers_out->add('set-cookie' => $key."=".$value."; path=/");
				delete($results{$key});
			}
		}

        #Get the form input that we are interested in
        my $form = $mech->form_with_fields( keys %results ) if %results;

        #Fill form with profile
        if ($form and %results){
            my $gotclick = 0;
            foreach my $inputis ($form->inputs){
                $log->debug("FWD: look click in ".$inputis->type);
                if ( $inputis->type eq 'submit') {
                    $gotclick = 1;
                    $log->debug("Setting got click to 1");
                }
                
            }
            while (my ($key, $value) = each(%results)){
                $mech->field($key, $value);
            }
            #Simulate click
            if ($gotclick == 1){
                    $log->debug("using form click");
                    $request = $form->click();
            }
            else{
                $log->debug("using form make request");
                $request = $form->make_request();
            }
        }
        else {
            return Apache2::Const::OK;
        }
    }
    #Direct POST
    else {
        $log->debug(
            "Direct POST enable: Old way to authenticate user on remote APP");
        my $post = '';

        #Getting fields from profile
        my %results =
          %{ SSO::ProfileManager::get_profile( $r, $log, $dbh, $app, $user ) };
        if (%results){
			
		while (my ($key, @vals) = each(%results)){
			my ($value,$type) = ($vals[0][0],$vals[0][1]);
#				if ($key =~ /(.*)TMP(.*)/) {
			if ($type eq 'cookie'){
				$cleaned_cookies = "$key=$value;$cleaned_cookies";
				$r->err_headers_out->add('Set-Cookie' => $key."=".$value."; path=/");
				delete($results{$key});
				next;
			}
			#$post .= uri_escape($key)."=".uri_escape($value)."&";
			$post .= uri_escape($key)."=".uri_escape_utf8($value)."&";
		}
		$request = HTTP::Request->new('POST', $base_url.$app->{logon_url}, undef, $post);
		$request->push_header('Content-Type' => 'application/x-www-form-urlencoded');
		#Setting headers
        }
        else {
            return Apache2::Const::OK;
        }
    }

    #Setting headers for both htaccess and normal way
    #Push user-agent, etc.
    $request->push_header( 'User-Agent' => $r->headers_in->{'User-Agent'} );
    #Host header
    $request->push_header( 'Host' => $r->headers_in->{'Host'} );
    if ( defined( $r->headers_in->{'Max-Forwards'} ) ) {
        $request->push_header(
            'Max-Forwards' => $r->headers_in->{'Max-Forwards'} - 1 );
    }
    else {
        $request->push_header( 'Max-Forwards' => '10' );
    }
    if ( defined( $r->headers_in->{'X-Forwarded-For'} ) ) {
        $request->push_header(
            'X-Forwarded-For' => $r->headers_in->{'X-Forwarded-For'} . ", "
              . $r->connection->remote_ip );
    }
    else {
        $request->push_header( 'X-Forwarded-For' => $r->connection->remote_ip );
    }
    $request->push_header( 'X-Forwarded-Host'   => $r->hostname() );
    $request->push_header( 'X-Forwarded-Server' => $r->hostname() );
    #Accept* headers
    $request->push_header( 'Accept' => $r->headers_in->{'Accept'} );
    $request->push_header(
        'Accept-Language' => $r->headers_in->{'Accept-Language'} );
    $request->push_header(
        'Accept-Encoding' => $r->headers_in->{'Accept-Encoding'} );
    $request->push_header(
        'Accept-Charset' => $r->headers_in->{'Accept-Charset'} );
    #We need to parse referer to replace @ IP by hostnames
    my $host = $r->headers_in->{'Host'};
    my $parsed_uri = APR::URI->parse( $r->pool, $base_url . $app->{logon_url} );
    $parsed_uri->scheme('http');
    $parsed_uri->scheme('https') if $r->is_https;
    $parsed_uri->port( $r->get_server_port() );
    $parsed_uri->hostname($host);
    $request->push_header( 'Referer' => $parsed_uri->unparse );

    #Getting custom headers defined in admin
    my $sth =
      $dbh->prepare("SELECT name, type, value FROM header WHERE app_id = ?");
    $sth->execute( $app->{id} );
    while ( my ( $name, $type, $value ) = $sth->fetchrow ) {
        if ( $type eq "REMOTE_ADDR" ) {
            $value = $r->connection->remote_ip;
        }
        elsif ( $type eq "CUSTOM" ) {
        }
        else {
            $value = $r->ssl_lookup( $headers_vars{$type} )
              if ( exists $headers_vars{$type} );
        }

        #Try to push custom headers
        try {
            $request->remove_header($name);
            $request->push_header( $name => $value );
            $log->debug("Pushing custom header $name => $value");
        }
	catch {
		$log->debug("Unable to push custom header $name => $value");
	}
    }
    $sth->finish();
    $request->remove_header('Cookie');
    $request->push_header( 'Cookie' => $cleaned_cookies ) if ($cleaned_cookies ne '') ;    # adding/replace

    #Send !!! simple !!! request (POST or GET (htaccess))
    #The client browser must do the rest
    #This is done after the handler action function
    #$post_response = $mech->request($request);

    #Cookie coming from response and from POST response
    our %cookies_app = ();
	if ((int($sso_is_post) != 1)) {
		$post_response = $mech->request($request);
		#$log->debug($mech->cookie_jar->as_string);
		$mech->cookie_jar->scan( \&SSO::SSO_FORWARD::callback );
	} else {	
		my $ua = LWP::UserAgent->new;
        	while ( my ($k,$v) = each %ssl_opts){
            		try{
                		$ua->ssl_opts ( $k => $v );
            		}
	    		catch {

	    		}
        	}
		$post_response = $ua->request($request);
		foreach ($post_response->headers->header('Set-Cookie')) {
           		if (/([^,; ]+)=([^,; ]*)/) {
                		$cookies_app{$1} = $2;		# ajout/remplacement
                		$log->debug("ADD/REPLACE ".$1."=".$2);
           		}
       		}
	}

	#Keep cookies to be able to log out
	#$session_app{cookie} = join('; ', map { "'$_'=\"${cookies_app{$_}}\"" } keys %cookies_app), "\n";

	foreach my $pr (split("\n",$post_response->content())) {
		if ($pr =~ /document\.cookie='(.*);path=(.*)'/) {
			my ($var,$val,$path);
			($var,$val) = split("=",$1);
			$path=$2;
			$log->debug('Set-Cookie' => $var."=".$val."; domain=".$r->hostname."; path=".$path);
			$r->err_headers_out->add('Set-Cookie' => $var."=".$val."; path=".$path);
		}
	}
    my $path = "/";

    #Pre-send cookies to client after parsing
    if ( $app->{name} =~ /\/(.*)/ ) {
        $path = "/" . $1 . "/";
    }
    foreach my $k ( keys %cookies_app ) {
        $log->debug( "path is " . $path );
        $r->err_headers_out->add( 'Set-Cookie' => $k . "="
              . $cookies_app{$k}
# We'll let the browser set the domain as he likes..
#              . "; domain="
#              . $r->hostname
              . "; path="
              . $path 
        );    # Send cookies to browser's client
        $log->debug( "PROPAG " . $k . "=" . $cookies_app{$k} );
    }
    # We won't set the stickyness cookie if it's already there
    if ( $route ne '' and not exists $cookies_app{$app->{Balancer_Stickyness}} ) {
        $r->err_headers_out->add(
                'Set-Cookie' => $app->{Balancer_Stickyness} . "=" 
              . ".$route"
# We'll let the browser set the domain as he likes..
#              . "; domain="
#              . $r->hostname
              . "; path="
              . $path );
    }

    #Handle action needed
    return SSO::SSO_FORWARD::handle_action( $r, $log, $dbh, $app,
        $post_response, $user );
}

sub callback {
    my (
        $version,   $key,    $val,    $path,    $domain, $port,
        $path_spec, $secure, $expire, $discard, $hash
    ) = @_;
    use vars qw(%cookies_app);
    $cookies_app{$key} = $val;
}
1;
