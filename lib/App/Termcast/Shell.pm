package App::Termcast::Shell;
# ABSTRACT: view termcast sessions from a shell

use Moose;
use Term::ReadLine;
use Term::ReadKey;

use JSON;
use Cwd;

use IO::Socket::UNIX;
use Time::Duration;
use List::MoreUtils 'any';

with 'MooseX::Getopt';

has output_sub => (
    is      => 'ro',
    isa     => 'CodeRef',
    traits  => ['NoGetopt'],
    lazy    => 1,
    default => sub {
        my $self = shift;
        return sub {
            my $msg = shift;
            syswrite \*{$self->term->OUT}, $msg;
        };
    },
);

has socket => (
    is            => 'ro',
    isa           => 'Str',
    documentation => 'Path to the UNIX socket that apps connect to',
    required      => 1,
);

has prompt_sub => (
    is      => 'ro',
    isa     => 'CodeRef',
    traits  => ['NoGetopt'],
    default => sub {
        return sub {
            return '> ';
        };
    },
);

has term => (
    is => 'ro',
    default => sub { Term::ReadLine->new('Termcast Shell') },
);

use constant CLEAR => "\e[2J\e[H";

sub output {
    my $self = shift;
    $self->output_sub->(@_);
}

sub say {
    my $self = shift;
    my $message = shift;
    $self->output("$message\n");
}

sub _retrieve_sessions {
    my $self = shift;

    my $socket = IO::Socket::UNIX->new(
        Peer => Cwd::abs_path($self->socket),
    ) or die $!;
    $socket->syswrite(JSON::encode_json({request => 'sessions'}));

    my $json = JSON->new;
    my ($buf, $data);
    {
        $socket->sysread($buf, 4096) until $buf;
        ($data) = $json->incr_parse($buf);
        redo until $data;
    }
    $socket->close;

    return $data->{response} eq 'sessions' ?  $data->{sessions} : [];
}

sub _format_session_list {
    my $self = shift;
    my ($sessions, @ids) = @_;

    my $output = '';
    for my $session (@$sessions) {
        if (@ids > 0) {
            next if any { lc($_) eq lc($session->{session_id}) } @ids;
        }
        my $ago = ago(time() - $session->{last_active});
        $output .= sprintf(
            "[%s] %s (%sx%s) - active %s\n",
            $session->{session_id},
            $session->{user},
            @{ $session->{geometry} },
            $ago,
        );
    }
    return $output;
}

sub run {
    my $self = shift;

    my %dispatch = (
        list => sub {
            my @args = @_;

            my $sessions = $self->_retrieve_sessions();
            my $output = $self->_format_session_list($sessions);
            $output ||= 'Nobody is currently streaming.';
            $self->say($output);
        },
        view => sub {
            my $id = shift;
            my $sessions = $self->_retrieve_sessions();
            my %session_lookup = ();
            for my $session (@$sessions) {
                if ($session->{session_id} =~ /$id/i) {
                    $session_lookup{$session->{session_id}} = $session;
                }
            }
            if (!scalar keys %session_lookup) {
                $self->say("Did not find a match. Use 'list' to see the available streams.");
                return;
            }
            if (scalar(keys %session_lookup) > 1) {
                my $output = "Ambiguous lookup:\n";
                $output .= $self->_format_session_list(
                    $sessions, keys(%session_lookup),
                );
                $self->say();
                return;
            }

            my ($session) = values %session_lookup;
            my $socket = IO::Socket::UNIX->new(
                Peer => $session->{socket},
            );

            $self->output(CLEAR);
            ReadMode 4;

            my $error = '';
            my $rin = my $ein = my $rout = my $eout = '';
            {
                vec($rin, fileno($_), 1) = 1 for \*STDIN, $socket;
                my $select = select($rout = $rin, undef, $eout = $ein, undef);
                if ($select == -1) {
                    redo if $!{EAGAIN} or $!{EINTR};
                }

                if (vec($eout, fileno($socket), 1)) {
                    $error = 'An error with the socket occurred.';
                    last;
                }
                elsif (vec($rout, fileno($socket), 1)) {
                    my $read = sysread($socket, my $buf, 4096);
                    last if not defined $read or $read == 0;
                    $self->output($buf);
                }
                elsif (vec($rout, fileno(\*STDIN), 1)) {
                    sysread(STDIN, my $buf, 1);
                    last if $buf eq 'q';
                }
                else {
                    last;
                }
                redo;
            }
            $self->output($error ? CLEAR . "$error\n" : CLEAR);
            ReadMode 0;
        },
    );

    $self->prompt_sub->();
    while (defined(my $output = $self->term->readline('termcast> '))) {
        chomp $output;
        if ($output) {
            my @words = split ' ', $output;
            my $command = shift @words;

            my $sub = $dispatch{$command} || sub {
                $self->say("Unknown command.");
            };

            $sub->(@words);
        }

        $self->prompt_sub->();
    }
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
