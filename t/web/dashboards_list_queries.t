use strict;
use warnings;

# DASH-7: the dashboards index used to count each privacy object's dashboards
# twice: once itself, to decide whether to show the Update button, and once more
# inside CollectionList. Counting once and passing the total down halves that.
#
# The page still runs one listing query per privacy object, so this test pins the
# duplicate count, not a constant query count: a full flattening would need the
# per-object CollectionList rendering to go away.

use RT::Test tests => undef;

# Run the app in this process so the statement log below observes the render.
# The default handler is a forked plack server, which hides it.
$ENV{RT_TEST_WEB_HANDLER} = 'inline';

my ( $baseurl, $m ) = RT::Test->started_ok;

my $user = RT::Test->load_or_create_user(
    Name         => 'dashlistuser',
    Password     => 'password',
    EmailAddress => 'dashlist@example.com',
    Privileged   => 1,
);
ok $user && $user->id, 'created user';

$user->PrincipalObj->GrantRight( Right => $_, Object => RT->System )
    for qw/SeeOwnDashboard AdminOwnDashboard SubscribeDashboard/;

my $content = {
    Elements => [
        {
            Layout   => 'col-12',
            Elements => [ [ { portlet_type => 'component', component => 'Summary' } ] ],
        }
    ],
};

my @owners;

my $mine = RT::Dashboard->new( RT->SystemUser );
my ( $mine_id, $mine_msg ) = $mine->Create(
    Name        => 'dashlist own dashboard',
    PrincipalId => $user->Id,
    Content     => $content,
);
ok $mine_id, "created user dashboard: $mine_msg";
push @owners, $user;

my $group = RT::Group->new( RT->SystemUser );
my ( $group_id, $group_msg ) = $group->CreateUserDefinedGroup( Name => 'dashlist-group' );
ok $group_id, "created group: $group_msg";

my ( $member_ok, $member_msg ) = $group->AddMember( $user->PrincipalId );
ok $member_ok, "added user to group: $member_msg";

$user->PrincipalObj->GrantRight( Right => 'SeeGroupDashboard',   Object => $group );
$user->PrincipalObj->GrantRight( Right => 'AdminGroupDashboard', Object => $group );

my $group_dash = RT::Dashboard->new( RT->SystemUser );
my ( $group_dash_id, $group_dash_msg ) = $group_dash->Create(
    Name        => 'dashlist group dashboard',
    PrincipalId => $group->Id,
    Content     => $content,
);
ok $group_dash_id, "created group dashboard: $group_dash_msg";
push @owners, $group;

ok $m->login( 'dashlistuser', 'password' ), 'logged in';

my $handle = RT->DatabaseHandle;

DBIx::SearchBuilder::Record::Cachable->FlushCache;

$handle->LogSQLStatements(1);
$handle->ClearSQLStatementLog;

$m->get_ok( $baseurl . '/Dashboards/index.html' );

my @log = $handle->SQLStatementLog;
$handle->LogSQLStatements(0);

my @counts = grep { $_->[1] =~ /count\s*\(\s*main\.id\s*\)\s*FROM\s+Dashboards/i } @log;
my @reads  = grep { $_->[1] =~ /\bFROM\s+Dashboards\b/i } @log;

note 'privacy objects with dashboards: ' . scalar @owners;
note 'Dashboards count statements: ' . scalar @counts;
note 'Dashboards statements total: ' . scalar @reads;

is scalar @counts, scalar @owners,
    'each privacy object counts its dashboards once, not twice';

ok scalar @reads > scalar @counts,
    'the collections are still listed after the count';

$m->content_contains( 'dashlist own dashboard',   'the user dashboard is listed' );
$m->content_contains( 'dashlist group dashboard', 'the group dashboard is listed' );
$m->content_like( qr/<input[^>]+name="Update"/, 'the Update button is still offered' );

done_testing();
