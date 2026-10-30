use strict;
use warnings;

# DASH-6: the dashboard mailer used to render the dashboard once per recipient.
# For a group (or multi-user) subscription with the same context and language
# that is the same HTML rendered over and over. It now renders once per
# (subscription, dashboard, current user, context user, language) and reuses
# the result; these tests pin the reuse, and that a different context user or
# language still gets its own render.

use RT::Test tests => undef;
use RT::Dashboard::Mailer;
use RT::DashboardSubscription;

my $root = RT::Test->load_or_create_user( Name => 'root' );
ok $root && $root->id, 'found the root user';
my $root_cu = RT::CurrentUser->new($root);

sub make_user {
    my ( $name, %extra ) = @_;
    my $user = RT::Test->load_or_create_user(
        Name         => $name,
        EmailAddress => "$name\@example.com",
        Password     => 'password',
        %extra,
    );
    ok $user && $user->id, "created user $name";
    return $user;
}

my $alice = make_user('alice');
my $bob   = make_user('bob');
my $carol = make_user( 'carol', Lang => 'fr' );

my $queue = RT::Test->load_or_create_queue( Name => 'General' );
ok $queue && $queue->id, 'queue';

for my $user ( $alice, $bob ) {
    for my $right (qw/SeeQueue ShowTicket OwnTicket/) {
        my ( $ok, $msg ) = $user->PrincipalObj->GrantRight(
            Right  => $right,
            Object => $queue,
        );
        ok $ok, "granted $right to " . $user->Name . ": $msg";
    }
}

# The "My Tickets" search is context sensitive (Owner = __CurrentUser__), so
# a render for a different context user has visibly different output.
my $search = RT::SavedSearch->new( RT->SystemUser );
$search->LoadByCols( Name => 'My Tickets', PrincipalId => RT->System->Id );
ok $search->id, 'loaded the system My Tickets saved search';

RT::Test->create_ticket(
    Queue   => 'General',
    Subject => 'owned by alice',
    Owner   => $alice->id,
);
RT::Test->create_ticket(
    Queue   => 'General',
    Subject => 'owned by bob',
    Owner   => $bob->id,
);
RT::Test->clean_caught_mails;

sub make_dashboard {
    my $name = shift;

    my $dashboard = RT::Dashboard->new($root_cu);
    my ( $id, $msg ) = $dashboard->Create(
        Name        => $name,
        PrincipalId => $root->id,
        Content     => {
            Elements => [
                {
                    Layout   => 'col-md-12',
                    Elements => [
                        [
                            {
                                portlet_type => 'search',
                                id           => $search->id,
                                description  => 'My Tickets',
                            },
                        ],
                        [],
                    ],
                }
            ],
        },
    );
    ok $id, "created dashboard $name: $msg";
    return $dashboard;
}

sub make_subscription {
    my ( $dashboard, %content ) = @_;

    my $subscription = RT::DashboardSubscription->new($root_cu);
    my ( $id, $msg ) = $subscription->Create(
        DashboardId => $dashboard->Id,
        UserId      => $root->id,
        Content     => {
            Frequency => 'daily',
            Hour      => '06:00',
            %content,
        },
    );
    ok $id, 'created subscription: ' . $msg;
    return $subscription;
}

sub run_mailer {
    my $subscription = shift;

    my %render_cache;
    RT::Dashboard::Mailer->MailDashboards(
        All          => 1,
        Subscription => $subscription,
        RenderCache  => \%render_cache,
    );

    my @mails = RT::Test->fetch_caught_mails;
    my @bodies = map { parse_mail($_)->bodyhandle->as_string } @mails;

    return ( \@bodies, \%render_cache );
}

note 'two recipients with the same context and language share one render';
{
    my $dashboard = make_dashboard('same context');
    my $subscription = make_subscription(
        $dashboard,
        Context    => 'subscriber',
        Recipients => { Users => [ $alice->id, $bob->id ], Groups => [] },
    );

    my ( $bodies, $cache ) = run_mailer($subscription);

    is @$bodies, 2, 'both recipients got a mail';
    is scalar( keys %$cache ), 1, 'the dashboard was rendered once';
    ok $bodies->[0] eq $bodies->[1], 'the two bodies are identical';

    is $subscription->DashboardObj, $subscription->DashboardObj,
        'DashboardObj is memoized on the subscription';
    is $subscription->UserObj, $subscription->UserObj,
        'UserObj is memoized on the subscription';
}

note 'the language is part of the render key';
{
    my $dashboard = make_dashboard('two languages');
    my $subscription = make_subscription(
        $dashboard,
        Context    => 'subscriber',
        Recipients => { Users => [ $alice->id, $carol->id ], Groups => [] },
    );

    my ( $bodies, $cache ) = run_mailer($subscription);

    is @$bodies, 2, 'both recipients got a mail';
    is scalar( keys %$cache ), 2, 'each language got its own render';
    ok $bodies->[0] ne $bodies->[1], 'the localized bodies differ';
}

note 'Context = recipient still renders per recipient';
{
    my $dashboard = make_dashboard('per recipient context');
    my $subscription = make_subscription(
        $dashboard,
        Context    => 'recipient',
        Recipients => { Users => [ $alice->id, $bob->id ], Groups => [] },
    );

    my ( $bodies, $cache ) = run_mailer($subscription);

    is @$bodies, 2, 'both recipients got a mail';
    is scalar( keys %$cache ), 2, 'each context user got its own render';

    my ($alice_body) = grep { /owned by alice/ } @$bodies;
    my ($bob_body)   = grep { /owned by bob/ } @$bodies;

    ok $alice_body, "alice sees her own ticket";
    ok $bob_body,   "bob sees his own ticket";
    ok $alice_body !~ /owned by bob/, "alice does not see bob's ticket";
    ok $bob_body !~ /owned by alice/, "bob does not see alice's ticket";
}

done_testing();
