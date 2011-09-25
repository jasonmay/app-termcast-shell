package App::Termcast::Shell;
use Moose;
use Term::ReadLine;

use JSON;
use Cwd;

use IO::Socket::UNIX;
use Time::Duration;

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
            print {$self->term->OUT} $msg;
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

sub run {
    my $self = shift;

    my %dispatch = (
        list => sub {
            my @args = @_;


            my $output = '';
            my $sessions = $self->_retrieve_sessions();
            for my $session (@$sessions) {
                my $ago = ago(time() - $session->{last_active});
                $output .= sprintf(
                    "[%s] %s (%sx%s) - active %s\n",
                    $session->{session_id},
                    $session->{user},
                    @{ $session->{geometry} },
                    $ago,
                );
            }
            $output ||= 'Nobody is currently streaming.';
            $self->say($output);
        },
    );

    $self->prompt_sub->();
    while (my $output = $self->term->readline('termcast> ')){
        chomp $output;
        my @words = split ' ', $output;
        my $command = shift @words;

        my $sub = $dispatch{$command} || sub {
            $self->say("Unknown command.");
        };

        $sub->(@words);

        $self->prompt_sub->();
    }
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
