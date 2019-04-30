package POE::Component::IRC::Plugin::ReKarma;

use strict;
use warnings;

use POE::Component::IRC;
use POE::Component::IRC::Plugin qw( :ALL );

use JSON::XS;

use constant {
    KARMA_INCREASE_RE_DEFAULT => qr(
        \A
        (?:
            \s*
        )
        (?:
            (?:(?:ev)?viva|w)
            \s+
        )
        (.*?)
        \s*
        \z
    )xi,

    KARMA_DECREASE_RE_DEFAULT => qr(
        \A
        (?:
            abbasso
            \s+
        )
        (.*?)
        \s*
        \z
    )xi,

    KARMA_STATS_RE_DEFAULT => qr(
        \A
        (?:
            karma
            \s*
            (?:(?:per|di|of|for)\b\s*)?
        )
        (.*?)?
        \s*
        \z
    )xi,

    # default to allowing one vote per hour, per user per item
    KARMA_REPEAT_SECONDS_DEFAULT => 60 * 60,
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

my $karma = {};
sub _karma_load_from_file {
    my ($path) = @_;

    my $encoded_karma;
    open my $fh, '<', $path or return;
    { local $/; $encoded_karma = <$fh> }
    $fh->close;

    $karma = JSON::XS::decode_json($encoded_karma);

    return;
}

sub _karma_store_to_file {
    my ($path) = @_;

    open my $fh, '>', $path or do {
        warn "Did not open <$path>: $!\n";
        return;
    };
    my $encoded_karma = JSON::XS::encode_json($karma);
    # warn "String size: @{[ bytes::length $encoded_karma ]} bytes\n";
    $fh->write($encoded_karma) or warn "Did not write <$path>: $!\n";
    $fh->close;

    return;
}

my $last_per_item = {};
sub S_public {
    my ($self, $irc) = (shift, shift);

    my $sender = ${ +shift };
    my ($nick, $mask) = split /!/, $sender, 2;

    my $my_own_nick = $irc->{nick};

    my $channel = ${ +shift }->[0];
    my $lc_channel = lc $channel;
    (my $pathsafe_channel = $lc_channel) =~ s{/}{_}g;
    my $channel_settings = $self->{channel_settings}{$lc_channel};

    my $repeat_seconds = $channel_settings->{repeat_seconds} // KARMA_REPEAT_SECONDS_DEFAULT;
    my $karma_increase_re = qr(@{[ $channel_settings->{karma_increase_re} // KARMA_INCREASE_RE_DEFAULT ]});
    my $karma_decrease_re = qr(@{[ $channel_settings->{karma_decrease_re} // KARMA_DECREASE_RE_DEFAULT ]});
    my $karma_stats_re    = qr(@{[ $channel_settings->{karma_stats_re}    // KARMA_STATS_RE_DEFAULT    ]});
    my $status_file = $channel_settings->{status_file} // $ENV{HOME} . '/.pocoirc-rekarma-status-' . $pathsafe_channel . '.json';

    my $message = shift;

    my $text = Encode::decode_utf8($$message);

    # allow optionally addressing the bot
    $text =~ s/\A$my_own_nick[:,\s]*//;

    my $new_karma = undef;

    my $karma_change_callback = sub {
        my ($original_key, $value_change_callback) = @_;
        my $normalized_key = lc $original_key;

        foreach my $item_per_mask ( keys %{ $last_per_item->{$mask} // {} }){
            my $seconds_since = time - $last_per_item->{$mask}{$item_per_mask};
            if ( $seconds_since > $repeat_seconds ){
                # cleanup old entries
                delete $last_per_item->{$mask}{$item_per_mask};
                next;
            }

            if ( $item_per_mask eq $normalized_key ){
                # we are visiting the element currently being voted, and
                # it hasn't been deleted, which means it's not old enough
                # to allow another vote.
                warn "Karming too soon ($mask -> $normalized_key) $seconds_since seconds ago\n";
                return;
            }
        }
        $last_per_item->{$mask}{$normalized_key} = time;

        _karma_load_from_file($status_file);

        my ($storage_key, @key_is_ambiguous) = grep { $normalized_key eq lc $_ } keys %$karma;
        if (@key_is_ambiguous) {
            warn "key <$original_key> is ambiguous (@{[ scalar @key_is_ambiguous ]} extra matches)\n";
        }

        # when we don't have any matches, we make the first mention be the canonical one
        $storage_key //= $original_key;

        $value_change_callback->($storage_key);
        $new_karma = $karma->{$storage_key};

        _karma_store_to_file($status_file);

        $irc->yield(
            notice => $channel,
            "karma for <$original_key> is now $new_karma",
        );
    };

    my $what = '';
    if ( $text =~ $karma_increase_re ) {
        warn "increasing ($lc_channel) karma for <$1> :)\n" if $channel_settings->{debug};
        $what = $1;
        $karma_change_callback->($what, sub { ($karma->{$_[0]} //= 0)++ });
    } elsif ( $text =~ $karma_decrease_re ) {
        warn "decreasing ($lc_channel) karma for <$1> :(\n" if $channel_settings->{debug};
        $what = $1;
        $karma_change_callback->($what, sub { ($karma->{$_[0]} //= 0)-- });
    } elsif ( $text =~ $karma_stats_re ) {
        $what = $1;
        warn "requesting karma stats for <@{[ $what || '(nothing/everything)' ]}>\n" if $channel_settings->{debug};
        _karma_load_from_file($status_file);

        if ( $what ){
            my $lc_what = lc $what;
            my $karma_value;
            while ( my ($k, $v) = each %$karma ){
                next unless lc $k eq $lc_what;
                $karma_value = $v;
                $irc->yield(
                    notice => $channel,
                    "karma for <$what> is $karma_value",
                );

                last;
            }

            if ( !$karma_value && $what =~ qr{\A / (?<needle>[^/]+) / \z}ix ){
                my $lc_needle = lc $+{needle};
                my $findings;
                while ( my ($k, $v) = each %$karma ){
                    next if index(lc $k, $lc_needle) == -1;
                    $findings->{$k} = $v;
                    # warn "/$lc_needle/ => <$k>:$v\n";
                }

                if ( keys %$findings ) {
                    my @best_worst_keys = sort { abs $findings->{$b} <=> abs $findings->{$a} } keys %$findings;
                    foreach my $k ( grep defined, @best_worst_keys[0..4] ){
                        $karma_value = $findings->{$k};
                        $irc->yield(
                            notice => $channel,
                            "karma for <$k> is $karma_value",
                        );
                    }
                }
            }

            if ( not defined $karma_value ){
                $irc->yield(
                    notice => $channel,
                    "there is no karma for <$what> yet!",
                );
            }
        } else {
            my @top_keys = grep defined, ( sort { $karma->{$b} <=> $karma->{$a} } keys %$karma )[0..5];

            $irc->yield(
                notice => $channel,
                "karma for <$_> is $karma->{$_}",
            ) for @top_keys;

            $irc->yield(
                notice => $channel,
                "[...]",
            );

            my @bottom_keys = grep defined, ( sort { $karma->{$a} <=> $karma->{$b} } keys %$karma )[0..5];

            $irc->yield(
                notice => $channel,
                "karma for <$_> is $karma->{$_}",
            ) for reverse @bottom_keys;
        }
    } else {
        return PCI_EAT_NONE;
    }

    return PCI_EAT_ALL;
}

1;

__END__

# vim: tabstop=4 shiftwidth=4 expandtab cindent:
