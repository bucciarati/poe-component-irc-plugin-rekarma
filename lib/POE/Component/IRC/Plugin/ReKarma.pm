package POE::Component::IRC::Plugin::ReKarma;

use strict;
use warnings;

use POE::Component::IRC;
use POE::Component::IRC::Plugin qw( :ALL );

use Data::Dumper;

use constant {
    KARMA_INCREASE_RE_DEFAULT => qr(
        \A
        (?:
            viva
            \s+
        )
        (.*)
        \z
    )xi,

    KARMA_DECREASE_RE_DEFAULT => qr(
        \A
        (?:
            abbasso
            \s+
        )
        (.*)
        \z
    )xi,
};

sub new {
    my ($package, %args) = @_;

    my $self = bless {}, $package;

    return $self;
}

sub PCI_register {
    my ($self, $irc) = @_;

    $irc->plugin_register($self, 'SERVER', 'public');

    return 1;
}

sub PCI_unregister {
    return 1;
}

sub S_public {
    my ($self, $irc) = (shift, shift);

    my $nick = ${ +shift };
    $nick =~ s/!.*$//;

    my $my_own_nick = $irc->{nick};

    my $channel = ${ +shift }->[0];
    my $lc_channel = lc $channel;
    my $channel_settings = $self->{channel_settings}{$lc_channel};

    my $karma_increase_re = qr(@{[ $channel_settings->{karma_increase_re} // KARMA_INCREASE_RE_DEFAULT ]});
    my $karma_decrease_re = qr(@{[ $channel_settings->{karma_decrease_re} // KARMA_DECREASE_RE_DEFAULT ]});
    my $status_file = $channel_settings->{status_file} // $ENV{HOME} . '/.pocoirc-rekarma-status-' . $lc_channel;
    my $karma = ( do $status_file ) // {};

    my $message = shift;

    my $text = $$message;
    Encode::_utf8_on( $text );

    # allow optionally addressing the bot
    $text =~ s/\A$my_own_nick\:\s*//;

    my $what = '';
    if ( $text =~ $karma_increase_re ) {
        warn "increasing ($lc_channel) karma for <$1> :)\n" if $channel_settings->{debug};
        $what = $1;
        ($karma->{$what} //= 0)++;
    } elsif ( $text =~ $karma_decrease_re ) {
        warn "decreasing ($lc_channel) karma for <$1> :(\n" if $channel_settings->{debug};
        $what = $1;
        ($karma->{$what} //= 0)--;
    } else {
        return PCI_EAT_NONE;
    }

    open my $fh, '>', $status_file;
    print $fh Dumper( $karma );
    $fh->close;

    $irc->yield(
        notice => $channel,
        "karma for <$what> is now $karma->{$what}",
    );

    return PCI_EAT_ALL;
}

1;

__END__

# vim: tabstop=4 shiftwidth=4 expandtab cindent:
