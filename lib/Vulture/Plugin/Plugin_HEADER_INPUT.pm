#!/usr/bin/perl

package Plugin::Plugin_HEADER_INPUT;

use strict;
use warnings;

BEGIN {
    use Exporter ();
    our @ISA       = qw(Exporter);
    our @EXPORT_OK = qw(&plugin);
}

use Apache2::Log;
use Apache2::Reload;

sub plugin {
    my (
        $package_name, $r,      $log,  $dbh,     $intf,
        $app,          $header, $type, $options, $options1
    ) = @_;
    $log->debug($header);
    if ( $type eq "Header Add" ) {
        $r->headers_in->add( $header => $options );
    }
    if ( $type eq "Header Replacement" ) {
        $log->debug("Header Replacement");
        my @valhead           = $r->headers_in->get($header);
        my $value             = $options;
        my $replacementheader = $options1;
        my $headval;
        foreach $headval (@valhead) {
            if ( $headval && $headval =~ /$value/x ) {
                $log->debug(
                    "Plugin_InputFilterHandler RH Rule substitution OLDVAL=",
                    $headval );
                $headval =~ s/$value/$replacementheader/ig;
                $log->debug(
                    "Plugin_InputFilterHandler RH Rule substitution NEWVAL=",
                    $headval );
                $r->headers_in->unset($header);
                $r->headers_in->set( $header => $headval );
            }
        }
    }
    if ( $type eq "Header Unset" ) {
        $log->debug("Header Unset");
        $r->headers_in->unset($header);
    }
    if ( $type eq "Header Concat" ) {
        $log->debug("Concat");
        my @valhead = $r->headers_in->get($header) || {''};
        my $headval;
        foreach $headval (@valhead) {
            $log->debug( "Before " . $headval );
            $headval = $headval . $options;
            $log->debug( "After " . $headval );
            $r->headers_in->unset($header);
            $r->headers_in->set( $header => $headval );
        }

    }
}
1;

