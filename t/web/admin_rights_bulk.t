use strict;
use warnings;

use RT::Test tests => undef;

# Run the app in this process so the ACL collection count below observes the
# render. The default handler is a forked plack server, which hides it.
$ENV{RT_TEST_WEB_HANDLER} = 'inline';

my ( $baseurl, $m ) = RT::Test->started_ok;
ok $m->login('root'), 'logged in as root';

my $queue = RT::Test->load_or_create_queue( Name => 'RightsBulk' );
ok $queue && $queue->id, 'loaded or created queue';

my $group_a = RT::Group->new( RT->SystemUser );
my ( $ga_id, $ga_msg ) = $group_a->CreateUserDefinedGroup( Name => 'rightsbulk-a' );
ok $ga_id, "created group A: $ga_msg";

my $group_b = RT::Group->new( RT->SystemUser );
my ( $gb_id, $gb_msg ) = $group_b->CreateUserDefinedGroup( Name => 'rightsbulk-b' );
ok $gb_id, "created group B: $gb_msg";

my $user = RT::Test->load_or_create_user(
    Name         => 'rightsbulkuser',
    Password     => 'password',
    EmailAddress => 'rightsbulk@example.com',
    Privileged   => 1,
);
ok $user && $user->id, 'loaded or created user';

RT::Test->add_rights(
    { Principal => $group_a->PrincipalObj, Right => ['SeeQueue'], Object => $queue },
    { Principal => $user->PrincipalObj,    Right => ['ShowTicket'], Object => $queue },
);

# The rendered ids are SetRights-<principal id>-<context class>-<context id>-<right>.
sub checkbox_checked {
    my ( $html, $principal_id, $right ) = @_;
    my $id = "SetRights-$principal_id-RT::Queue-" . $queue->id . "-$right";
    return $html =~ /id="\Q$id\E"[^>]*\schecked/ ? 1 : 0;
}

sub acl_queries_for {
    my $url = shift;

    # The page runs in-process, so wrapping the collection constructor counts
    # how many ACL queries the render triggers. One per principal is the old
    # behavior; one per page is what we want.
    my $calls = 0;
    my $original = \&RT::ACL::LimitToObject;

    {
        no warnings 'redefine';
        local *RT::ACL::LimitToObject = sub {
            $calls++;
            return $original->(@_);
        };
        $m->get_ok($url);
    }

    note "LimitToObject calls for $url: $calls";

    return ( $m->content, $calls );
}

note 'group rights: the checkbox reflects the stored ACE, looked up once per page';
{
    my ( $html, $calls ) = acl_queries_for( $baseurl . '/Admin/Queues/GroupRights.html?id=' . $queue->id );

    ok checkbox_checked( $html, $group_a->PrincipalId, 'SeeQueue' ),
        'group A shows SeeQueue checked';
    ok !checkbox_checked( $html, $group_a->PrincipalId, 'CommentOnTicket' ),
        'group A does not show CommentOnTicket checked';

    is $calls, 1, 'the whole page built one ACL collection';
}

note 'user rights: a grant stored against the equivalence group is still found';
{
    my ( $html, $calls ) = acl_queries_for( $baseurl . '/Admin/Queues/UserRights.html?id=' . $queue->id );

    ok checkbox_checked( $html, $user->PrincipalId, 'ShowTicket' ),
        'the user panel shows ShowTicket checked';
    ok !checkbox_checked( $html, $user->PrincipalId, 'SeeQueue' ),
        'the user panel does not show an unrelated right checked';

    is $calls, 1, 'the user page built one ACL collection';
}

note 'the ACL collection count does not grow with the number of principals';
{
    my $before = ( acl_queries_for( $baseurl . '/Admin/Queues/GroupRights.html?id=' . $queue->id ) )[1];

    my @created;
    for my $n ( 2 .. 4 ) {
        my $group = RT::Group->new( RT->SystemUser );
        my ( $gid, $gmsg ) = $group->CreateUserDefinedGroup( Name => "rightsbulk-extra-$n" );
        ok $gid, "created extra group $n: $gmsg";
        my ( $granted, $grant_msg ) = $group->PrincipalObj->GrantRight(
            Right  => 'CommentOnTicket',
            Object => $queue,
        );
        ok $granted, "granted CommentOnTicket to extra group $n: $grant_msg";
        push @created, $group;
    }

    my ( $html, $after ) = acl_queries_for( $baseurl . '/Admin/Queues/GroupRights.html?id=' . $queue->id );

    is $after, $before,
        'four principals build the same number of ACL collections as one';

    my $last_pid = $created[-1]->PrincipalId;

    ok checkbox_checked( $html, $last_pid, 'CommentOnTicket' ),
        'an added group still shows its right checked';
}

done_testing();
