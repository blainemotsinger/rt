use strict;
use warnings;

# A group that watches a ticket plays the ticket's role for its members, even
# though CachedGroupMembers only stores a row for the group (RT deliberately
# does not unroll RT::Ticket-Role ancestors). The SQL ticket search has to add
# the user's groups to the member list for that to work; this test locks that
# in so the group list is not "optimized" away.

use RT::Test tests => undef;

my $queue = RT::Test->load_or_create_queue( Name => 'RoleGroupWatcher' );
ok $queue && $queue->id, 'queue';

my $user = RT::Test->load_or_create_user(
    Name         => 'rolegroupuser',
    Password     => 'password',
    EmailAddress => 'rolegroup@example.com',
    Privileged   => 1,
);
ok $user && $user->id, 'user';

my $group = RT::Group->new( RT->SystemUser );
my ( $gid, $gmsg ) = $group->CreateUserDefinedGroup( Name => 'rolegroup-watchers' );
ok $gid, "group: $gmsg";

my ( $member_ok, $member_msg ) = $group->AddMember( $user->PrincipalId );
ok $member_ok, "user is in the group: $member_msg";

my $ticket = RT::Ticket->new( RT->SystemUser );
my ( $tid, $tmsg ) = $ticket->Create(
    Queue   => $queue->Id,
    Subject => 'a ticket watched by a group',
);
ok $tid, "ticket: $tmsg";
$ticket->Load($tid);

my ( $watcher_ok, $watcher_msg )
    = $ticket->AddWatcher( Type => 'Cc', PrincipalId => $group->PrincipalId );
ok $watcher_ok, "group is Cc on the ticket: $watcher_msg";

my $cc_role = RT::Group->new( RT->SystemUser );
$cc_role->LoadRoleGroup( Object => $queue, Name => 'Cc' );
ok $cc_role->id, 'loaded the queue Cc role group';

my ( $granted, $grant_msg )
    = $cc_role->PrincipalObj->GrantRight( Right => 'ShowTicket', Object => $queue );
ok $granted, "ShowTicket granted to the queue Cc role: $grant_msg";

RT::Principal->InvalidateACLCache;

my $tickets = RT::Tickets->new( RT::CurrentUser->new($user) );
$tickets->Limit( FIELD => 'id', OPERATOR => '>', VALUE => 0 );
$tickets->CurrentUserCanSee;

my @visible = map { $_->Id } @{ $tickets->ItemsArrayRef || [] };
is_deeply \@visible, [$tid],
    'the member of a group Cc watcher sees the ticket through the role right';

done_testing();
