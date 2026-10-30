use strict;
use warnings;

# DASH-1: the autohandler used to precache every system-level right on every
# request, including the htmx /Views/ fragments. A component renders one small
# piece and should pay only for the rights it asks about, so the precache is
# skipped there. These tests pin both halves: the fragment still resolves
# rights lazily (it renders for someone who may see the ticket, and not for
# someone who may not), and the precache is not paid.

use RT::Test tests => undef;

$ENV{RT_TEST_WEB_HANDLER} = 'inline';

my ( $baseurl, $m ) = RT::Test->started_ok;

my $queue = RT::Test->load_or_create_queue( Name => 'ViewsBootstrap' );
ok $queue && $queue->id, 'queue';

my $user = RT::Test->load_or_create_user(
    Name         => 'viewsbootstrap',
    Password     => 'password',
    EmailAddress => 'viewsbootstrap@example.com',
    Privileged   => 1,
);
ok $user && $user->id, 'user';

my $group = RT::Group->new( RT->SystemUser );
my ( $gid, $gmsg ) = $group->CreateUserDefinedGroup( Name => 'views-bootstrap-group' );
ok $gid, "group: $gmsg";
$group->AddMember( $user->PrincipalId );

for my $right (qw/SeeQueue ShowTicket CommentOnTicket/) {
    my ( $ok, $msg ) = $group->PrincipalObj->GrantRight( Right => $right, Object => $queue );
    ok $ok, "granted $right: $msg";
}

my $ticket = RT::Ticket->new( RT->SystemUser );
my ( $tid, $tmsg ) = $ticket->Create(
    Queue   => $queue->Id,
    Subject => 'views bootstrap subject',
);
ok $tid, "ticket: $tmsg";

my $outsider = RT::Test->load_or_create_user(
    Name         => 'viewsoutsider',
    Password     => 'password',
    EmailAddress => 'viewsoutsider@example.com',
    Privileged   => 1,
);
ok $outsider && $outsider->id, 'outsider';

ok $m->login( 'viewsbootstrap', 'password' ), 'logged in as the ticket viewer';

my $handle = RT->DatabaseHandle;

sub get_component {
    my $url = shift;
    $handle->ClearSQLStatementLog;
    $handle->LogSQLStatements(1);
    my $res = $m->get( $url, { 'HX-Request' => 'true' } );
    my @log = $handle->SQLStatementLog;
    $handle->LogSQLStatements(0);
    return ( $res, \@log );
}

note 'the /Views/ fragment resolves the rights it needs, lazily';
{
    my ( $res, $log ) = get_component("$baseurl/Views/Ticket/Title?id=$tid");
    is $res->code, 200, 'the Title fragment renders';
    like $m->content, qr/views bootstrap subject/, 'it contains the ticket subject';

    note 'statements for the fragment: ' . scalar @$log;
    cmp_ok scalar @$log, '<=', 8,
        'no system-rights precache: the fragment costs only what it needs (was 10)';
}

note 'a user without ShowTicket does not get the fragment';
{
    ok $m->login( 'viewsoutsider', 'password', logout => 1 ), 'logged in as the outsider';
    my ( $res ) = get_component("$baseurl/Views/Ticket/Title?id=$tid");
    ok $res->code != 200 || $m->content !~ /views bootstrap subject/,
        'the fragment does not leak the subject to someone without ShowTicket';
}

note 'full pages still precache and still render';
{
    ok $m->login( 'viewsbootstrap', 'password', logout => 1 ), 'back to the ticket viewer';
    $m->get_ok("$baseurl/Ticket/Display.html?id=$tid");
    like $m->content, qr/views bootstrap subject/, 'ticket display renders';
}

done_testing();
