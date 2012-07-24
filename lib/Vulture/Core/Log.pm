#file:Core/Log.pm
#-------------------------
#!/usr/bin/perl
package Core::Log;

use strict;
use warnings;

BEGIN {
    use Exporter ();
    our @ISA = qw(Exporter);
    our @EXPORT_OK =
      qw(&new &emerg &alert &crit &error &warn &notice &info &debug);
}

use Apache2::Log;
use Apache2::Reload;

# use same constant as in Apache
use constant {
    EMERG  => "emerg",
    ALERT  => "alert",
    CRIT   => "crit",
    ERROR  => "error",
    WARN   => "warn",
    NOTICE => "notice",
    INFO   => "info",
    DEBUG  => "debug"
};

sub new {
    my $class = $_[0];
    my ($self) = {};
    $self->{'r'} = $_[1];
    bless( $self, $class );
    return ($self);
}

sub handle_log {
    my ( $self, @args ) = @_;
    my $r = $self->{'r'};
    my ( $package, $filename, $line, $log_level, $type, $desc, $user ) = @args;

    #Getting apache log
    my $log = $r->server->log;

    #Setting message
    my $message = $package . "(" . $line . "): ";
    $message .= $type . ' | Desc : ' if defined $type;
    $message .= $desc                if defined $desc;
    $message .= ' | User : ' . $user if defined $user;

    #if no log level are specified , use debug level
    unless ( defined $log_level ) {
        $log->debug($message);
        return;
    }

    #Sort by log level
    if ( $log_level eq EMERG ) {
        $log->emerg($message);
    }
    elsif ( $log_level eq ALERT ) {
        $log->alert($message);
    }
    elsif ( $log_level eq CRIT ) {
        $log->crit($message);
    }
    elsif ( $log_level eq ERROR ) {
        $log->error($message);
    }
    elsif ( $log_level eq WARN ) {
        $log->warn($message);
    }
    elsif ( $log_level eq NOTICE ) {
        $log->notice($message);
    }
    elsif ( $log_level eq INFO ) {
        $log->info($message);
    }
    else {
        $log->debug($message);
    }
    return;
}

sub emerg {
    my ( $self, @args ) = @_;
    my ( $desc, $type, $user ) = @args;

    my $log_level = EMERG;
    my ( $package, $filename, $line ) = caller;

    handle_log( $self, $package, $filename, $line, $log_level, $type, $desc,
        $user );
    return;
}

sub alert {
    my ( $self, @args ) = @_;
    my ( $desc, $type, $user ) = @args;

    my $log_level = ALERT;
    my ( $package, $filename, $line ) = caller;

    handle_log( $self, $package, $filename, $line, $log_level, $type, $desc,
        $user );
    return;
}

sub crit {
    my ( $self, @args ) = @_;
    my ( $desc, $type, $user ) = @args;

    my $log_level = CRIT;
    my ( $package, $filename, $line ) = caller;

    handle_log( $self, $package, $filename, $line, $log_level, $type, $desc,
        $user );
    return;
}

sub error {
    my ( $self, @args ) = @_;
    my ( $desc, $type, $user ) = @args;

    my $log_level = ERROR;
    my ( $package, $filename, $line ) = caller;

    handle_log( $self, $package, $filename, $line, $log_level, $type, $desc,
        $user );
    return;
}

sub warn {
    my ( $self, @args ) = @_;
    my ( $desc, $type, $user ) = @args;

    my $log_level = WARN;
    my ( $package, $filename, $line ) = caller;

    handle_log( $self, $package, $filename, $line, $log_level, $type, $desc,
        $user );
    return;
}

sub notice {
    my ( $self, @args ) = @_;
    my ( $desc, $type, $user ) = @args;

    my $log_level = NOTICE;
    my ( $package, $filename, $line ) = caller;

    handle_log( $self, $package, $filename, $line, $log_level, $type, $desc,
        $user );
    return;
}

sub info {
    my ( $self, @args ) = @_;
    my ( $desc, $type, $user ) = @args;

    my $log_level = INFO;
    my ( $package, $filename, $line ) = caller;

    handle_log( $self, $package, $filename, $line, $log_level, $type, $desc,
        $user );
    return;
}

sub debug {
    my ( $self, @args ) = @_;
    my ( $desc, $type, $user ) = @args;

    my $log_level = DEBUG;
    my ( $package, $filename, $line ) = caller;

    handle_log( $self, $package, $filename, $line, $log_level, $type, $desc,
        $user );
    return;
}
1;
