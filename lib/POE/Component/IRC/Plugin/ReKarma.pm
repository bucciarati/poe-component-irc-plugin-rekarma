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
};

use DBI;

# TODO(gmodena) these should be moved to a module. But where?
sub DBI_init {
    my $dbname = shift;

    my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","", {
        RaiseError => 1,
        PrintError => 1,
        sqlite_unicode => 1,
        AutoCommit => 1
    }) or die "Can't connect to the database: $DBI::errstr";

    my $sth = $dbh->prepare(q{
        CREATE TABLE IF NOT EXISTS "Karmas" ( 
        "Name" TEXT NOT NULL CONSTRAINT "PK_Karmas" PRIMARY KEY, 
        "Score" INTEGER NOT NULL );
    });

    $sth->execute or die "Can't create Karmas table: $DBI::errstr";

    return $dbh;
};

sub DBI_upsert_score {
    # TODO(gmodena): update to the latest sqlite3, which introduces UPSERT.
    my ($dbh, $what, $score) = @_;

    my $sth = $dbh->prepare(q{ INSERT OR IGNORE INTO Karmas (Name, Score) VALUES(?, ?) });
    $sth->execute($what, $score) or die "Can't execute SQL statement: $DBI::errstr\n";

    $sth = $dbh->prepare(q{
        UPDATE Karmas SET Score = ? WHERE Name = ?
    });

    $sth->execute($score, $what) or die "Can't execute SQL statement: $DBI::errstr\n"; 
};

sub DBI_select_score {
    my ($dbh, $what) = @_;
    my $sth = $dbh->prepare(q{
        SELECT Score FROM Karmas WHERE Name = ?;
        });

    my $res = $sth->execute($what) or die "Can't execute SQL statement: $DBI::errstr\n";
    my $score = $sth->fetchrow_array();

    return $score;
};

sub DBI_select_all {
    my ($dbh, $order_direction, $limit) = @_;
    my $limit = defined $limit ? "LIMIT $limit" : "";
    my $sth = $dbh->prepare(qq{
        SELECT Name, Score FROM Karmas ORDER BY Score $order_direction $limit;
    }); 

    $sth->execute() or die "Can't execute SQL statement: $DBI::errstr\n";
    my @result = @{ $sth->fetchall_arrayref() };
    my %hash = map { $_->[0] => $_->[1] } @result;

    return %hash;
};

sub DBI_close {
    my $dbh = shift;
    my $res = $dbh->disconnect() or warn "$DBI::errstr";
    return $res
}

sub new {
    my ($package, %args) = @_;

    my $self = bless {}, $package;
    $self->{dbh} = undef;

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

sub get_or_create_dbh {
    my ($self, $dbname) = @_;

    if (! defined $self->{dbh}) {
        $self->{dbh} = DBI_init($dbname);
    } elsif ($self->{dbh}->sqlite_db_filename ne $dbname) {
        warn "Replacing database " . $self->{dbh}->sqlite_db_filename . " with " . $dbname;
        $self->{dbh}->disconnect;
        $self->{dbh} = DBI_init($dbname); 
    }
    return $self->{dbh};
}

sub S_public {
    my ($self, $irc) = (shift, shift);

    my $nick = ${ +shift };
    $nick =~ s/!.*$//;

    my $my_own_nick = $irc->{nick};

    my $channel = ${ +shift }->[0];
    my $lc_channel = lc $channel;
    (my $pathsafe_channel = $lc_channel) =~ s{/}{_}g;
    my $channel_settings = $self->{channel_settings}{$lc_channel};

    my $karma_increase_re = qr(@{[ $channel_settings->{karma_increase_re} // KARMA_INCREASE_RE_DEFAULT ]});
    my $karma_decrease_re = qr(@{[ $channel_settings->{karma_decrease_re} // KARMA_DECREASE_RE_DEFAULT ]});
    my $karma_stats_re    = qr(@{[ $channel_settings->{karma_stats_re}    // KARMA_STATS_RE_DEFAULT    ]});
    my $status_file = $channel_settings->{status_file} // $ENV{HOME} . '/.pocoirc-rekarma-status-' . $pathsafe_channel;

    my $dbh = $self->get_or_create_dbh($status_file);

    my $message = shift;

    my $text = $$message;
    Encode::_utf8_on( $text );

    # allow optionally addressing the bot
    $text =~ s/\A$my_own_nick[:,\s]*//;

    my $new_karma = undef;

    my $karma_change_callback = sub {
        my ($dbh, $original_key, $value_change_callback) = @_;
        my $normalized_key = lc $original_key;

        my $old_karma = DBI_select_score($dbh, $original_key); 
        $old_karma //= 0;
        return $value_change_callback->($old_karma);
    };

    my $what = '';

    if ( $text =~ $karma_increase_re ) {
        warn "increasing ($lc_channel) karma for <$1> :)\n" if $channel_settings->{debug};
        $what = $1;
        $new_karma = $karma_change_callback->($dbh, $what, sub { return $_[0] + 1 });
    } elsif ( $text =~ $karma_decrease_re ) {
        warn "decreasing ($lc_channel) karma for <$1> :(\n" if $channel_settings->{debug};
        $what = $1;
        $new_karma = $karma_change_callback->($dbh, $what, sub { return $_[0] - 1 });
    } elsif ( $text =~ $karma_stats_re ) {
        $what = $1;
        
        warn "requesting karma stats for <@{[ $what // '(nothing/everything)' ]}>\n" if $channel_settings->{debug};

        if ( $what ){
            my $lc_what = lc $what;
            my $karma_value = DBI_select_score($dbh, $lc_what);
            my $message;
            
            if (defined $karma_value) {
                $message = "karma for <$lc_what> is $karma_value";
            } else {
                $message = "there is no karma for <$lc_what> yet!";
            }

            $irc->yield(
                notice => $channel,
                $message,
            ); 
        } else {
            my $num_records = 6;
            my %top_karma = DBI_select_all($dbh, "DESC", $num_records);
            my @top_keys = sort { %top_karma{$a} <=> %top_karma{$b} } keys %top_karma;

            $irc->yield(
                notice => $channel,
                "karma for <$_> is " . %top_karma{$_},
            ) for reverse @top_keys;

            my %bottom_karma = DBI_select_all($dbh, "ASC", $num_records);
            # Avoid printing duplicates when we have less than 2 * $num_records
            # entries in the database.
            foreach my $name (keys %bottom_karma) {
                if (exists($top_karma{$name})) {
                    delete %bottom_karma{$name};
                }
            }

            my @bottom_keys = sort { %bottom_karma{$a} <=> %bottom_karma{$b} } keys %bottom_karma;
            if (@bottom_keys) {
                $irc->yield(
                    notice => $channel,
                    "[...]",
                );

                $irc->yield(
                    notice => $channel,
                    "karma for <$_> is " . %bottom_karma{$_},
                ) for @bottom_keys;
            }
        }
    } else {
        return PCI_EAT_NONE;
    }

    if ( defined $new_karma ) {
        my $success = DBI_upsert_score($dbh, $what, $new_karma);
        
        if ( $success ) {
            $irc->yield(
                notice => $channel,
                "karma for <$what> is now $new_karma",
            );
        } else {
            warn "Failed to upsert karma <$what> in databse <$status_file>\n" if $channel_settings->{debug};
        }
    }

    return PCI_EAT_ALL;
}

sub DESTROY {
    my $self = shift;
    if ( defined $self->{dbh} ) {
        DBI_close($self->{dbh});
    }
}

1;

__END__

# vim: tabstop=4 shiftwidth=4 expandtab cindent:
