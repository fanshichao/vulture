#file:Core/TransHandlerv2.pm
#-------------------------
#!/usr/bin/perl
package Core::TransHandlerv2;

use strict;
use warnings;

use Apache2::Reload ;
use Apache2::Response;
use Apache2::RequestRec;
use Apache2::RequestIO;
use Apache2::RequestUtil;
use Apache::SSLLookup;
use Apache2::Const -compile => qw(OK FORBIDDEN REDIRECT DONE NOT_FOUND);
use Core::VultureUtils qw(&get_memcached_conf &get_app &get_intf &version_check &get_cookie 
   &session &get_translations &get_style &load_module 
   &get_memcached &set_memcached &decrypt);
use Core::VultureUtils_Kerberos qw(&getKerberosServiceToken);
use Core::Log qw(&new &debug &error);
use Core::Config qw(&new &get_key);
use MIME::Base64 ;

use APR::URI;
use APR::Table;
use APR::SockAddr;

use DBI ;

use Try::Tiny;

sub handler {

    my $r            = Apache::SSLLookup->new(shift);
    my $protocol     = $r->protocol();
    my $dbh          = DBI->connect( $r->dir_config('VultureDSNv3') );
    my $log = Core::Log->new($r);
    my $config = Core::Config->new($dbh);
    my $mc_conf = Core::VultureUtils::get_memcached_conf($config);

    #Sending db handler to next Apache Handlers, always needed
    $r->pnotes( 'dbh'     => $dbh );
    $r->pnotes( 'log'     => $log );
    $r->pnotes( 'config'  => $config );
    $r->pnotes( 'mc_conf' => $mc_conf );
    
    $log->debug("########## TransHandler ($protocol|"
            . $r->hostname.$r->uri."|".$r->dir_config('VultureID').")");
    #protocol check
    if ( $protocol !~ /^HTTP\/[0-9]\.[0-9]$/ ) {
        $log->error("Rejecting bad protocol $protocol");
        return Apache2::Const::FORBIDDEN;
    }
    #version check
    unless ( Core::VultureUtils::version_check($config) ) {
        $log->error("Database version is not up-to-date. Can't load Vulture");
        return Apache2::Const::FORBIDDEN;
    }

    #If URI matches with app adress, get app and interface
    my $intf =
      Core::VultureUtils::get_intf( $log, $dbh, $r->dir_config('VultureID'),
       $config,$mc_conf );
    $r->pnotes( 'intf' => $intf );
    
    my $app = Core::VultureUtils::get_app( $log, $dbh,$mc_conf,
        $intf->{id},$r->hostname . $r->uri);
    my $cookie_app_name=$r->dir_config('VultureAppCookieName');

    my $id_sap = undef;
    if ( $r->unparsed_uri =~ /$cookie_app_name=([a-zA-Z0-9]+)/ ){
        $id_sap = $1;
    }
    $r->pnotes( 'app' => $app );
    
    #Call header rewrite plugins
    Core::TransHandlerv2::header_input($log,$r,$dbh,$app,$intf);

    #Plugin or Rewrite (according to URI)
    my $ret = Core::TransHandlerv2::plugins_th ($log,$r,$dbh,$app,$intf,$r->unparsed_uri);
    return $ret if defined $ret;
    
    #Call content rewrite plugins
    Core::TransHandlerv2::rewrite_content($log,$r,$dbh,$app,$intf);

    #Get sso url for this query:
    my $sso_url = ((defined $intf->{sso_portal} and $intf->{sso_portal}) 
            ? $intf->{sso_portal}
            : $app ? $app->{name} . '/' : '');

    $log->debug("SSO_URL : $sso_url");
    #If application exists and is not down, check auth
    if ( $app and not $id_sap ){
        # Application is down or unusable
        if (defined $app->{'up'} and not $app->{'up'} ) {
            return Core::TransHandlerv2::app_down($log,$r,$dbh,$app);
        }
        # get url to proxify
        my $proxy_url = Core::TransHandlerv2::get_proxy_url($r,$app,$r->uri);
        $log->debug("proxy = $proxy_url");

        #No authentication is needed
        my $auths = $app->{'auth'};
        if ( not defined $auths or not $auths ) {
            return Core::TransHandlerv2::anon_app($log,$r,$dbh,$app,$proxy_url);
        }

        #Getting session app if exists. If not, creating one
        my $id_app = Core::VultureUtils::get_cookie( $r->headers_in->{Cookie},
            $r->dir_config('VultureAppCookieName') . '=([^;]*)' ) || '' ;
        
        my (%session_app);
        Core::VultureUtils::session( \%session_app, $app->{timeout}, $id_app,
            $log, $mc_conf, $app->{update_access_time} );
        $r->pnotes( 'id_session_app' => $id_app );

        # We have authorization for this app so let's go with mod_proxy
        if ( defined $session_app{is_auth} and $session_app{is_auth} == 1 and $session_app{app_name} eq $app->{name} ) {
            return Core::TransHandlerv2::authen_app($log,$r,$dbh,$app,\%session_app,$proxy_url);
        }
        # Not authentified in this app. Setting cookie for app. 
        # Redirecting to SSO Portal.
        $log->debug( "App ". $r->hostname
              . " is secured and user is not authentified in app. Let's"
              . " have fun with AuthenHandler / redirect to SSO Portal."
              . $intf->{'sso_portal'} );
        $r->status(200);

        # Fill session for SSO Portal
        
        #$log->debug("APP_NAME : " . $app->{name}); 
        if (not defined $session_app{app_name}){
            $session_app{app_name} = $app->{name};
        }
        elsif( $session_app{app_name} ne $app->{name} ){
            return Apache2::Const::FORBIDDEN;
        }
        if ( $r->pnotes('url_to_redirect') ) {
            $log->debug("TRANS1 : will redirect to '".$r->pnotes('url_to_redirect')."'");
            $session_app{url_to_redirect} = $r->pnotes('url_to_redirect');
        }
        else {
            $log->debug("TRANS2 : will redirect to '$r->unparsed_uri'");
            $session_app{url_to_redirect} = $r->unparsed_uri;
        }
        # A plugin has send a $r->pnotes('url_to_mod_proxy') => proxify
        if ( $r->pnotes('url_to_mod_proxy') ) {
            return Core::TransHandlerv2::plugin_proxify($log,$r,$app,\%session_app);
        }

        # Redirect to SSO Portal
        # if $r->pnotes('url_to_mod_proxy') wasn't set by Rewrite engine
        return Core::TransHandlerv2::redirect_portal($log,$r,$app,$intf,\%session_app);
    }
    elsif (
        # SSO Portal
	    (($r->hostname . $r->uri . '/') =~ /$sso_url/)
        or(defined $app and defined $id_sap)
      )
    {
        return Core::TransHandlerv2::portal_mode ($log,$r,$dbh,$app,$intf,$id_sap);
    }
    # CAS Portal
    elsif ( $r->hostname =~ $intf->{'cas_portal'} ) {
        $log->debug('cas portal');
        return Apache2::Const::OK;
    }
    # If a default URL is defined in intf, redirect to it
    elsif ($intf->{'default_url'} =~ /^http/ ) {
	    $r->pnotes( 'url_to_redirect' => ''.$intf->{'default_url'} );
            $log->debug("TRANS3 : will redirect to default app '".$intf->{'default_url'}."'");
    }
    # Fail
    else {
        return Core::TransHandlerv2::app_not_found($log,$r);
    }
}
sub plugins_th{
    my ($log,$r,$dbh,$app,$intf,$uuri)=@_;
    my $mc_conf = $r->pnotes('mc_conf');
    my $query =
'SELECT uri_pattern, type, options FROM plugin WHERE app_id = ? OR app_id IS NULL';
    my $plugins = $dbh->selectall_arrayref( $query, undef, $app->{id} );
    my $module_name;
    foreach my $row (@$plugins) {
        my $options;
        my @result;
        my $exp = @$row[0];
        if ( (@result) = ( $uuri =~ /$exp/ ) ) {
            $log->debug( "Pattern " . $exp . " matches with URI" );
            $module_name = 'Plugin::Plugin_' . uc( @$row[1] );
            $log->debug("Load plugin TH: $module_name");
            if ( uc( @$row[1] ) eq "REWRITE" ) {
                $options = $row;
            }
            else {
                $options = @$row[2];
            }
            $options ||= \@result if defined $1;
            #load plugin
            Core::VultureUtils::load_module($module_name,'plugin');
            #execute plugin and get return
            my $ret =
              $module_name->plugin( $r, $log, $dbh, $intf, $app, $options );
#Return code (OK from plugin will skip all of the TransHandler process)
            return $ret if defined $ret ;
        }
    }
    return undef;
}
sub rewrite_content{
    my ($log,$r,$dbh,$app,$intf)=@_;
    # portal content should not be rewritten
    return undef unless $app->{id};
    my $mc_conf = $r->pnotes('mc_conf');
    my $key = "plugincontent:".$app->{id};
    my $plugins = Core::VultureUtils::get_memcached($key,$mc_conf);
    if (defined $plugins){
        $log->debug("got $key from memcached");
    }
    else{
        my $query = ('SELECT type, pattern, options, options1 FROM plugincontent'
            . ' WHERE app_id = ? OR app_id IS NULL');
        $plugins = $dbh->selectall_arrayref( $query, undef, $app->{id} );
        Core::VultureUtils::set_memcached( $key, $plugins, 60, $mc_conf);
        $log->debug("set $key in memcached");
    }
    if ( scalar @$plugins) {
        #Calling associated plugin
        use Plugin::Plugin_OutputFilterHandler;
        $r->pnotes(content_rewrites => $plugins);
        $r->add_output_filter( \&Plugin::Plugin_OutputFilterHandler::handler );
    }
}
sub header_input{
    my ($log,$r,$dbh,$app,$intf)=@_;
    my $mc_conf = $r->pnotes('mc_conf');
    my $key = "header_input:".$intf->{id};
    my $plugins = Core::VultureUtils::get_memcached($key, $mc_conf);
    if (defined $plugins){
        $log->debug("got $key from memcached");
    }
    else{
        my $query = ('SELECT pattern, type, options, options1 FROM pluginheader'
            . ' WHERE app_id = ? OR app_id IS NULL ORDER BY type');
        $log->debug($query);
        $plugins = $dbh->selectall_arrayref( $query, undef, $app->{id} );
        Core::VultureUtils::set_memcached($key,$plugins,60,$mc_conf);
        $log->debug("save $key in memcached");
    }
    foreach my $row (@$plugins) {
        my $header   = @$row[0];
        my $type     = @$row[1];
        my $options  = @$row[2];
        my $options1 = @$row[3];
        my $module_name = 'Plugin::Plugin_HEADER_INPUT';
        $log->debug("Load $module_name");
        $log->debug($header);

        #Calling associated plugin
        #Get return
        Core::VultureUtils::load_module($module_name,'plugin');
        $module_name->plugin(
            $r,      $log,  $dbh,     $intf, $app,
            $header, $type, $options, $options1
        );
    }
}
sub anon_app{
    my ($log,$r,$dbh,$app,$proxy_url) = @_;
    #Destroy useless handlers
    $r->set_handlers( PerlAuthenHandler => undef );
    $r->set_handlers( PerlAuthzHandler  => undef );
    $log->debug( "Setting pnotes 'url_to_mod_proxy' to " . $proxy_url )
      unless $r->pnotes('url_to_mod_proxy');
    $r->filename( "proxy:" . $proxy_url );
    $r->pnotes( 'url_to_mod_proxy' => $proxy_url )
      unless $r->pnotes('url_to_mod_proxy');

    #Getting headers to forward
    Core::TransHandlerv2::forward_headers($log,$r,$dbh,$app);
    return Apache2::Const::OK;
}
sub authen_app{
    my ($log,$r,$dbh,$app,$session_app,$proxy_url) = @_;
    #Setting username && password for FixupHandler and ResponseHandler
    $r->pnotes( 'username' => ''.$session_app->{username} );
    $r->pnotes( 'password' => ''.Core::VultureUtils::decrypt($r,$session_app->{password}) );
    $r->user( $session_app->{username} );
    $log->debug( "This app : "
          . $r->hostname
          . " is secured or display portal is on."
          . " User has a valid cookie for this app"
    );

    #Add Authorization header for htaccess
    if (    $app->{'sso'}->{'type'}
        and $app->{'sso'}->{'type'} eq "sso_forward_htaccess" )
    {
        my $authorization = encode_base64($session_app->{username}.':'.Core::VultureUtils::decrypt($r,$session_app->{password}));
        $authorization =~ s/\n//;
        $r->headers_in->set(
            'Authorization' => "Basic $authorization"
        );
    }
    #Add Authorization header for kerberos
    elsif (    $app->{'sso'}->{'type'}
        and $app->{'sso'}->{'type'} eq "sso_forward_kerberos" )
    {
        $log->debug("::authen_app: sso_type = sso_forward_kerberos  => request kerberos token..");

        my $token = Core::VultureUtils_Kerberos::getKerberosServiceToken($log, $r, $dbh, $app, $session_app->{username}, $session_app->{password});
        if ( $token ) {
            $log->debug("::authen_app: sso_type = sso_forward_kerberos  => set kerberos token in authorization header");
            $r->headers_in->set('Authorization' => "Negotiate ".encode_base64($token,"") );
        } else {
            $log->debug("::authen_app: sso_type = sso_forward_kerberos  => kerberos token request failed");
        }
    }
    #Destroy useless handlers
    $r->set_handlers( PerlAuthenHandler => undef );
    $r->set_handlers( PerlAuthzHandler  => undef );
    #Mod_proxy with apache : user will not see anything
    if ( not defined $session_app->{SSO_Forwarding} ) {
        $log->debug(
            "Setting pnotes 'url_to_mod_proxy' to " . $proxy_url )
          unless $r->pnotes('url_to_mod_proxy');
        $r->filename( "proxy:" . $proxy_url );
        $r->pnotes( 'url_to_mod_proxy' => $proxy_url )
          unless $r->pnotes('url_to_mod_proxy');
    }
    Core::TransHandlerv2::forward_headers($log,$r,$dbh,$app);
    return Apache2::Const::OK;
}
sub forward_headers{
    my ($log,$r,$dbh,$app)=@_;
    #Getting headers to forward
    my $sth = $dbh->prepare(
        "SELECT name, type, value FROM header WHERE app_id= ?");
    $sth->execute( $app->{id} );
    while ( my ( $name, $type, $value ) = $sth->fetchrow ) {
        if ( $type eq "REMOTE_ADDR" ) {
            $value = $r->connection->remote_ip;
            #Nothing to do
        }
        elsif ( $type eq "CUSTOM" ) {
            #Types related to SSL
        }
        else {
            $value = $r->ssl_lookup($type);
        }
        #Try to push custom headers
        try {
            $r->headers_in->set( $name => $value );
            $log->debug("Pushing custom header $name => $value");
        }
	catch {
	}
    }
    $sth->finish();
}
sub redirect_portal{
    my ($log,$r,$app,$intf,
        $session_app)=@_;

    my $incoming_uri = $app->{name};
    my $ssl          = 0;
    my $auths = $app->{'auth'};
    if (defined $auths and $auths and $auths->{auth_type} eq 'SSL'){
        $ssl = 1;
    }
    $incoming_uri = $intf->{'sso_portal'} if $intf->{'sso_portal'} and not $ssl;
    if ( $incoming_uri !~ /^(http|https):\/\/(.*)/ ) {
        #Fake scheme for making APR::URI parse
        $incoming_uri = 'http://' . $incoming_uri;
    }
    #Rewrite URI with scheme, port, path,...
    my $rewrite_uri = APR::URI->parse( $r->pool, $incoming_uri );
    $rewrite_uri->scheme('http');
    $rewrite_uri->scheme('https') if $r->is_https;
    $rewrite_uri->port( $r->get_server_port() );
    $rewrite_uri->path( $rewrite_uri->path . $app->{auth_url}."?"
        .$r->dir_config('VultureAppCookieName')."=".$session_app->{_session_id}
    );
    #Set cookie
    #$r->err_headers_out->set('Location' => $rewrite_uri->unparse);
    my $dir = '';
    if ( $app->{name} =~ /\/(.*)/ ) {
        $dir = $1;
    }
    $r->err_headers_out->add(
        'Set-Cookie' => $r->dir_config('VultureAppCookieName') . "="
          . $session_app->{_session_id}
          . "; path=/".$dir
          . "; domain=."
          . $r->hostname );

    #Redirect user to SSO portal
    $r->pnotes( 'response_content' =>
          '<html><head><meta http-equiv="Refresh" content="0; url='
          . $rewrite_uri->unparse
          . '"/></head></html>' );
    $r->pnotes( 'response_content_type' => 'text/html' );
    $r->set_handlers( PerlAuthenHandler => undef );
    $r->set_handlers( PerlAuthzHandler  => undef );
    $r->set_handlers( PerlFixupHandler  => undef );
    return Apache2::Const::OK;
}
sub portal_mode{
    my ($log,$r,$dbh,$app,$intf, $id_sap) = @_;
    $log->debug('Entering SSO Portal mode.');
    my $mc_conf = $r->pnotes( 'mc_conf');
    my $cname=$r->dir_config('VultureAppCookieName');
#App coming from vulture itself
    if ( defined $id_sap ) {
        $log->debug("PORTAL MODE: app from vulture");
        my $app_cookie_name = $1;
        my (%session_app);
        #Get app
        Core::VultureUtils::session( \%session_app, $app->{timeout},
            $id_sap, $log, $mc_conf, $app->{update_access_time} );
        my $app = Core::VultureUtils::get_app( $log, $dbh,$mc_conf,
            $intf->{id},$session_app{app_name});

        #Send app if exists.
        $r->pnotes( 'app' => $app ) if $app;
        $r->pnotes( 'id_session_app' => $id_sap );
    }
    else{
        $r->pnotes('app'=>0);
    }

#Getting SSO session if exists.
    my $sso_sid = '';
    $sso_sid =
      Core::VultureUtils::get_cookie( $r->headers_in->{'Cookie'},
        $r->dir_config('VultureProxyCookieName') . '=([^;]*)' );
    $sso_sid||= '';
    my (%session_SSO);

    Core::VultureUtils::session( \%session_SSO, $intf->{sso_timeout},
        $sso_sid, $log, $mc_conf, $intf->{sso_update_access_time} );

#Get session id if not exists
    if ( $sso_sid ne $session_SSO{_session_id} ) {
        $log->debug("SID : Replacing SSO id");
        $sso_sid = $session_SSO{_session_id};
    }
    my $dir = "";
    if ( defined $app and exists $app->{name} and $app->{name} =~ /\/([^?]*)/ ) {
        $log->debug("BOOO ! app_name is " . $app->{name});
        $dir = $1;
    }
#Set cookie for SSO portal
    $r->err_headers_out->add(
            'Set-Cookie' => $r->dir_config('VultureProxyCookieName') . "="
          . $sso_sid
          . "; path=/"
          . $dir
          . "; domain=."
          . $r->hostname );

    $r->pnotes( 'id_session_SSO' => $sso_sid );

#Destroy useless handlers
    $r->set_handlers( PerlFixupHandler => undef );

    return Apache2::Const::OK;
}
sub plugin_proxify{
    my ($log,$r,$app,$session_app) = @_;
    $r->set_handlers( PerlAuthenHandler => undef );
    $r->set_handlers( PerlAuthzHandler  => undef );
    my $dir;
    if ( $app->{name} =~ /\/(.*)/ ) {
        $dir = $1;
    }
    $r->err_headers_out->add(
        'Set-Cookie' => $r->dir_config('VultureAppCookieName') . "="
          . $session_app->{_session_id}
          . "; path=/"
          . $dir
          . "; domain=."
          . $r->hostname );
    return Apache2::Const::OK;
}
sub app_down{
    my ($log,$r,$dbh,$app) = @_;
    $log->error( 'Trying to redirect to '
          . $r->hostname
          . ' but failed because '
          . $r->hostname
          . ' is down' );
    $r->status(Apache2::Const::NOT_FOUND);

    #Custom error message
    my $translations =
      Core::VultureUtils::get_translations( $r, $log, $dbh, "APP_DOWN" );
    my $html =
      Core::VultureUtils::get_style( $r, $log, $dbh, $app, 'DOWN',
        'App is down', {}, $translations );
    $html |= '';
    $log->debug($html);
    $r->custom_response( Apache2::Const::NOT_FOUND, $html )
        if $html =~ /<body>.+<\/body>/s;
    return Apache2::Const::NOT_FOUND;
}
sub app_not_found{
    my ($log,$r) = @_;
    $log->error( 'Trying to redirect to '
          . $r->hostname
          . ' but failed because '
          . $r->hostname
          . ' doesn\'t exist in Database' );
    $r->status(Apache2::Const::NOT_FOUND);
    return Apache2::Const::DONE;
}
sub get_proxy_url{
    my ($r,$app,$uri)=@_;
    my $proxy_url;
    if ( $uri =~ /^(http|https|ftp):\/\// ) {
        return $uri;
    }
    else {
        my $dir = '';
        my $hostname = $r->hostname;
        if ( $app->{name} =~ /$hostname\/?(.*)(\/*)$/ ) {
            $dir = $1;
        }
        if ( $uri =~ /^\/?$dir\/(.*)$/ ) {
            $uri = $1;
        }
        else { $uri = ''; }
        return $app->{url} . "/" . $uri;
    }
}
1;
