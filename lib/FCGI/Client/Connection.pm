package FCGI::Client::Connection;
use Any::Moose;
use FCGI::Client::Constant;
use Time::HiRes qw(time);
use List::Util qw(max);
use POSIX qw(EAGAIN);
use FCGI::Client::Record;
use FCGI::Client::RecordFactory;

has sock => (
    is       => 'ro',
    required => 1,
);

has timeout => (
    is => 'ro',
    isa => 'Int',
    default => 10,
);

sub request {
    my ($self, $env, $content) = @_;
    local $SIG{PIPE} = "IGNORE";
    my $orig_alarm;
    my @res;
    eval {
        $SIG{ALRM} = sub { Carp::confess('REQUESET_TIME_OUT') };
        $orig_alarm = alarm($self->timeout);
        my $sock = $self->sock();
        $self->_send_request($env, $content);
        @res = $self->_receive_response($sock);
    };
    if ($@) {
        die $@;
    } else {
        return @res;
    }
}

sub _receive_response {
    my ($self, $sock) = @_;
    my ($stdout, $stderr);
    while (my $res = FCGI::Client::Record->read($self)) {
        my $type = $res->type;
        if ($type == FCGI_STDOUT) {
            $stdout .= $res->content;
        } elsif ($type == FCGI_STDERR) {
            $stderr .= $res->content;
        } elsif ($type == FCGI_END_REQUEST) {
            $sock->close();
            return ($stdout, $stderr);
        } else {
            die "unknown response type: " . $res->type;
        }
    }
    die 'connection breaked from server process?';
}
sub _send_request {
    my ($self, $env, $content) = @_;
    my $reqid = int(rand(1000));
    $self->sock->print($self->create_request($reqid, $env, $content));
}
sub create_request {
    my ($self, $reqid, $env, $content) = @_;
    my $factory = "FCGI::Client::RecordFactory";
    my $flags = 0;
    return join('',
        $factory->begin_request($reqid, FCGI_RESPONDER, $flags),
        $factory->params($reqid, %$env),
        $factory->params($reqid),
        ($content ? $factory->stdin($reqid, $content) : ''),
        $factory->stdin($reqid),
    );
}

# returns 1 if socket is ready, undef on timeout
sub wait_socket {
    my ( $self, $sock, $is_write, $wait_until ) = @_;
    do {
        my $vec = '';
        vec( $vec, $sock->fileno, 1 ) = 1;
        if (
            select(
                $is_write ? undef : $vec,
                $is_write ? $vec  : undef,
                undef,
                max( $wait_until - time, 0 )
            ) > 0
          )
        {
            return 1;
        }
    } while ( time < $wait_until );
    return;
}

# returns (positive) number of bytes read, or undef if the socket is to be closed
sub read_timeout {
    my ( $self, $buf, $len, $off, ) = @_;
    my $sock = $self->sock;
    my $timeout = $self->timeout;
    my $wait_until = time + $timeout;
    while ( $self->wait_socket( $sock, undef, $wait_until ) ) {
        if ( my $ret = $sock->sysread( $$buf, $len, $off ) ) {
            return $ret;
        }
        elsif ( !( !defined($ret) && $! == EAGAIN ) ) {
            last;
        }
    }
    return;
}

1;
__END__

=head1 FAQ

=over 4

=item Why don't support FCGI_KEEP_CONN?

FCGI_KEEP_CONN is not used by lighttpd's mod_fastcgi.c, and mod_fast_cgi for apache.
And, FCGI.xs doesn't support it.

I seems FCGI_KEEP_CONN is not used in real world.

=back
